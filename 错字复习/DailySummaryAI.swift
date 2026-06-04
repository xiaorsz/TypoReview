import CryptoKit
import Foundation
import Security

enum DailySummaryAISettings {
    static let isEnabledKey = "dailySummaryAI.isEnabled"
    static let modelKey = "dailySummaryAI.deepSeekModel"
    static let defaultModel = DeepSeekSummaryModel.flash.rawValue
}

enum DeepSeekSummaryModel: String, CaseIterable, Identifiable {
    case flash = "deepseek-v4-flash"
    case pro = "deepseek-v4-pro"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flash:
            return "DeepSeek V4 Flash"
        case .pro:
            return "DeepSeek V4 Pro"
        }
    }
}

struct DailySummaryInput: Codable, Equatable {
    struct Metrics: Codable, Equatable {
        let reviewCompleted: Int
        let reviewCorrect: Int
        let reviewWrong: Int
        let reviewAccuracyText: String
        let dictationReviewedEntries: Int
        let tasksCompleted: Int
        let tasksPending: Int
        let pointsEarnedToday: Int
        let currentStreak: Int
    }

    struct Highlights: Codable, Equatable {
        let completedTaskTitles: [String]
        let wrongReviewSamples: [String]
    }

    let date: String
    let locale: String
    let tone: String
    let childName: String
    let metrics: Metrics
    let highlights: Highlights

    var hasActivity: Bool {
        metrics.reviewCompleted > 0 ||
        metrics.dictationReviewedEntries > 0 ||
        metrics.tasksCompleted > 0
    }

    func stableHash() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "\(date)-fallback"
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func localFallbackResult() -> DailySummaryResult {
        let name = childName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "小朋友" : childName

        guard hasActivity else {
            return DailySummaryResult(
                title: "今天还没有完成记录",
                message: "先从一小组复习、听写或任务开始，完成后这里会自动整理今日小结。",
                highlights: [],
                tomorrowFocus: "今天先完成一个小目标就很好。"
            )
        }

        var highlights: [String] = []
        if metrics.reviewCompleted > 0 {
            highlights.append("完成 \(metrics.reviewCompleted) 次复习")
        }
        if metrics.dictationReviewedEntries > 0 {
            highlights.append("听写判定 \(metrics.dictationReviewedEntries) 条")
        }
        if metrics.tasksCompleted > 0 {
            highlights.append("任务完成 \(metrics.tasksCompleted) 项")
        }
        if metrics.pointsEarnedToday > 0 {
            highlights.append("获得 \(metrics.pointsEarnedToday) 积分")
        }

        let message: String
        if metrics.reviewCompleted > 0 {
            message = "\(name) 今天完成得很扎实，复习正确率 \(metrics.reviewAccuracyText)，继续保持这个节奏。"
        } else if metrics.dictationReviewedEntries > 0 {
            message = "\(name) 今天完成了听写判定，已经把练习结果记录下来了。"
        } else {
            message = "\(name) 今天的任务有推进，稳定完成比一次做很多更重要。"
        }

        let focus = metrics.reviewWrong > 0
            ? "明天重点回看今天答错的 \(metrics.reviewWrong) 个内容。"
            : "明天继续按计划少量复习，保持手感。"

        return DailySummaryResult(
            title: "今日小结",
            message: message,
            highlights: highlights,
            tomorrowFocus: focus
        )
    }

