import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum DataBackupError: LocalizedError {
    case unsupportedVersion(Int)
    case missingFileData

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "暂不支持导入这个备份版本（v\(version)）。请先升级到支持该备份格式的 App 版本。"
        case .missingFileData:
            return "无法读取备份文件内容，请重新选择文件后再试。"
        }
    }
}

struct DataBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var payload: DataBackupPayload

    init(payload: DataBackupPayload) {
        self.payload = payload
    }

    init(data: Data) throws {
        payload = try DataBackupPayload.decode(from: data)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw DataBackupError.missingFileData
        }
        try self.init(data: data)
    }

    static var empty: DataBackupDocument {
        DataBackupDocument(payload: .placeholder)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try payload.encodedData())
    }
}

struct DataBackupPayload: Codable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let appVersion: String
    let settings: AppSettingsSnapshot?
    let reviewItems: [ReviewItemSnapshot]
    let reviewRecords: [ReviewRecordSnapshot]
    let taskItems: [TaskItemSnapshot]
    let taskCompletions: [TaskCompletionSnapshot]
    let dictationSessions: [DictationSessionSnapshot]
    let dictationEntries: [DictationEntrySnapshot]
    let scheduleItems: [ScheduleItemSnapshot]
    let mediaAssets: [MediaAssetSnapshot]

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt
        case appVersion
        case settings
        case reviewItems
        case reviewRecords
        case taskItems
        case taskCompletions
        case dictationSessions
        case dictationEntries
        case scheduleItems
        case mediaAssets
    }

    init(
        version: Int = DataBackupPayload.currentVersion,
        exportedAt: Date = .now,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知版本",
        settings: AppSettingsSnapshot?,
        reviewItems: [ReviewItemSnapshot],
        reviewRecords: [ReviewRecordSnapshot],
        taskItems: [TaskItemSnapshot],
        taskCompletions: [TaskCompletionSnapshot],
        dictationSessions: [DictationSessionSnapshot],
        dictationEntries: [DictationEntrySnapshot],
        scheduleItems: [ScheduleItemSnapshot],
        mediaAssets: [MediaAssetSnapshot] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.settings = settings
        self.reviewItems = reviewItems
        self.reviewRecords = reviewRecords
        self.taskItems = taskItems
        self.taskCompletions = taskCompletions
        self.dictationSessions = dictationSessions
        self.dictationEntries = dictationEntries
        self.scheduleItems = scheduleItems
        self.mediaAssets = mediaAssets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        settings = try container.decodeIfPresent(AppSettingsSnapshot.self, forKey: .settings)
        reviewItems = try container.decode([ReviewItemSnapshot].self, forKey: .reviewItems)
        reviewRecords = try container.decode([ReviewRecordSnapshot].self, forKey: .reviewRecords)
        taskItems = try container.decode([TaskItemSnapshot].self, forKey: .taskItems)
        taskCompletions = try container.decode([TaskCompletionSnapshot].self, forKey: .taskCompletions)
        dictationSessions = try container.decode([DictationSessionSnapshot].self, forKey: .dictationSessions)
        dictationEntries = try container.decode([DictationEntrySnapshot].self, forKey: .dictationEntries)
        scheduleItems = try container.decode([ScheduleItemSnapshot].self, forKey: .scheduleItems)
        mediaAssets = try container.decodeIfPresent([MediaAssetSnapshot].self, forKey: .mediaAssets) ?? []
    }

    static var placeholder: DataBackupPayload {
        DataBackupPayload(
            settings: nil,
            reviewItems: [],
            reviewRecords: [],
            taskItems: [],
            taskCompletions: [],
            dictationSessions: [],
            dictationEntries: [],
            scheduleItems: [],
            mediaAssets: []
        )
    }

    static func capture(from modelContext: ModelContext, mediaAssets: [MediaLibraryAsset]) throws -> DataBackupPayload {
        let settings = try modelContext.fetch(FetchDescriptor<AppSettings>()).first.map(AppSettingsSnapshot.init)
        let reviewItems = try modelContext.fetch(FetchDescriptor<ReviewItem>()).map(ReviewItemSnapshot.init)
        let reviewRecords = try modelContext.fetch(FetchDescriptor<ReviewRecord>()).map(ReviewRecordSnapshot.init)
        let taskItems = try modelContext.fetch(FetchDescriptor<TaskItem>()).map(TaskItemSnapshot.init)
        let taskCompletions = try modelContext.fetch(FetchDescriptor<TaskCompletion>()).map(TaskCompletionSnapshot.init)
        let dictationSessions = try modelContext.fetch(FetchDescriptor<DictationSession>()).map(DictationSessionSnapshot.init)
        let dictationEntries = try modelContext.fetch(FetchDescriptor<DictationEntry>()).map(DictationEntrySnapshot.init)
        let scheduleItems = try modelContext.fetch(FetchDescriptor<ScheduleItem>()).map(ScheduleItemSnapshot.init)
        let mediaAssetSnapshots = mediaAssets.map(MediaAssetSnapshot.init)

        return DataBackupPayload(
            settings: settings,
            reviewItems: reviewItems,
            reviewRecords: reviewRecords,
            taskItems: taskItems,
            taskCompletions: taskCompletions,
            dictationSessions: dictationSessions,
            dictationEntries: dictationEntries,
            scheduleItems: scheduleItems,
            mediaAssets: mediaAssetSnapshots
        )
    }

    static func decode(from data: Data) throws -> DataBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload = try decoder.decode(DataBackupPayload.self, from: data)
        guard payload.version == currentVersion else {
            throw DataBackupError.unsupportedVersion(payload.version)
        }
        return payload
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "听写复习本备份-\(formatter.string(from: exportedAt))"
    }

    var summaryText: String {
        [
            settings == nil ? nil : "设置 1 条",
            "题库 \(reviewItems.count) 条",
            "复习记录 \(reviewRecords.count) 条",
            "待办 \(taskItems.count) 条",
            "完成记录 \(taskCompletions.count) 条",
            "听写计划 \(dictationSessions.count) 组",
            "听写条目 \(dictationEntries.count) 条",
            "日程 \(scheduleItems.count) 条",
            "晨读资源 \(mediaAssets.count) 条"
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

enum DataBackupService {
    static func makeDocument(
        from modelContext: ModelContext,
        mediaAssets: [MediaLibraryAsset]
    ) throws -> DataBackupDocument {
        DataBackupDocument(payload: try DataBackupPayload.capture(from: modelContext, mediaAssets: mediaAssets))
    }

    @MainActor
    static func restore(
        _ payload: DataBackupPayload,
        into modelContext: ModelContext,
        mediaLibraryStore: MediaLibraryStore
    ) throws {
        try deleteAll(AppSettings.self, in: modelContext)
        try deleteAll(ReviewItem.self, in: modelContext)
        try deleteAll(ReviewRecord.self, in: modelContext)
        try deleteAll(TaskItem.self, in: modelContext)
        try deleteAll(TaskCompletion.self, in: modelContext)
        try deleteAll(DictationSession.self, in: modelContext)
        try deleteAll(DictationEntry.self, in: modelContext)
        try deleteAll(ScheduleItem.self, in: modelContext)

        if let settings = payload.settings?.makeModel() {
            modelContext.insert(settings)
        }

        payload.reviewItems
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.reviewRecords
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.taskItems
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.taskCompletions
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.dictationSessions
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.dictationEntries
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.scheduleItems
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }

        _ = try AppSettings.ensureSingleton(in: modelContext)
        if modelContext.hasChanges {
            try modelContext.save()
        }
        try mediaLibraryStore.replaceAll(with: payload.mediaAssets.map { $0.makeModel() })
    }

    private static func deleteAll<Model: PersistentModel>(_ type: Model.Type, in modelContext: ModelContext) throws {
        try modelContext.fetch(FetchDescriptor<Model>()).forEach(modelContext.delete)
    }
}

struct AppSettingsSnapshot: Codable {
    let id: UUID
    let childName: String
    let dailyLimit: Int
    let remindHour: Int
    let remindMinute: Int
    let reviewInteractionStyleRawValue: String
    let boardAutoplayEnabled: Bool
    let boardAutoplayStartHour: Int
    let boardAutoplayStartMinute: Int
    let boardAutoplayEndHour: Int
    let boardAutoplayEndMinute: Int
    let boardAutoplayDurationMinutes: Int
    let boardAutoplaySlotsRawValue: String
    let boardManualPlaybackOptionRawValue: String
    let boardAutoplaySkipWeekends: Bool
    let boardAutoplaySkipChinaHolidays: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case childName
        case dailyLimit
        case remindHour
        case remindMinute
        case reviewInteractionStyleRawValue
        case boardAutoplayEnabled
        case boardAutoplayStartHour
        case boardAutoplayStartMinute
        case boardAutoplayEndHour
        case boardAutoplayEndMinute
        case boardAutoplayDurationMinutes
        case boardAutoplaySlotsRawValue
        case boardManualPlaybackOptionRawValue
        case boardAutoplaySkipWeekends
        case boardAutoplaySkipChinaHolidays
    }

    init(_ settings: AppSettings) {
        id = settings.id
        childName = settings.childName
        dailyLimit = settings.dailyLimit
        remindHour = settings.remindHour
        remindMinute = settings.remindMinute
        reviewInteractionStyleRawValue = settings.reviewInteractionStyleRawValue
        boardAutoplayEnabled = settings.boardAutoplayEnabled
        boardAutoplayStartHour = settings.boardAutoplayStartHour
        boardAutoplayStartMinute = settings.boardAutoplayStartMinute
        boardAutoplayEndHour = settings.boardAutoplayEndHour
        boardAutoplayEndMinute = settings.boardAutoplayEndMinute
        boardAutoplayDurationMinutes = settings.boardAutoplayDurationMinutes
        boardAutoplaySlotsRawValue = settings.boardAutoplaySlotsRawValue
        boardManualPlaybackOptionRawValue = settings.boardManualPlaybackOptionRawValue
        boardAutoplaySkipWeekends = settings.boardAutoplaySkipWeekends
        boardAutoplaySkipChinaHolidays = settings.boardAutoplaySkipChinaHolidays
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        childName = try container.decode(String.self, forKey: .childName)
        dailyLimit = try container.decode(Int.self, forKey: .dailyLimit)
        remindHour = try container.decode(Int.self, forKey: .remindHour)
        remindMinute = try container.decode(Int.self, forKey: .remindMinute)
        reviewInteractionStyleRawValue = try container.decode(String.self, forKey: .reviewInteractionStyleRawValue)
        boardAutoplayEnabled = try container.decodeIfPresent(Bool.self, forKey: .boardAutoplayEnabled)
            ?? AppSettings.defaultBoardAutoplayEnabled
        boardAutoplayStartHour = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayStartHour)
            ?? AppSettings.defaultBoardAutoplayStartHour
        boardAutoplayStartMinute = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayStartMinute)
            ?? AppSettings.defaultBoardAutoplayStartMinute
        boardAutoplayEndHour = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayEndHour)
            ?? AppSettings.defaultBoardAutoplayEndHour
        boardAutoplayEndMinute = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayEndMinute)
            ?? AppSettings.defaultBoardAutoplayEndMinute
        let legacyDuration = max(
            1,
            (boardAutoplayEndHour * 60 + boardAutoplayEndMinute) - (boardAutoplayStartHour * 60 + boardAutoplayStartMinute)
        )
        boardAutoplayDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayDurationMinutes)
            ?? legacyDuration
        boardAutoplaySlotsRawValue = try container.decodeIfPresent(String.self, forKey: .boardAutoplaySlotsRawValue)
            ?? ""
        boardManualPlaybackOptionRawValue = try container.decodeIfPresent(String.self, forKey: .boardManualPlaybackOptionRawValue)
            ?? AppSettings.defaultBoardManualPlaybackOption
        boardAutoplaySkipWeekends = try container.decodeIfPresent(Bool.self, forKey: .boardAutoplaySkipWeekends)
            ?? AppSettings.defaultBoardAutoplaySkipWeekends
        boardAutoplaySkipChinaHolidays = try container.decodeIfPresent(Bool.self, forKey: .boardAutoplaySkipChinaHolidays)
            ?? AppSettings.defaultBoardAutoplaySkipChinaHolidays
    }

    func makeModel() -> AppSettings {
        let settings = AppSettings(
            id: id,
            childName: childName,
            dailyLimit: dailyLimit,
            remindHour: remindHour,
            remindMinute: remindMinute,
            reviewInteractionStyle: ReviewInteractionStyle(rawValue: reviewInteractionStyleRawValue) ?? AppSettings.defaultReviewInteractionStyle,
            boardAutoplayEnabled: boardAutoplayEnabled,
            boardAutoplayStartHour: boardAutoplayStartHour,
            boardAutoplayStartMinute: boardAutoplayStartMinute,
            boardAutoplayEndHour: boardAutoplayEndHour,
            boardAutoplayEndMinute: boardAutoplayEndMinute,
            boardAutoplayDurationMinutes: boardAutoplayDurationMinutes,
            boardAutoplaySlots: nil,
            boardManualPlaybackOption: BoardManualPlaybackOption(rawValue: boardManualPlaybackOptionRawValue) ?? .untilPlaylistEnds,
            boardAutoplaySkipWeekends: boardAutoplaySkipWeekends,
            boardAutoplaySkipChinaHolidays: boardAutoplaySkipChinaHolidays
        )
        settings.reviewInteractionStyleRawValue = reviewInteractionStyleRawValue
        settings.boardAutoplaySlotsRawValue = boardAutoplaySlotsRawValue
        return settings
    }
}

