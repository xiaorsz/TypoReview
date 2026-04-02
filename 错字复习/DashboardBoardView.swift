import SwiftUI
import SwiftData
import AVKit
import UIKit

struct DashboardBoardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MediaLibraryStore.self) private var mediaLibraryStore
    @Query(sort: \ReviewItem.nextReviewAt) private var reviewItems: [ReviewItem]
    @Query(sort: \ReviewRecord.reviewedAt, order: .reverse) private var reviewRecords: [ReviewRecord]
    @Query(sort: \DictationSession.createdAt, order: .reverse) private var dictationSessions: [DictationSession]
    @Query(sort: \DictationEntry.sortOrder) private var dictationEntries: [DictationEntry]
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var taskCompletions: [TaskCompletion]
    @Query(sort: \ScheduleItem.startTime) private var allSchedules: [ScheduleItem]
    @Query private var settings: [AppSettings]

    @State private var previousIdleTimerDisabled = false
    @State private var previousScreenBrightness: CGFloat?
    @State private var boardBaselineBrightness: Double = 0.6
    @State private var boardBrightness: Double = 0.45
    @State private var boardNow = Date.now
    @State private var playbackCoordinator = MediaPlaybackCoordinator()
    @State private var lastBoardInteractionAt = Date.now
    @State private var isExitButtonVisible = false

    private var childName: String {
        guard let settings = settings.first else { return "小朋友" }
        return settings.childName.isEmpty ? "小朋友" : settings.childName
    }

    private var dueItems: [ReviewItem] {
        reviewItems
            .filter { $0.nextReviewAt <= boardNow }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
    }

    private var pendingDictationSessions: [DictationSession] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: boardNow)
        return dictationSessions
            .filter { !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var pendingDictationCount: Int {
        pendingDictationSessions.reduce(into: 0) { result, session in
            result += dictationEntries.filter { $0.sessionID == session.id }.count
        }
    }

    private var pendingDictationBoardItems: [BoardTextItem] {
        pendingDictationSessions.flatMap { session in
            dictationEntries
                .filter { $0.sessionID == session.id }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { entry in
                    BoardTextItem(id: entry.id, text: entry.content, detail: "")
                }
        }
    }

    private var todayTaskItems: [TodayTaskDisplayItem] {
        TodayTaskListBuilder
            .build(from: allTasks.filter { !$0.isArchived }, completions: taskCompletions, on: boardNow)
    }

    private var todayPendingTasks: [TodayTaskDisplayItem] {
        todayTaskItems.filter { $0.section == .todayPending }
    }

    private var historicalPendingTasks: [TodayTaskDisplayItem] {
        todayTaskItems
            .filter { $0.section == .historicalPending }
            .sorted { lhs, rhs in
                if lhs.occurrenceDate == rhs.occurrenceDate {
                    return lhs.task.createdAt < rhs.task.createdAt
                }
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
    }

    private var todayCompletedTasks: [TodayTaskDisplayItem] {
        todayTaskItems.filter { $0.section == .todayDone }
    }

    private var boardTaskItems: [TodayTaskDisplayItem] {
        todayPendingTasks + historicalPendingTasks + todayCompletedTasks
    }

    private var totalPendingTaskCount: Int {
        todayPendingTasks.count + historicalPendingTasks.count
    }

    private var todaySchedules: [ScheduleItem] {
        allSchedules
            .filter { $0.shouldAppear(on: boardNow) && !$0.hasEnded(on: boardNow, reference: boardNow) }
            .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
    }

    private var boardSettings: AppSettings? {
        settings.first
    }

    private var enabledMediaAssets: [MediaLibraryAsset] {
        mediaLibraryStore.mediaAssets
            .filter(\.isIncludedInPlaylist)
            .sorted { lhs, rhs in
                if lhs.playlistOrder == rhs.playlistOrder {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.playlistOrder < rhs.playlistOrder
            }
    }

    private var todayHeadline: String {
        var parts: [String] = []
        if !todayPendingTasks.isEmpty {
            parts.append("\(todayPendingTasks.count) 项今日待办")
        }
        if !historicalPendingTasks.isEmpty {
            parts.append("\(historicalPendingTasks.count) 项历史待完成")
        }
        if !dueItems.isEmpty {
            parts.append("\(dueItems.count) 项复习")
        }
        if pendingDictationCount > 0 {
            parts.append("\(pendingDictationCount) 条听写")
        }
        return parts.isEmpty ? "\(childName) 今天都完成了" : "\(childName) 今天还有 \(parts.joined(separator: "、"))"
    }

    private var mediaAutoplayStatusText: String {
        guard let boardSettings else { return "未配置" }
        guard boardSettings.boardAutoplayEnabled else { return "已关闭" }
        guard boardSettings.hasValidBoardAutoplayWindow else { return "时间无效" }
        guard !enabledMediaAssets.isEmpty else { return "播放列表为空" }

        if let manualStatusText = playbackCoordinator.boardManualStatusText {
            return manualStatusText
        }

        if playbackCoordinator.isManuallyPaused {
            return "已暂停"
        }

        if playbackCoordinator.isPlaying {
            return "正在播放"
        }

        if playbackCoordinator.isWaitingForDownload {
            return "等待下载"
        }

        if let blockedReason = boardSettings.boardAutoplayBlockedReason(on: boardNow) {
            return blockedReason
        }

        if boardSettings.isBoardAutoplayActive(on: boardNow) {
            return "准备播放"
        }

        if let window = boardSettings.boardAutoplayWindow(on: boardNow), boardNow < window.start {
            return "等待开始"
        }

        return "今日已结束"
    }

    private var boardMediaPreviewHeight: CGFloat {
        240
    }

    private let boardTopAnchorID = "board-top-anchor"
    private let boardInactivityReturnInterval: TimeInterval = 30
    private let boardOverlayVisibilityInterval: TimeInterval = 8

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.12, blue: 0.22),
                            Color(red: 0.04, green: 0.33, blue: 0.47),
                            Color(red: 0.05, green: 0.52, blue: 0.48)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 28) {
                            Color.clear
                                .frame(height: 1)
                                .id(boardTopAnchorID)

                            boardHeader
                            boardStats
                            boardContent
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, boardTopInset(for: proxy))
                        .padding(.horizontal, 36)
                        .padding(.bottom, 28)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture().onChanged { _ in
                                recordBoardInteraction()
                            }
                        )
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                recordBoardInteraction()
                            }
                        )
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onReceive(boardInactivityTimer) { _ in
                        autoReturnBoardToTopIfNeeded(using: scrollProxy)
                    }

                    if isExitButtonVisible {
                        exitBoardButton
                            .padding(.top, topOverlayPadding(for: proxy))
                            .padding(.trailing, 28)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
            }
        }
        .onAppear {
            activateIdleTimerOverride()
            lastBoardInteractionAt = .now
            isExitButtonVisible = false
            syncBoardPlayback(for: boardNow)
        }
        .onDisappear {
            restoreIdleTimer()
            playbackCoordinator.stop()
        }
        .onReceive(boardRefreshTimer) {
            boardNow = $0
            applyScheduledBoardBrightness(for: $0)
            syncBoardPlayback(for: $0)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                boardNow = .now
                activateIdleTimerOverride()
                lastBoardInteractionAt = .now
                isExitButtonVisible = false
                syncBoardPlayback(for: boardNow)
            } else {
                isExitButtonVisible = false
                restoreIdleTimer()
                playbackCoordinator.stop()
            }
        }
    }

    private var boardHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("听写复习看板")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Button {
                        recordBoardInteraction()
                        playbackCoordinator.toggleManualPlayback(
                            playlist: enabledMediaAssets,
                            option: boardSettings?.boardManualPlaybackOption ?? .untilPlaylistEnds
                        )
                    } label: {
                        Image(systemName: playbackCoordinator.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(enabledMediaAssets.isEmpty && playbackCoordinator.currentAsset == nil)
                    .opacity((enabledMediaAssets.isEmpty && playbackCoordinator.currentAsset == nil) ? 0.45 : 1)
                    .accessibilityLabel(playbackCoordinator.isPlaying ? "暂停晨读资源播放" : "开始晨读资源播放")
                }

                Text(todayHeadline)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(context.date.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.top, -12)
        }
    }

    private var boardStats: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 18
            let unitWidth = max((proxy.size.width - spacing * 3) / 4, 0)
            let hasSchedule = todaySchedules.first != nil

            HStack(spacing: spacing) {
                BoardStatCard(title: "待办任务", value: "\(totalPendingTaskCount)", tint: .orange)
                    .frame(width: unitWidth)

                BoardStatCard(title: "待复习", value: "\(dueItems.count)", tint: .blue)
                    .frame(width: unitWidth)

                if hasSchedule {
                    BoardScheduleStatCard(schedule: todaySchedules.first, tint: .green)
                        .frame(width: unitWidth * 2 + spacing)
                } else {
                    BoardStatCard(title: "待听写", value: "\(pendingDictationCount)", tint: .teal)
                        .frame(width: unitWidth)

                    BoardScheduleStatCard(schedule: nil, tint: .green)
                        .frame(width: unitWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 112)
    }

    private var boardContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if playbackCoordinator.isPlaying {
                boardMediaPanel
            }

            HStack(alignment: .top, spacing: 18) {
                boardTaskColumn

                boardColumn(
                    title: "待复习",
                    icon: "book.closed.fill",
                    items: dueItems,
                    emptyTitle: "今天没有待复习",
                    itemText: { item in
                        let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        return prompt.isEmpty ? item.content : "\(item.content) · \(prompt)"
                    }
                )

                boardColumn(
                    title: "待听写",
                    icon: "text.book.closed.fill",
                    items: pendingDictationBoardItems,
                    emptyTitle: "今天没有待听写",
                    itemText: { item in
                        item.text
                    }
                )
            }
        }
    }

    private var boardMediaPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    Image(systemName: "music.note.tv")
                    Text("晨读自动播放")
                    Text(boardSettings?.boardAutoplayTimeSummary ?? "07:00 - 07:30")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

                Spacer()

                Text(mediaAutoplayStatusText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.15), in: Capsule())
            }

            if enabledMediaAssets.isEmpty {
                Label("播放列表还没有资源，请到资源库里导入音频或视频。", systemImage: "tray")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.vertical, 12)
            } else if playbackCoordinator.isWaitingForDownload {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        playbackCoordinator.pendingAssetTitle.map { "“\($0)” 正在从 iCloud 下载" } ?? "资源正在从 iCloud 下载",
                        systemImage: "icloud.and.arrow.down"
                    )
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))

                    Text("文件下载完成后，看板会继续自动播放。")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.vertical, 12)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    boardMediaPreviewCard
                    boardMediaQueueCard
                }
            }
        }
        .padding(22)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
    }

    private var boardMediaPreviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前资源")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            if let currentAsset = playbackCoordinator.currentAsset {
                if currentAsset.mediaType == .video {
                    VideoPlayer(player: playbackCoordinator.player)
                        .frame(height: boardMediaPreviewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 58))
                            .foregroundStyle(.white.opacity(0.92))

                        Text(currentAsset.title)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text("正在播放音频")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .padding(20)
                    .background(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.55), Color.cyan.opacity(0.36)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 24)
                    )
                    .frame(maxWidth: .infinity, minHeight: boardMediaPreviewHeight, maxHeight: boardMediaPreviewHeight)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "clock.badge")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("到时间后会从第一条资源开始播放")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text("只有看板保持打开时才会触发自动播放。")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, minHeight: boardMediaPreviewHeight, maxHeight: boardMediaPreviewHeight)
                .padding(20)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var boardMediaQueueCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("播放列表")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(enabledMediaAssets.prefix(6))) { asset in
                    HStack(spacing: 12) {
                        Image(systemName: asset.mediaType.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(asset.title)
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Text(asset.mediaType.rawValue)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }
                        }

                        Spacer()

                        if asset.id == playbackCoordinator.currentAsset?.id {
                            Text("播放中")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(asset.id == playbackCoordinator.currentAsset?.id ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: 18))
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture {
                        playbackCoordinator.play(
                            asset: asset,
                            within: enabledMediaAssets,
                            boardManualOption: boardSettings?.boardManualPlaybackOption ?? .untilPlaylistEnds
                        )
                    }
                }
            }

            if enabledMediaAssets.count > 6 {
                Text("还有 \(enabledMediaAssets.count - 6) 条资源未展示")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(width: 360, alignment: .topLeading)
    }

    private var boardTaskColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                Text("待办任务")
            }
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(.white)

            if boardTaskItems.isEmpty {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("今天没有任务")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(24)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(boardTaskItems.prefix(10))) { item in
                        boardTaskRow(item)
                    }

                    if boardTaskItems.count > 10 {
                        Text("还有 \(boardTaskItems.count - 10) 项未展示")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func boardColumn<Item: Identifiable>(
        title: String,
        icon: String,
        items: [Item],
        emptyTitle: String,
        itemText: @escaping (Item) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(.white)

            if items.isEmpty {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.25))
                    Text(emptyTitle)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(24)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.prefix(10))) { item in
                        Text(itemText(item))
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 20))
                    }

                    if items.count > 10 {
                        Text("还有 \(items.count - 10) 项未展示")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func boardTaskRow(_ item: TodayTaskDisplayItem) -> some View {
        let isDone = item.isCompleted
        let statusText: String? = switch item.section {
        case .todayDone:
            "已完成"
        case .historicalPending:
            item.overdueOriginText ?? "历史待完成"
        case .todayPending:
            nil
        }

        return HStack(spacing: 14) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isDone ? Color.green.opacity(0.95) : .white.opacity(0.72))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.task.title)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(isDone ? .white.opacity(0.68) : .white)
                    .strikethrough(isDone, color: .white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let statusText {
                    Text(statusText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(isDone ? Color.green.opacity(0.95) : Color.orange.opacity(0.95))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            (isDone ? Color.green.opacity(0.15) : Color.white.opacity(0.13)),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
            if isDone {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.green.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private func boardTopInset(for proxy: GeometryProxy) -> CGFloat {
        let isLandscape = isLandscapeBoardLayout(fallbackSize: proxy.size)
        let safeTop = isLandscape ? min(proxy.safeAreaInsets.top, 6) : max(proxy.safeAreaInsets.top, 8)
        return max(safeTop - 18, 0)
    }

    private func isLandscapeBoardLayout(fallbackSize: CGSize) -> Bool {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        if let activeScene {
            return activeScene.interfaceOrientation.isLandscape
        }
        return fallbackSize.width > fallbackSize.height
    }

    private func topOverlayPadding(for proxy: GeometryProxy) -> CGFloat {
        let isLandscape = isLandscapeBoardLayout(fallbackSize: proxy.size)
        let safeTop = isLandscape ? min(proxy.safeAreaInsets.top, 8) : max(proxy.safeAreaInsets.top, 12)
        return safeTop + 10
    }

    private var exitBoardButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.22), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var boardRefreshTimer: Timer.TimerPublisher {
        Timer.publish(every: 5, on: .main, in: .common)
    }

    private var boardInactivityTimer: Timer.TimerPublisher {
        Timer.publish(every: 1, on: .main, in: .common)
    }

    private func activateIdleTimerOverride() {
        let application = UIApplication.shared
        previousIdleTimerDisabled = application.isIdleTimerDisabled
        application.isIdleTimerDisabled = true

        if previousScreenBrightness == nil {
            let currentBrightness = UIScreen.main.brightness
            previousScreenBrightness = currentBrightness
            boardBaselineBrightness = Double(currentBrightness)
        }

        applyScheduledBoardBrightness(for: boardNow)
    }

    private func restoreIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled

        if let previousScreenBrightness {
            UIScreen.main.brightness = previousScreenBrightness
            self.previousScreenBrightness = nil
        }
    }

    private func applyScheduledBoardBrightness(for date: Date) {
        guard previousScreenBrightness != nil else { return }
        boardBrightness = scheduledBoardBrightness(for: date)
        UIScreen.main.brightness = CGFloat(boardBrightness)
    }

    private func syncBoardPlayback(for date: Date) {
        playbackCoordinator.sync(
            now: date,
            settings: boardSettings,
            playlist: enabledMediaAssets
        )
    }

    private func recordBoardInteraction() {
        lastBoardInteractionAt = .now
        if !isExitButtonVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExitButtonVisible = true
            }
        }
    }

    private func autoReturnBoardToTopIfNeeded(using scrollProxy: ScrollViewProxy) {
        if isExitButtonVisible, Date.now.timeIntervalSince(lastBoardInteractionAt) >= boardOverlayVisibilityInterval {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExitButtonVisible = false
            }
        }

        guard Date.now.timeIntervalSince(lastBoardInteractionAt) >= boardInactivityReturnInterval else { return }

        withAnimation(.easeInOut(duration: 0.35)) {
            scrollProxy.scrollTo(boardTopAnchorID, anchor: .top)
        }
        lastBoardInteractionAt = .now
    }

    private func scheduledBoardBrightness(for date: Date) -> Double {
        switch brightnessMode(for: date) {
        case .normal:
            return max(min(boardBaselineBrightness, 1.0), 0.1)
        case .dimmed:
            return min(boardBaselineBrightness, 0.12)
        }
    }

    private func brightnessMode(for date: Date) -> BoardBrightnessMode {
        let hour = Calendar.current.component(.hour, from: date)
        if (7..<8).contains(hour) || (16..<22).contains(hour) {
            return .normal
        }
        return .dimmed
    }
}

private enum BoardBrightnessMode {
    case normal
    case dimmed
}

private struct BoardTextItem: Identifiable {
    let id: UUID
    let text: String
    let detail: String
}

private struct BoardStatCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text(value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(tint.opacity(0.32), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct BoardScheduleStatCard: View {
    let schedule: ScheduleItem?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日日程")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            if let schedule {
                Text(schedule.title)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(schedule.timeRangeText(on: .now))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            } else {
                Text("0")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(tint.opacity(0.32), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}