    static func dateKey(for date: Date = .now, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct DailySummaryResult: Codable, Equatable {
    let title: String
    let message: String
    let highlights: [String]
    let tomorrowFocus: String

    var displayText: String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMessage.isEmpty {
            return trimmedMessage
        }
        return tomorrowFocus.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LearningSessionSummaryInput: Codable, Equatable {
    enum SessionKind: String, Codable {
        case review
        case dictation

        var title: String {
            switch self {
            case .review:
                return "复习"
            case .dictation:
                return "听写"
            }
        }
    }

    struct Metrics: Codable, Equatable {
        let totalCount: Int
        let correctCount: Int
        let wrongCount: Int
        let accuracyText: String
    }

    struct Samples: Codable, Equatable {
        let wrongItems: [String]
        let correctItems: [String]
    }

    let kind: SessionKind
    let title: String
    let date: String
    let childName: String
    let metrics: Metrics
    let samples: Samples

    func stableHash() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "\(date)-\(kind.rawValue)-fallback"
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func localFallbackResult() -> LearningSessionSummaryResult {
        let kindTitle = kind.title
        let title = metrics.wrongCount == 0 ? "\(kindTitle)完成得很稳" : "\(kindTitle)已完成"
        let message: String
        if metrics.totalCount == 0 {
            message = "这次还没有可总结的记录。"
        } else if metrics.wrongCount == 0 {
            message = "这次 \(kindTitle) 共完成 \(metrics.totalCount) 条，全部正确，正确率 \(metrics.accuracyText)。"
        } else {
            message = "这次 \(kindTitle) 共完成 \(metrics.totalCount) 条，答错 \(metrics.wrongCount) 条，正确率 \(metrics.accuracyText)。"
        }

        let suggestions: [String]
        if kind == .dictation {
            suggestions = metrics.wrongCount == 0
                ? ["这次没有错项，保持当前听写节奏。", "可以把全对内容快速朗读一遍。"]
                : ["把本次错项单独读准，再遮住重写。", "对照错项找偏旁、字形或拼写差异。"]
        } else {
            suggestions = metrics.wrongCount == 0
                ? ["这次没有错项，按系统节奏继续即可。", "可以用听写方式抽查一小组。"]
                : ["把本次错项先看提示，再独立复述。", "对照错项补一句自己的记忆提示。"]
        }

        return LearningSessionSummaryResult(
            title: title,
            message: message,
            suggestions: suggestions
        )
    }
}

struct LearningSessionSummaryResult: Codable, Equatable {
    let title: String
    let message: String
    let suggestions: [String]

    var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DailySummaryCache {
    private static let prefix = "dailySummaryAI.cache.v2"

    private struct Entry: Codable {
        let result: DailySummaryResult
        let createdAt: Date
    }

    static func load(inputHash: String, model: String) -> DailySummaryResult? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(inputHash: inputHash, model: model)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return entry.result
    }

    static func save(_ result: DailySummaryResult, inputHash: String, model: String) {
        let entry = Entry(result: result, createdAt: .now)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(inputHash: inputHash, model: model))
    }

    private static func cacheKey(inputHash: String, model: String) -> String {
        "\(prefix).\(model).\(inputHash)"
    }
}

enum LearningSessionSummaryCache {
    private static let prefix = "learningSessionSummaryAI.cache.v1"

    private struct Entry: Codable {
        let result: LearningSessionSummaryResult
        let createdAt: Date
    }

    static func load(inputHash: String, model: String) -> LearningSessionSummaryResult? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(inputHash: inputHash, model: model)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return entry.result
    }

    static func save(_ result: LearningSessionSummaryResult, inputHash: String, model: String) {
        let entry = Entry(result: result, createdAt: .now)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(inputHash: inputHash, model: model))
    }

    private static func cacheKey(inputHash: String, model: String) -> String {
        "\(prefix).\(model).\(inputHash)"
    }
}