struct ReviewItemSnapshot: Codable {
    let id: UUID
    let typeRawValue: String
    let content: String
    let prompt: String
    let note: String
    let source: String
    let stage: Int
    let nextReviewAt: Date
    let lastReviewedAt: Date?
    let consecutiveCorrectCount: Int
    let consecutiveWrongCount: Int
    let isPriority: Bool
    let isDictationPassRaw: Bool?
    let createdAt: Date
    let updatedAt: Date

    init(_ item: ReviewItem) {
        id = item.id
        typeRawValue = item.typeRawValue
        content = item.content
        prompt = item.prompt
        note = item.note
        source = item.source
        stage = item.stage
        nextReviewAt = item.nextReviewAt
        lastReviewedAt = item.lastReviewedAt
        consecutiveCorrectCount = item.consecutiveCorrectCount
        consecutiveWrongCount = item.consecutiveWrongCount
        isPriority = item.isPriority
        isDictationPassRaw = item.isDictationPassRaw
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }

    func makeModel() -> ReviewItem {
        let item = ReviewItem(
            id: id,
            type: ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter,
            content: content,
            prompt: prompt,
            note: note,
            source: source,
            stage: stage,
            nextReviewAt: nextReviewAt,
            lastReviewedAt: lastReviewedAt,
            consecutiveCorrectCount: consecutiveCorrectCount,
            consecutiveWrongCount: consecutiveWrongCount,
            isPriority: isPriority,
            isDictationPass: isDictationPassRaw ?? false,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        item.typeRawValue = typeRawValue
        item.isDictationPassRaw = isDictationPassRaw
        return item
    }
}

struct ReviewRecordSnapshot: Codable {
    let id: UUID
    let itemID: UUID
    let reviewedAt: Date
    let resultRawValue: String
    let modeRawValue: String
    let oldStage: Int
    let newStage: Int
    let note: String

