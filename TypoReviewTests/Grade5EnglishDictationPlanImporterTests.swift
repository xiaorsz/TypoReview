import XCTest
import SwiftData
@testable import TypoReview

final class Grade5EnglishDictationPlanImporterTests: XCTestCase {
    func testPlanHasFortyConsecutiveDaysStartingJuly15() {
        let plan = Grade5EnglishDictationPlanImporter.plan

        XCTAssertEqual(plan.count, 40)
        XCTAssertEqual(plan.map(\.dayNumber), Array(1...40))
        XCTAssertEqual(Set(plan.map(\.id)).count, 40)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: plan.first!.scheduledDate),
            DateComponents(year: 2026, month: 7, day: 15)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: plan.last!.scheduledDate),
            DateComponents(year: 2026, month: 8, day: 23)
        )
    }

    func testPlanPreservesTextbookVocabularyAndUnitOrder() {
        let plan = Grade5EnglishDictationPlanImporter.plan
        let entries = plan.flatMap(\.entries)

        XCTAssertEqual(entries, Grade5EnglishDictationPlanImporter.vocabulary)
        XCTAssertEqual(entries.count, 119)
        XCTAssertEqual(entries.filter(\.isLevelTwo).count, 55)
        XCTAssertEqual(entries.filter(\.isRequired).count, 46)
        XCTAssertTrue(plan.allSatisfy { (2...4).contains($0.entries.count) })

        XCTAssertEqual(Dictionary(grouping: entries, by: \.unit).mapValues(\.count), [
            1: 18,
            2: 17,
            3: 20,
            4: 20,
            5: 21,
            6: 23
        ])
        XCTAssertEqual(Dictionary(grouping: plan, by: \.unit).mapValues(\.count), [
            1: 6,
            2: 6,
            3: 7,
            4: 7,
            5: 7,
            6: 7
        ])
    }

    func testKnownFirstAndLastEntriesStayStable() {
        let plan = Grade5EnglishDictationPlanImporter.plan

        XCTAssertEqual(plan.first?.entries.first?.word, "team")
        XCTAssertEqual(plan.first?.entries.first?.meaning, "（游戏或运动的）队；（一起工作的）组，班")
        XCTAssertEqual(plan.last?.entries.last?.word, "bring")
        XCTAssertEqual(plan.last?.entries.last?.meaning, "带……到某处；带来；取来")
        XCTAssertEqual(plan.first?.title, "五上英语听写 第01天｜Unit 1 Different friends")
        XCTAssertEqual(plan.last?.title, "五上英语听写 第40天｜Unit 6 Nature and us")
    }

    @MainActor
    func testImportIsIdempotentAndCreatesEnglishPrompts() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let first = try Grade5EnglishDictationPlanImporter.importPlan(in: context)
        XCTAssertEqual(first.insertedSessions, 40)
        XCTAssertEqual(first.refreshedSessions, 0)
        XCTAssertEqual(first.insertedEntries, 119)

        let second = try Grade5EnglishDictationPlanImporter.importPlan(in: context)
        XCTAssertEqual(second.insertedSessions, 0)
        XCTAssertEqual(second.refreshedSessions, 40)
        XCTAssertEqual(second.insertedEntries, 119)

        let sessions = try context.fetch(FetchDescriptor<DictationSession>())
        let entries = try context.fetch(FetchDescriptor<DictationEntry>())
        XCTAssertEqual(sessions.count, 40)
        XCTAssertEqual(entries.count, 119)
        XCTAssertTrue(sessions.allSatisfy { $0.type == .englishWord })
        XCTAssertTrue(entries.allSatisfy {
            $0.type == .englishWord && !$0.prompt.isEmpty && $0.source == Grade5EnglishDictationPlanImporter.planSource
        })
    }

    @MainActor
    func testAutomaticImportRunsOnlyOnce() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let suiteName = "Grade5EnglishDictationPlanImporterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try Grade5EnglishDictationPlanImporter.importIfNeeded(
            in: context,
            defaults: defaults
        )
        let second = try Grade5EnglishDictationPlanImporter.importIfNeeded(
            in: context,
            defaults: defaults
        )

        XCTAssertEqual(first?.insertedSessions, 40)
        XCTAssertNil(second)
        XCTAssertTrue(defaults.bool(forKey: Grade5EnglishDictationPlanImporter.automaticImportKey))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DictationSession>()), 40)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DictationEntry>()), 119)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            DictationSession.self,
            DictationEntry.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
