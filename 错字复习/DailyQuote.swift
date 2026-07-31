import Foundation

struct DailyQuote: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case verified
        case encouragement

        var badgeTitle: String {
            switch self {
            case .verified:
                return "经典名言"
            case .encouragement:
                return "每日鼓励"
            }
        }
    }

    let id: String
    let dayKey: String
    let text: String
    let kind: Kind
    let attribution: String
    let explanation: String
    let action: String

    var nonemptyAttribution: String? {
        let value = attribution.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct DailyQuoteCache {
    private struct Entry: Codable {
        let quote: DailyQuote
    }

    static let standard = DailyQuoteCache()

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "dailyQuote.serverCache.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func load(for dayKey: String) -> DailyQuote? {
        guard let data = defaults.data(forKey: storageKey),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.quote.dayKey == dayKey else {
            return nil
        }
        return entry.quote
    }

    func save(_ quote: DailyQuote) {
        guard let data = try? JSONEncoder().encode(Entry(quote: quote)) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    static func shanghaiDayKey(for date: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")
            ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