    init(_ record: ReviewRecord) {
        id = record.id
        itemID = record.itemID
        reviewedAt = record.reviewedAt
        resultRawValue = record.resultRawValue
        modeRawValue = record.modeRawValue
        oldStage = record.oldStage
        newStage = record.newStage
        note = record.note
    }

    func makeModel() -> ReviewRecord {
        let record = ReviewRecord(
            id: id,
            itemID: itemID,
            reviewedAt: reviewedAt,
            result: ReviewResult(rawValue: resultRawValue) ?? .correct,
            mode: ReviewMode(rawValue: modeRawValue) ?? .scheduled,
            oldStage: oldStage,
            newStage: newStage,
            note: note
        )
        record.resultRawValue = resultRawValue
        record.modeRawValue = modeRawValue
        return record
    }
}

struct TaskItemSnapshot: Codable {
    let id: UUID
    let title: String
    let note: String
    let recurrenceJSON: String?
    let skipPolicyRawValue: String?
    let startDate: Date
    let endDate: Date?
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        note = task.note
        recurrenceJSON = task.recurrenceJSON
        skipPolicyRawValue = task.skipPolicyRawValue
        startDate = task.startDate
        endDate = task.endDate
        isArchived = task.isArchived
        createdAt = task.createdAt
        updatedAt = task.updatedAt
    }

