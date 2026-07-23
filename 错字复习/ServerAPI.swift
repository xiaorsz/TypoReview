import Foundation
import Security

struct ServerAPIConfiguration: Sendable {
    static let urlInfoKey = "TypoReviewServerURL"

    let baseURL: URL
    let token: String

    static var serverURL: URL? {
        guard let rawURL = Bundle.main.object(forInfoDictionaryKey: urlInfoKey) as? String else {
            return nil
        }
        return URL(string: rawURL)
    }

    static var current: ServerAPIConfiguration? {
        guard let url = serverURL,
              let token = try? ServerCredentialStore.loadToken(),
              !token.isEmpty else {
            return nil
        }
        return ServerAPIConfiguration(baseURL: url, token: token)
    }
}

enum ServerCredentialStore {
    private static let service = "cc.xiaorsz.typo-review.server-sync"
    private static let tokenAccount = "device-token"
    private static let pairingCodeAccount = "pairing-code"

    static func loadToken() throws -> String {
        try loadValue(account: tokenAccount)
    }

    static func saveToken(_ token: String) throws {
        try saveValue(token, account: tokenAccount)
    }

    static func loadPairingCode() throws -> String {
        try loadValue(account: pairingCodeAccount)
    }

    static func savePairingCode(_ code: String) throws {
        try saveValue(code, account: pairingCodeAccount)
    }

    private static func loadValue(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw ServerAPIError.notConfigured
        }
        return token
    }

    private static func saveValue(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var inserted = query
            attributes.forEach { inserted[$0.key] = $0.value }
            let status = SecItemAdd(inserted as CFDictionary, nil)
            guard status == errSecSuccess else { throw ServerAPIError.notConfigured }
        } else if updateStatus != errSecSuccess {
            throw ServerAPIError.notConfigured
        }
    }
}

enum ServerAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case rejected(statusCode: Int, message: String)
    case pinnedCertificateUnavailable
    case pinnedCertificateRejected

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "服务器同步尚未配置。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .rejected(let statusCode, let message):
            return "服务器拒绝了请求（HTTP \(statusCode)）：\(message)"
        case .pinnedCertificateUnavailable:
            return "App 中缺少服务器 CA 证书。"
        case .pinnedCertificateRejected:
            return "服务器证书与 App 固定的证书不一致。"
        }
    }
}

private final class ServerPinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let certificate: SecCertificate?

    override init() {
        if let url = Bundle.main.url(forResource: "TypoReviewServerCA", withExtension: "crt"),
           let data = try? Data(contentsOf: url) {
            certificate = Self.makeCertificate(from: data)
        } else {
            certificate = nil
        }
        super.init()
    }

    private static func makeCertificate(from data: Data) -> SecCertificate? {
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            return certificate
        }
        guard let pem = String(data: data, encoding: .utf8) else { return nil }
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // The shared HTTPS gateway uses a publicly trusted certificate. Keep
        // accepting the bundled private CA as a fallback for the legacy
        // :18443 endpoint while devices transition to the standard :443 URL.
        var systemTrustError: CFError?
        if SecTrustEvaluateWithError(trust, &systemTrustError) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let certificate else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct ServerImportResponse: Decodable, Sendable {
    let ok: Bool
    let changed: [String: Int]
    let ignoredMediaAssets: Int
    let ignoredDuplicatePointEntries: Int
}

struct ServerDailyPlan: Codable, Sendable {
    struct Item: Codable, Sendable {
        let itemID: UUID
        let position: Int
        let completedEventID: UUID?
        let completedAt: Date?
    }

    let id: UUID
    let day: String
    let dailyLimit: Int
    let createdAt: Date
    let updatedAt: Date
    let items: [Item]
}

struct ServerReviewSubmission: Encodable, Sendable {
    let eventID: UUID
    let itemID: UUID
    let result: String
    let modeRawValue: String
    let reviewedAt: Date
    let note: String
}

struct ServerReviewResponse: Decodable, Sendable {
    let accepted: Bool
    let idempotent: Bool
    let item: ReviewItemSnapshot?
    let record: ReviewRecordSnapshot
}

struct ServerPairingResponse: Decodable, Sendable {
    let token: String
    let accountID: UUID
    let deviceID: UUID
}

struct ServerPairingCodeResponse: Decodable, Sendable {
    let code: String
    let persistent: Bool
}

actor ServerAPIClient {
    static let shared = ServerAPIClient()

    private let configuration: ServerAPIConfiguration?
    private let sessionDelegate: ServerPinnedCertificateDelegate
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(configuration: ServerAPIConfiguration? = .current) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 45
        sessionConfiguration.timeoutIntervalForResource = 180
        sessionConfiguration.waitsForConnectivity = true
        let sessionDelegate = ServerPinnedCertificateDelegate()
        self.sessionDelegate = sessionDelegate
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = .typoReviewISO8601
    }

    func health() async throws {
        let _: EmptyHealthResponse = try await request(path: "/health", method: "GET", authorized: false)
    }

    func pair(code: String, deviceName: String) async throws -> ServerPairingResponse {
        struct Body: Encodable {
            let code: String
            let deviceName: String
        }
        return try await request(
            path: "/v1/auth/pair",
            method: "POST",
            body: try encoder.encode(Body(code: code, deviceName: deviceName)),
            authorized: false
        )
    }

    func pairingCode() async throws -> ServerPairingCodeResponse {
        try await request(path: "/v1/auth/pairing-code", method: "GET")
    }

    func importSnapshot(_ payload: DataBackupPayload) async throws -> ServerImportResponse {
        try await request(
            path: "/v1/migration/import",
            method: "POST",
            body: try encoder.encode(payload)
        )
    }

    func exportSnapshot() async throws -> DataBackupPayload {
        try await request(path: "/v1/migration/export", method: "GET")
    }

    func dailyPlan(day: String, dailyLimit: Int) async throws -> ServerDailyPlan {
        struct Body: Encodable {
            let day: String
            let dailyLimit: Int
        }
        return try await request(
            path: "/v1/review/daily-plan",
            method: "POST",
            body: try encoder.encode(Body(day: day, dailyLimit: dailyLimit))
        )
    }

    func submitReview(_ submission: ServerReviewSubmission) async throws -> ServerReviewResponse {
        try await request(
            path: "/v1/review/submit",
            method: "POST",
            body: try encoder.encode(submission)
        )
    }

    func pushMutations(_ body: Data) async throws {
        let _: ServerMutationResponse = try await request(
            path: "/v1/sync/push",
            method: "POST",
            body: body
        )
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        body: Data? = nil,
        authorized: Bool = true
    ) async throws -> Response {
        guard let baseURL = configuration?.baseURL ?? ServerAPIConfiguration.serverURL else {
            throw ServerAPIError.notConfigured
        }
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if authorized {
            guard let token = configuration?.token else { throw ServerAPIError.notConfigured }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(1_024), encoding: .utf8) ?? "未知错误"
            throw ServerAPIError.rejected(statusCode: http.statusCode, message: message)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ServerAPIError.invalidResponse
        }
    }
}

private struct EmptyHealthResponse: Decodable {
    let status: String
}

private struct ServerMutationResponse: Decodable {
    let appliedMutationIDs: [UUID]
}
