import CryptoKit
import Foundation
import Observation
import SwiftData
import WidgetKit

@MainActor
@Observable
final class ServerSyncCoordinator {
    static let shared = ServerSyncCoordinator()

    private static let baselineDefaultsKey = "typo_review_server_sync_baseline_v1"
    private static let bootstrapInProgressDefaultsKey = "typo_review_server_bootstrap_in_progress_v1"
    nonisolated private static let entityOrder = [
        "reviewRecords",
        "reviewItems",
        "taskItems",
        "taskCompletions",
        "taskSubitems",
        "taskExecutionRecords",
        "taskSubitemExecutionRecords",
        "dictationSessions",
        "dictationEntries",
        "scheduleItems",
        "pointLedgerEntries",
        "pointRewardStates",
        "settings",
    ]

    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    private var isPulling = false
    private var isUploading = false
    private var activeSyncPhase: String?
    private(set) var isApplyingRemoteSnapshot = false
    private(set) var lastErrorDescription: String?
    private(set) var lastSuccessfulConnectionAt: Date?
    private(set) var lastSuccessfulPullAt: Date?
    private(set) var lastSuccessfulUploadAt: Date?
    private(set) var lastPulledDataSummary = "尚未完成服务器下载"

    var isEnabled: Bool { ServerAPIConfiguration.current != nil }
    var isSynchronizing: Bool { isPulling || isUploading || isApplyingRemoteSnapshot }
    var serverStatusText: String {
        if let activeSyncPhase {
            return activeSyncPhase
        }
        return lastErrorDescription == nil ? "正常" : "等待重试"
    }

    func synchronize(
        modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async {
        guard isEnabled else { return }
        if loadBaseline() == nil {
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: Self.bootstrapInProgressDefaultsKey) else {
                lastErrorDescription = "上次首次同步被系统中断，已暂停自动导入。请在设置中手动同步。"
                return
            }
            defaults.set(true, forKey: Self.bootstrapInProgressDefaultsKey)
            defer {
                defaults.removeObject(forKey: Self.bootstrapInProgressDefaultsKey)
            }
            _ = await pull(into: modelContext, settingsStore: settingsStore)
            return
        } else {
            let uploadSucceeded = await uploadChanges(
                from: modelContext,
                settingsStore: settingsStore
            )
            guard uploadSucceeded else {
                // Preserve locally completed work when the server rejects an
                // upload. Pulling the older server snapshot here would replace
                // the local store and make a successful submission appear undone.
                return
            }
        }
        await pull(into: modelContext, settingsStore: settingsStore)
    }

    @discardableResult
    func pull(
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard isEnabled, !isApplyingRemoteSnapshot, !isPulling else { return false }

        // A delayed upload may already have started. Stop it and wait for its
        // cancellation to finish before replacing local data with the server
        // snapshot, otherwise its cancellation error can overwrite pull status.
        let pendingUpload = uploadTask
        uploadTask = nil
        pendingUpload?.cancel()
        if let pendingUpload {
            await pendingUpload.value
        }
        guard !isUploading else { return false }

        isPulling = true
        lastErrorDescription = nil
        activeSyncPhase = "正在检查连接"
        defer {
            activeSyncPhase = nil
            isPulling = false
        }
        do {
            try await ServerAPIClient.shared.health()
            lastSuccessfulConnectionAt = .now
            activeSyncPhase = "正在下载数据"
            let payload = try await ServerAPIClient.shared.exportSnapshot()
            activeSyncPhase = "正在写入本机"
            isApplyingRemoteSnapshot = true
            defer { isApplyingRemoteSnapshot = false }

            try await DataBackupService.restoreStructuredDataInBatches(
                payload,
                into: modelContext,
                settingsStore: settingsStore
            )
            activeSyncPhase = "正在更新今日计划"
            try await installServerDailyPlan(
                in: modelContext,
                dailyLimit: settingsStore.dailyLimit
            )
            saveBaseline(try StructuredSnapshot(payload: payload).hashes)
            UserDefaults.standard.removeObject(forKey: Self.bootstrapInProgressDefaultsKey)
            lastErrorDescription = nil
            lastSuccessfulPullAt = .now
            lastPulledDataSummary = Self.dataSummary(for: payload)
            await synchronizeDeepSeekAPIKey()
            AppDataChangeCenter.post()
            WidgetCenter.shared.reloadAllTimelinesInBackground()
            return true
        } catch where Self.isCancellation(error) {
            return false
        } catch {
            lastErrorDescription = Self.userFacingDescription(
                for: error,
                phase: activeSyncPhase
            )
            #if DEBUG
            print("Server pull failed: \(error)")
            #endif
            return false
        }
    }