    func makeModel() -> TaskItem {
        let task = TaskItem(
            id: id,
            title: title,
            note: note,
            recurrence: recurrenceJSON.map(TaskRecurrence.fromJSON) ?? .once,
            skipPolicy: skipPolicyRawValue.flatMap(TaskSkipPolicy.init(rawValue:)) ?? .skippable,
            startDate: startDate,
            endDate: endDate,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        task.recurrenceJSON = recurrenceJSON
        task.skipPolicyRawValue = skipPolicyRawValue
        return task
    }
}

struct TaskCompletionSnapshot: Codable {
    let id: UUID
    let taskID: UUID
    let completedDate: Date
    let completedAt: Date

    init(_ completion: TaskCompletion) {
        id = completion.id
        taskID = completion.taskID
        completedDate = completion.completedDate
        completedAt = completion.completedAt
    }

    func makeModel() -> TaskCompletion {
        TaskCompletion(
            id: id,
            taskID: taskID,
            completedDate: completedDate,
            completedAt: completedAt
        )
    }
}

struct DictationSessionSnapshot: Codable {
    let id: UUID
    let title: String
    let typeRawValue: String
    let createdAt: Date
    let updatedAt: Date
    let scheduledDate: Date
    let finishedAt: Date?
    let reviewedAt: Date?