enum DeepSeekAPIKeyStore {
    enum StoreError: LocalizedError {
        case encodingFailed
        case readFailed(OSStatus)
        case writeFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "API Key 编码失败。"
            case .readFailed(let status):
                return "读取 Keychain 失败：\(status)"
            case .writeFailed(let status):
                return "保存 Keychain 失败：\(status)"
            }
        }
    }

    private static let service = Bundle.main.bundleIdentifier ?? "cc.xiaorsz.typo-review"
    private static let account = "deepseek-api-key"

    static func loadAPIKey() throws -> String {
        if let synchronizedKey = try loadAPIKey(synchronizable: true) {
            return synchronizedKey
        }

        guard let legacyLocalKey = try loadAPIKey(synchronizable: false) else {
            return ""
        }

        // Best effort: preserve the readable local key if iCloud Keychain is
        // temporarily unavailable while upgrading from an older app version.
        try? saveAPIKey(legacyLocalKey)
        return legacyLocalKey
    }

    static func saveAPIKey(_ key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            deleteAPIKey()
            return
        }
        guard let data = trimmedKey.data(using: .utf8) else {
            throw StoreError.encodingFailed
        }

        let synchronizedQuery = query(synchronizable: true)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(synchronizedQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            deleteLegacyLocalAPIKey()
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw StoreError.writeFailed(updateStatus)
        }

        let deletedLegacyLocalKey = try loadAPIKey(synchronizable: false)
        deleteLegacyLocalAPIKey()

        var addQuery = synchronizedQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess, let deletedLegacyLocalKey {
            restoreLegacyLocalAPIKey(deletedLegacyLocalKey)
        }
        guard addStatus == errSecSuccess else {
            throw StoreError.writeFailed(addStatus)
        }
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func query(synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        ]
    }

    private static func loadAPIKey(synchronizable: Bool) throws -> String? {
        var query = query(synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw StoreError.readFailed(status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw StoreError.readFailed(status)
        }
        return key
    }

    private static func deleteLegacyLocalAPIKey() {
        SecItemDelete(query(synchronizable: false) as CFDictionary)
    }

    private static func restoreLegacyLocalAPIKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        var addQuery = query(synchronizable: false)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

struct DeepSeekSummaryClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(String)
        case emptyContent
        case invalidSummary

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "请先填写 DeepSeek API Key。"
            case .invalidResponse:
                return "DeepSeek 返回异常。"
            case .apiError(let message):
                return message
            case .emptyContent:
                return "DeepSeek 没有返回小结内容。"
            case .invalidSummary:
                return "DeepSeek 返回的小结格式不正确。"
            }
        }
    }

    let apiKey: String
    let model: String

    func generateSummary(for input: DailySummaryInput) async throws -> DailySummaryResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(makeRequestBody(input: input))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(DeepSeekErrorResponse.self, from: data)
            throw ClientError.apiError(errorResponse?.error.message ?? "DeepSeek 请求失败：\(httpResponse.statusCode)")
        }

        let chatResponse = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.emptyContent
        }

        guard let resultData = content.data(using: .utf8),
              let result = try? JSONDecoder().decode(DailySummaryResult.self, from: resultData),
              result.isUsable else {
            throw ClientError.invalidSummary
        }
        return result
    }

    func generateLearningSessionSummary(for input: LearningSessionSummaryInput) async throws -> LearningSessionSummaryResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(makeLearningSessionRequestBody(input: input))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(DeepSeekErrorResponse.self, from: data)
            throw ClientError.apiError(errorResponse?.error.message ?? "DeepSeek 请求失败：\(httpResponse.statusCode)")
        }

        let chatResponse = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.emptyContent
        }

        guard let resultData = content.data(using: .utf8),
              let result = try? JSONDecoder().decode(LearningSessionSummaryResult.self, from: resultData),
              result.isUsable else {
            throw ClientError.invalidSummary
        }
        return result
    }

    private func makeRequestBody(input: DailySummaryInput) throws -> DeepSeekChatRequest {
        let inputData = try JSONEncoder().encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"

        let systemPrompt = """
        你是一个给小学生家长看的学习助手。请只根据用户提供的 JSON 事实写今日小结，不要编造数字。
        输出必须是严格 JSON object，字段为 title、message、highlights、tomorrowFocus。
        message 只总结今天已经完成的内容和当前状态，不要写“明天”，不要说今天失败了，也不要承诺今天一定还能完成。
        如果 tasksCompleted 为 0 且 tasksPending 大于 0，可以温和表达“还有待办未完成”，不要写“今天没有完成任务”。
        tomorrowFocus 只写下一次可以关注什么，不要再出现“今天还能/今天可以/一起完成今天”这类表达。
        语气温和、鼓励、具体，中文简体。message 不超过 55 个汉字，tomorrowFocus 不超过 30 个汉字，highlights 最多 3 条。
        """

        let userPrompt = """
        请根据这份今日学习 JSON 生成小结：
        \(inputJSON)
        """

        return DeepSeekChatRequest(
            model: model,
            messages: [
                DeepSeekMessage(role: "system", content: systemPrompt),
                DeepSeekMessage(role: "user", content: userPrompt)
            ],
            responseFormat: DeepSeekResponseFormat(type: "json_object"),
            temperature: 0.4,
            maxTokens: 500,
            stream: false
        )
    }

    private func makeLearningSessionRequestBody(input: LearningSessionSummaryInput) throws -> DeepSeekChatRequest {
        let inputData = try JSONEncoder().encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"

        let systemPrompt = """
        你是一个给小学生家长看的学习助手。请只根据用户提供的 JSON 事实写本次练习结束小结，不要编造数字。
        输出必须是严格 JSON object，字段为 title、message、suggestions。
        message 只总结本次 \(input.kind.title) 的完成情况，不要提不存在的任务、日程或历史记录。
        suggestions 给 2 到 3 条具体可执行建议，必须优先针对 samples.wrongItems 里的本次错项；不要泛泛写“下次/明天/以后”。
        若 kind 是 dictation，建议围绕本次听错内容如何立刻纠正、辨析字形/拼写/发音或提示；若 kind 是 review，建议围绕本次错项如何重新理解和记忆。
        语气温和、具体，中文简体。message 不超过 55 个汉字，每条 suggestion 不超过 24 个汉字。
        """

        let userPrompt = """
        请根据这份本次练习 JSON 生成结束小结：
        \(inputJSON)
        """

        return DeepSeekChatRequest(
            model: model,
            messages: [
                DeepSeekMessage(role: "system", content: systemPrompt),
                DeepSeekMessage(role: "user", content: userPrompt)
            ],
            responseFormat: DeepSeekResponseFormat(type: "json_object"),
            temperature: 0.35,
            maxTokens: 500,
            stream: false
        )
    }
}

private struct DeepSeekChatRequest: Encodable {
    let model: String
    let messages: [DeepSeekMessage]
    let responseFormat: DeepSeekResponseFormat
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct DeepSeekMessage: Codable {
    let role: String
    let content: String
}

private struct DeepSeekResponseFormat: Encodable {
    let type: String
}

private struct DeepSeekChatResponse: Decodable {
    struct Choice: Decodable {
        let message: DeepSeekMessage
    }

    let choices: [Choice]
}

private struct DeepSeekErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
