import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Query private var settingsList: [AppSettings]

    @State private var exportDocument = DataBackupDocument.empty
    @State private var exportFilename = DataBackupPayload.placeholder.defaultFilename
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var pendingImportPayload: DataBackupPayload?
    @State private var pendingImportFilename = ""
    @State private var backupAlert: BackupAlert?
    @State private var isRestoringBackup = false

    private var settings: AppSettings? {
        settingsList.first
    }

    private var reviewStyle: Binding<ReviewInteractionStyle> {
        Binding(
            get: { settings?.reviewInteractionStyle ?? AppSettings.defaultReviewInteractionStyle },
            set: { newValue in settings?.reviewInteractionStyle = newValue }
        )
    }

    /// Binding for the reminder time as a Date
    private var reminderDate: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = settings?.remindHour ?? 19
                components.minute = settings?.remindMinute ?? 30
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings?.remindHour = components.hour ?? 19
                settings?.remindMinute = components.minute ?? 30
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                introCard
                childInfoCard
                reminderCard
                reviewCard
                syncCard
                backupCard
                aboutCard
            }
            .padding(20)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExportingBackup,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            handleBackupExport(result)
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleBackupImport(result)
        }
        .confirmationDialog(
            "恢复备份",
            isPresented: Binding(
                get: { pendingImportPayload != nil },
                set: { if !$0 { clearPendingImport() } }
            ),
            titleVisibility: .visible
        ) {
            Button("覆盖当前数据", role: .destructive) {
                restorePendingBackup()
            }
            Button("取消", role: .cancel) {
                clearPendingImport()
            }
        } message: {
            Text(importConfirmationMessage)
        }
        .alert(item: $backupAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("通用设置")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text("调整复习偏好、通知以及数据同步状态。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [.gray.opacity(0.85), .secondary.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var childInfoCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("孩子名字", systemImage: "person.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.blue)
                
                TextField("输入孩子名字", text: bind(\.childName))
                    .font(.title2.weight(.medium))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("每日题量", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                
                HStack {
                    Text("\(settings?.dailyLimit ?? 15) 题")
                        .font(.title2.weight(.medium))
                    Spacer()
                    Stepper("", value: bind(\.dailyLimit), in: 5...30, step: 5)
                        .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var reminderCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("每日提醒")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                DatePicker("", selection: reminderDate, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("复习模式")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("复习模式", selection: reviewStyle) {
                    ForEach(ReviewInteractionStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Text(reviewStyle.wrappedValue == .oneByOne ? "提示：每报一题，家长立刻确认对错。" : "提示：连续报听写，最后统一批改。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("阶段复习间隔 (艾宾浩斯曲线)", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)

                Text("同一题目当天只复习一次。答对或答错会自动安排后续复习。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    stageChip("20分", stage: 1)
                    stageChip("1天", stage: 2)
                    stageChip("2天", stage: 3)
                    stageChip("4天", stage: 4)
                    stageChip("7天", stage: 5)
                    stageChip("15天", stage: 6)
                    stageChip("30天", stage: 7)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("数据同步")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(syncStatusStore.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
            }

            Text("数据通过 iCloud 同步到同一 Apple ID 下的设备。")
                .font(.caption)
                .foregroundStyle(.secondary)

            syncStatusNoticeCard

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("诊断信息", systemImage: "stethoscope")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 10) {
                    diagnosticRow(title: "当前存储", value: syncStatusStore.storageModeTitle)
                    diagnosticRow(title: "同步模式", value: syncStatusStore.cloudKitModeText)
                    diagnosticRow(title: "iCloud 账户", value: syncStatusStore.cloudAccountTitle)
                    diagnosticRow(title: "安装线索", value: syncStatusStore.cloudKitEnvironment)
                    diagnosticRow(title: "推送环境", value: syncStatusStore.apsEnvironment)
                    diagnosticRow(title: "容器 ID", value: syncStatusStore.containerIdentifier, monospaced: true)
                    diagnosticRow(title: "本地数据", value: syncStatusStore.localDataSummary)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("同步说明", systemImage: "icloud.and.arrow.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)

                Text(syncStatusStore.cloudAccountDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !syncStatusStore.cloudKitEnabled {
                    Text("当前这台设备已经退回本地存储模式，所以它不会和其他设备互相同步。常见原因是 CloudKit schema 没同步到后台，或这台设备当前构建无法初始化 CloudKit。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !syncStatusStore.cloudKitInitializationError.isEmpty {
                    Text(syncStatusStore.cloudKitInitializationError)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                Text("这里显示的是安装收据线索，不足以单独判断 CloudKit 一定在哪个环境。尤其 TestFlight 也可能显示 sandboxReceipt，所以请优先看“同步模式”和“iCloud 账户”这两项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await syncStatusStore.refresh(using: modelContext, trigger: .manual)
                }
            } label: {
                HStack {
                    if syncStatusStore.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                        Text("检查中...")
                    } else {
                        Image(systemName: "arrow.clockwise.icloud")
                        Text("立即检查")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(syncStatusStore.isRefreshing)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var syncStatusNoticeCard: some View {
        let style = syncNoticeStyle

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.tint)
                Text(syncStatusStore.syncNoticeTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.tint)
            }

            Text(syncStatusStore.syncNoticeMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: syncStatusStore.isUsingLocalFallback ? "externaldrive.fill.badge.xmark" : "externaldrive.fill.badge.checkmark")
                    .foregroundStyle(syncStatusStore.isUsingLocalFallback ? .red : .green)
                Text(syncStatusStore.storageModeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(syncStatusStore.isUsingLocalFallback ? .red : .green)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var syncNoticeStyle: (symbol: String, tint: Color, background: Color) {
        switch syncStatusStore.syncNoticeKind {
        case .checking:
            return ("arrow.triangle.2.circlepath", .cyan, .cyan.opacity(0.08))
        case .ready:
            return ("checkmark.icloud.fill", .green, .green.opacity(0.08))
        case .caution:
            return ("exclamationmark.icloud.fill", .orange, .orange.opacity(0.08))
        case .blocked:
            return ("icloud.slash.fill", .red, .red.opacity(0.08))
        }
    }

    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("备份与恢复")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if isRestoringBackup {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("恢复中...")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Text("导出会生成一个 JSON 备份文件，包含题库、复习记录、任务、日程、听写计划和设置；导入恢复会用备份内容覆盖当前设备上的现有数据。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("使用建议", systemImage: "externaldrive.badge.icloud")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)

                Text("建议在更换设备、重装 App 或做大批量整理前，先手动导出一份备份。恢复后的数据仍会继续参与 iCloud 同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    exportBackup()
                } label: {
                    Label("导出数据", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isRestoringBackup)

                Button {
                    isImportingBackup = true
                } label: {
                    Label("导入恢复", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isRestoringBackup)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var aboutCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "app.badge.fill")
                .font(.title)
                .foregroundStyle(.indigo)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("听写复习本")
                    .font(.headline)
                Text("结合艾宾浩斯遗忘曲线，帮助孩子高效攻克写错的词句和英语内容。")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func stageChip(_ text: String, stage: Int) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stage.stageColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stage.stageColor.opacity(0.12), in: Capsule())
    }

    private func diagnosticRow(title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
    }

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings?[keyPath: keyPath] ?? defaultValue(for: keyPath) },
            set: { newValue in settings?[keyPath: keyPath] = newValue }
        )
    }

    private func defaultValue<Value>(for keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Value {
        AppSettings()[keyPath: keyPath]
    }

    private var importConfirmationMessage: String {
        guard let pendingImportPayload else {
            return ""
        }

        let exportedAt = pendingImportPayload.exportedAt.formatted(
            .dateTime.year().month().day().hour().minute()
        )

        return """
        文件：\(pendingImportFilename)
        备份时间：\(exportedAt)
        内容：\(pendingImportPayload.summaryText)

        恢复后会覆盖当前这台设备上的现有数据，请确认已经完成导出备份。
        """
    }

    private func exportBackup() {
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }

            let document = try DataBackupService.makeDocument(from: modelContext)
            exportDocument = document
            exportFilename = document.payload.defaultFilename
            isExportingBackup = true
        } catch {
            showBackupAlert(
                title: "导出失败",
                message: error.localizedDescription
            )
        }
    }

    private func handleBackupExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            showBackupAlert(
                title: "导出成功",
                message: "备份文件已经导出完成，可以保存在 iCloud Drive 或本地文件夹中备用。"
            )
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            showBackupAlert(
                title: "导出失败",
                message: error.localizedDescription
            )
        }
    }

    private func handleBackupImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let document = try DataBackupDocument(data: data)
                pendingImportPayload = document.payload
                pendingImportFilename = url.lastPathComponent
            } catch {
                showBackupAlert(
                    title: "导入失败",
                    message: error.localizedDescription
                )
            }
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            showBackupAlert(
                title: "导入失败",
                message: error.localizedDescription
            )
        }
    }

    private func restorePendingBackup() {
        guard let pendingImportPayload else { return }

        isRestoringBackup = true
        defer {
            isRestoringBackup = false
            clearPendingImport()
        }

        do {
            try DataBackupService.restore(pendingImportPayload, into: modelContext)
            showBackupAlert(
                title: "恢复完成",
                message: "已经根据备份文件恢复数据。\n\n\(pendingImportPayload.summaryText)"
            )
            Task {
                await syncStatusStore.refresh(using: modelContext, trigger: .manual)
            }
        } catch {
            showBackupAlert(
                title: "恢复失败",
                message: error.localizedDescription
            )
        }
    }

    private func clearPendingImport() {
        pendingImportPayload = nil
        pendingImportFilename = ""
    }

    private func showBackupAlert(title: String, message: String) {
        backupAlert = BackupAlert(title: title, message: message)
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return error is CancellationError
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == 3072)
    }
}

private struct BackupAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