    init(_ session: DictationSession) {
        id = session.id
        title = session.title
        typeRawValue = session.typeRawValue
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        scheduledDate = session.scheduledDate
        finishedAt = session.finishedAt
        reviewedAt = session.reviewedAt
    }

    func makeModel() -> DictationSession {
        let session = DictationSession(
            id: id,
            title: title,
            type: ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter,
            createdAt: createdAt,
            updatedAt: updatedAt,
            scheduledDate: scheduledDate,
            finishedAt: finishedAt,
            reviewedAt: reviewedAt
        )
        session.typeRawValue = typeRawValue
        return session
    }
}

struct DictationEntrySnapshot: Codable {
    let id: UUID
    let sessionID: UUID
    let sortOrder: Int
    let typeRawValue: String
    let content: String
    let prompt: String
    let note: String
    let source: String
    let resultRawValue: String
    let createdAt: Date
    let updatedAt: Date

    init(_ entry: DictationEntry) {
        id = entry.id
        sessionID = entry.sessionID
        sortOrder = entry.sortOrder
        typeRawValue = entry.typeRawValue
        content = entry.content
        prompt = entry.prompt
        note = entry.note
        source = entry.source
        resultRawValue = entry.resultRawValue
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
    }

    func makeModel() -> DictationEntry {
        let entry = DictationEntry(
            id: id,
            sessionID: sessionID,
            sortOrder: sortOrder,
            type: ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter,
            content: content,
            prompt: prompt,
            note: note,
            source: source,
            result: DictationResult(rawValue: resultRawValue) ?? .pending,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        entry.typeRawValue = typeRawValue
        entry.resultRawValue = resultRawValue
        return entry
    }
}

struct ScheduleItemSnapshot: Codable {
    let id: UUID
    let title: String
    let note: String
    let startTime: Date
    let endTime: Date
    let repeatRuleRawValue: String
    let weekdaysJSON: String
    let effectiveStartDate: Date
    let effectiveEndDate: Date?
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ schedule: ScheduleItem) {
        id = schedule.id
        title = schedule.title
        note = schedule.note
        startTime = schedule.startTime
        endTime = schedule.endTime
        repeatRuleRawValue = schedule.repeatRuleRawValue
        weekdaysJSON = schedule.weekdaysJSON
        effectiveStartDate = schedule.effectiveStartDate
        effectiveEndDate = schedule.effectiveEndDate
        isArchived = schedule.isArchived
        createdAt = schedule.createdAt
        updatedAt = schedule.updatedAt
    }

    func makeModel() -> ScheduleItem {
        let schedule = ScheduleItem(
            id: id,
            title: title,
            note: note,
            startTime: startTime,
            endTime: endTime,
            repeatRule: ScheduleRepeatRule(rawValue: repeatRuleRawValue) ?? .once,
            weekdays: (try? JSONDecoder().decode([Int].self, from: Data(weekdaysJSON.utf8))) ?? [],
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        schedule.repeatRuleRawValue = repeatRuleRawValue
        schedule.weekdaysJSON = weekdaysJSON
        return schedule
    }
}

struct MediaAssetSnapshot: Codable {
    let id: UUID
    let title: String
    let originalFilename: String
    let storedFilename: String
    let mediaTypeRawValue: String
    let storageScopeRawValue: String
    let playlistOrder: Int
    let isIncludedInPlaylist: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ asset: MediaLibraryAsset) {
        id = asset.id
        title = asset.title
        originalFilename = asset.originalFilename
        storedFilename = asset.storedFilename
        mediaTypeRawValue = asset.mediaTypeRawValue
        storageScopeRawValue = asset.storageScopeRawValue
        playlistOrder = asset.playlistOrder
        isIncludedInPlaylist = asset.isIncludedInPlaylist
        createdAt = asset.createdAt
        updatedAt = asset.updatedAt
    }

    func makeModel() -> MediaLibraryAsset {
        MediaLibraryAsset(
            id: id,
            title: title,
            originalFilename: originalFilename,
            storedFilename: storedFilename,
            mediaType: MediaAssetType(rawValue: mediaTypeRawValue) ?? .audio,
            storageScope: MediaStorageScope(rawValue: storageScopeRawValue) ?? .local,
            playlistOrder: playlistOrder,
            isIncludedInPlaylist: isIncludedInPlaylist,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