    func scheduleUpload(
        from modelContext: ModelContext,
        settingsStore: AppSettingsStore,
        delayNanoseconds: UInt64 = 700_000_000
    ) {
        guard isEnabled, !isApplyingRemoteSnapshot else { return }
        uploadTask?.cancel()
        uploadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.uploadChanges(from: modelContext, settingsStore: settingsStore)
        }
    }

    @discardableResult
    func uploadChanges(
        from modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard isEnabled, !isApplyingRemoteSnapshot, !isPulling, !isUploading else { return false }
        guard let baseline = loadBaseline() else { return false }
        isUploading = true
        activeSyncPhase = "正在上传数据"
        defer {
            activeSyncPhase = nil
            isUploading = false
        }
        do {
            let container = modelContext.container
            let settings = settingsStore.snapshot
            let preparedUpload = try await Task.detached(priority: .utility) {
                try Self.prepareUpload(
                    from: container,
                    settings: settings,
                    baseline: baseline
                )
            }.value
            guard !preparedUpload.bodies.isEmpty else {
                lastErrorDescription = nil
                return true
            }

            for body in preparedUpload.bodies {
                try Task.checkCancellation()
                try await ServerAPIClient.shared.pushMutations(body)
            }
            saveBaseline(preparedUpload.hashes)
            lastErrorDescription = nil
            lastSuccessfulUploadAt = .now
            return true
        } catch where Self.isCancellation(error) {
            return false
        } catch {
            lastErrorDescription = error.localizedDescription
            #if DEBUG
            print("Server upload failed: \(error)")
            #endif
            return false
        }
    }

    nonisolated private static func prepareUpload(
        from container: ModelContainer,
        settings: AppSettingsSnapshot,
        baseline: [String: [String: String]]
    ) throws -> PreparedServerUpload {
        let context = ModelContext(container)
        let payload = try DataBackupPayload.capture(
            from: context,
            settings: settings,
            mediaAssets: []
        )
        let snapshot = try StructuredSnapshot(payload: payload)
        let mutations = try snapshot.mutations(comparedWith: baseline)
        var bodies: [Data] = []
        bodies.reserveCapacity((mutations.count + 499) / 500)
        for batchStart in stride(from: 0, to: mutations.count, by: 500) {
            let batchEnd = min(batchStart + 500, mutations.count)
            bodies.append(
                try JSONSerialization.data(
                    withJSONObject: ["mutations": Array(mutations[batchStart..<batchEnd])],
                    options: [.sortedKeys]
                )
            )
        }
        return PreparedServerUpload(bodies: bodies, hashes: snapshot.hashes)
    }

    private static func dataSummary(for payload: DataBackupPayload) -> String {
        "题库 \(payload.reviewItems.count) 条，复习记录 \(payload.reviewRecords.count) 条，听写 \(payload.dictationSessions.count) 组 / \(payload.dictationEntries.count) 条"
    }

    private func synchronizeDeepSeekAPIKey() async {
        do {
            let remote = try await ServerAPIClient.shared.deepSeekAPIKey()
            if let value = remote.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                try DeepSeekAPIKeyStore.saveAPIKey(value)
                return
            }

            let local = try DeepSeekAPIKeyStore.loadAPIKey()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !local.isEmpty {
                _ = try await ServerAPIClient.shared.saveDeepSeekAPIKey(local)
            }
        } catch {
            #if DEBUG
            print("DeepSeek API Key sync failed: \(error)")
            #endif
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func userFacingDescription(for error: Error, phase: String?) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return "\(phase ?? "服务器请求")超时。请切换 Wi‑Fi/蜂窝网络后重试；本机数据不会因此丢失。"
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            return "当前网络不可用，请恢复网络后重试。"
        }
        return error.localizedDescription
    }

    private func installServerDailyPlan(
        in modelContext: ModelContext,
        dailyLimit: Int
    ) async throws {
        let dayKey = ReviewDailyPlan.dayKey(for: .now)
        let serverPlan = try await ServerAPIClient.shared.dailyPlan(
            day: dayKey,
            dailyLimit: dailyLimit
        )
        let plans = try modelContext.fetch(
            FetchDescriptor<ReviewDailyPlan>(
                predicate: #Predicate<ReviewDailyPlan> { $0.dayKey == dayKey }
            )
        )
        plans.forEach(modelContext.delete)
        modelContext.insert(
            ReviewDailyPlan(
                id: serverPlan.id,
                dayKey: serverPlan.day,
                itemIDs: serverPlan.items.map(\.itemID),
                createdAt: serverPlan.createdAt,
                updatedAt: serverPlan.updatedAt
            )
        )
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    private func loadBaseline() -> [String: [String: String]]? {
        guard let data = UserDefaults.standard.data(forKey: Self.baselineDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    private func saveBaseline(_ baseline: [String: [String: String]]) {
        if let data = try? JSONEncoder().encode(baseline) {
            UserDefaults.standard.set(data, forKey: Self.baselineDefaultsKey)
        }
    }

    struct StructuredSnapshot {
        private static let timestampFields: [String: String] = [
            "reviewItems": "updatedAt",
            "reviewRecords": "reviewedAt",
            "taskItems": "updatedAt",
            "taskCompletions": "completedAt",
            "taskSubitems": "updatedAt",
            "taskExecutionRecords": "updatedAt",
            "taskSubitemExecutionRecords": "updatedAt",
            "dictationSessions": "updatedAt",
            "dictationEntries": "updatedAt",
            "scheduleItems": "updatedAt",
            "pointLedgerEntries": "createdAt",
            "pointRewardStates": "updatedAt",
            "settings": "updatedAt",
        ]

        let records: [String: [String: [String: Any]]]
        let hashes: [String: [String: String]]

        init(payload: DataBackupPayload) throws {
            let data = try payload.encodedData()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ServerAPIError.invalidResponse
            }
            var records: [String: [String: [String: Any]]] = [:]
            for entity in ServerSyncCoordinator.entityOrder {
                let values: [[String: Any]]
                if entity == "settings" {
                    values = (root["settings"] as? [String: Any]).map { [$0] } ?? []
                } else {
                    values = root[entity] as? [[String: Any]] ?? []
                }
                records[entity] = try Self.deduplicated(
                    values,
                    timestampField: Self.timestampFields[entity]
                )
            }
            self.records = records
            hashes = try records.mapValues { values in
                try values.mapValues { value in
                    let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
                }
            }
        }

        func mutations(comparedWith baseline: [String: [String: String]]) throws -> [[String: Any]] {
            let timestamp = ISO8601DateFormatter().string(from: .now)
            var mutations: [[String: Any]] = []
            for entity in ServerSyncCoordinator.entityOrder {
                let currentRecords = records[entity] ?? [:]
                let currentHashes = hashes[entity] ?? [:]
                let previousHashes = baseline[entity] ?? [:]

                for id in currentRecords.keys.sorted() where currentHashes[id] != previousHashes[id] {
                    mutations.append([
                        "mutationID": UUID().uuidString,
                        "entityType": entity,
                        "recordID": id,
                        "operation": "upsert",
                        "updatedAt": timestamp,
                        "payload": currentRecords[id]!,
                    ])
                }
                for id in previousHashes.keys.sorted() where currentRecords[id] == nil {
                    mutations.append([
                        "mutationID": UUID().uuidString,
                        "entityType": entity,
                        "recordID": id,
                        "operation": "delete",
                        "updatedAt": timestamp,
                    ])
                }
            }
            return mutations
        }

        private static func deduplicated(
            _ values: [[String: Any]],
            timestampField: String?
        ) throws -> [String: [String: Any]] {
            var result: [String: [String: Any]] = [:]
            for value in values {
                guard let id = value["id"] as? String else { continue }
                guard let existing = result[id] else {
                    result[id] = value
                    continue
                }

                let existingTimestamp = timestampField.flatMap { existing[$0] as? String } ?? ""
                let candidateTimestamp = timestampField.flatMap { value[$0] as? String } ?? ""
                if candidateTimestamp != existingTimestamp {
                    if candidateTimestamp > existingTimestamp {
                        result[id] = value
                    }
                    continue
                }

                // Equal timestamps still need a stable winner so every device hashes
                // the same physical duplicates in the same way.
                let existingData = try JSONSerialization.data(
                    withJSONObject: existing,
                    options: [.sortedKeys]
                )
                let candidateData = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.sortedKeys]
                )
                if existingData.lexicographicallyPrecedes(candidateData) {
                    result[id] = value
                }
            }
            return result
        }
    }
}

private struct PreparedServerUpload: Sendable {
    let bodies: [Data]
    let hashes: [String: [String: String]]
}
