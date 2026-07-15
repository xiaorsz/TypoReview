import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReviewItem.updatedAt, order: .reverse) private var reviewItems: [ReviewItem]
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var stageFilter: LibraryStageFilter = .all
    @State private var displayedItemLimit = 50
    @State private var editingItemID: UUID?

    private let scheduler = ReviewScheduler()

    private var canonicalItems: [ReviewItem] {
        ReviewContentIdentity.canonicalReviewItems(from: reviewItems)
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private var filteredItems: [ReviewItem] {
        let now = Date()
        let scopedItems = canonicalItems.filter { item in
            matches(item, filter: filter, referenceDate: now) && matches(item, stageFilter: stageFilter)
        }

        guard !searchText.isEmpty else { return scopedItems }
        return scopedItems.filter {
            $0.content.localizedCaseInsensitiveContains(searchText) ||
            $0.prompt.localizedCaseInsensitiveContains(searchText) ||
            $0.source.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var displayedItems: [ReviewItem] {
        Array(filteredItems.prefix(displayedItemLimit))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(LibraryFilter.allCases) { item in
                                filterButton(item)
                            }
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(LibraryStageFilter.options) { item in
                                stageFilterButton(item)
                            }
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 6, trailing: 0))
            }

            if filteredItems.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    Text(emptyDescription)
                } actions: {
                    HStack {
                        NavigationLink {
                            AddReviewItemView()
                        } label: {
                            Text("单条录入")
                        }
                        .buttonStyle(.borderedProminent)

                        NavigationLink {
                            BatchAddReviewItemsView()
                        } label: {
                            Text("批量录入")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                ForEach(displayedItems) { item in
                    NavigationLink {
                        AddReviewItemView(item: item)
                    } label: {
                        libraryRow(item)
                    }
                    .iOS17SafeSwipeActions {
                        Button(role: .destructive) {
                            delete(item)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        Button {
                            togglePriority(item)
                        } label: {
                            Label(
                                item.isPriority ? "取消重点" : "设为重点",
                                systemImage: item.isPriority ? "star.slash" : "star.fill"
                            )
                        }
                        .tint(.orange)

                        Button {
                            editingItemID = item.id
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }

                paginationFooter
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .searchable(text: $searchText, prompt: "搜索词句或英语")
        .onChange(of: searchText) { _, _ in
            displayedItemLimit = 50
        }
        .navigationTitle("题库")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $editingItemID) { itemID in
            if let item = reviewItems.first(where: { $0.id == itemID }) {
                AddReviewItemView(item: item)
            } else {
                ContentUnavailableView("内容不存在", systemImage: "exclamationmark.triangle")
            }
        }
        .toolbar {
            Menu("新增", systemImage: "plus") {
                NavigationLink {
                    AddReviewItemView()
                } label: {
                    Label("单条录入", systemImage: "square.and.pencil")
                }

                NavigationLink {
                    BatchAddReviewItemsView()
                } label: {
                    Label("批量录入", systemImage: "text.badge.plus")
                }
            }
        }
    }

    private func matches(_ item: ReviewItem, filter: LibraryFilter, referenceDate: Date) -> Bool {
        switch filter {
        case .all:
            return true
        case .due:
            return ReviewScheduler.isDue(item.nextReviewAt, on: referenceDate)
        case .priority:
            return item.isPriority
        case .mastered:
            return scheduler.isMastered(item)
        }
    }

    private func filterCount(_ filter: LibraryFilter) -> Int {
        let now = Date()
        return canonicalItems.reduce(into: 0) { count, item in
            if matches(item, filter: filter, referenceDate: now) {
                count += 1
            }
        }
    }

    private func filterButton(_ item: LibraryFilter) -> some View {
        let isSelected = filter == item

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                filter = item
                displayedItemLimit = 50
            }
        } label: {
            HStack(spacing: 5) {
                Text(item.rawValue)
                Text("\(filterCount(item))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                isSelected ? item.tint : Color(uiColor: .secondarySystemGroupedBackground),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func matches(_ item: ReviewItem, stageFilter: LibraryStageFilter) -> Bool {
        switch stageFilter {
        case .all:
            return true
        case let .stage(stage):
            return item.reviewTrack != .dictationFollowUp && !item.isDictationPass && item.stage == stage
        case .dictationFollowUp:
            return item.reviewTrack == .dictationFollowUp || item.isDictationPass
        }
    }

    private func stageFilterCount(_ stageFilter: LibraryStageFilter) -> Int {
        let now = Date()
        return canonicalItems.reduce(into: 0) { count, item in
            if matches(item, filter: filter, referenceDate: now) && matches(item, stageFilter: stageFilter) {
                count += 1
            }
        }
    }

    private func stageFilterButton(_ item: LibraryStageFilter) -> some View {
        let isSelected = stageFilter == item

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                stageFilter = item
                displayedItemLimit = 50
            }
        } label: {
            HStack(spacing: 5) {
                Text(item.title)
                Text("\(stageFilterCount(item))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.indigo : Color(uiColor: .secondarySystemGroupedBackground),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if filteredItems.count > 50 {
            Section {
                VStack(spacing: 8) {
                    Text("已显示 \(displayedItems.count) / 共 \(filteredItems.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if displayedItems.count < filteredItems.count {
                        Button {
                            displayedItemLimit += 50
                        } label: {
                            Label("再加载 50 条", systemImage: "arrow.down.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private func libraryRow(_ item: ReviewItem) -> some View {
        let status = statusBadge(for: item)

        return HStack(alignment: .top, spacing: 12) {
            Text(typeLabel(for: item.type))
                .font(.system(size: item.type == .englishWord ? 10 : 13, weight: .bold, design: .rounded))
                .foregroundStyle(typeColor(for: item.type))
                .frame(width: 36, height: 36)
                .background(typeColor(for: item.type).opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.content)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    Text(status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(status.tint.opacity(0.09), in: Capsule())
                }

                Text(subtitle(for: item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if !item.source.isEmpty || item.isPriority {
                    HStack(spacing: 8) {
                        if !item.source.isEmpty {
                            Label(item.source, systemImage: "bookmark")
                                .lineLimit(1)
                        }

                        if item.isPriority {
                            priorityBadge
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func subtitle(for item: ReviewItem) -> String {
        if item.reviewTrack == .dictationFollowUp {
            return item.trackingSummaryText
        }

        let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            return prompt
        }

        return "听写模式：直接朗读 \(item.type.displayName)"
    }

    private var priorityBadge: some View {
        Label("重点", systemImage: "star.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.08), in: Capsule())
    }

    private func statusBadge(for item: ReviewItem) -> (title: String, tint: Color) {
        if scheduler.isMastered(item) {
            return ("已掌握", .green)
        }

        if ReviewScheduler.isDue(item.nextReviewAt) {
            let calendar = Calendar.current
            let reviewDay = ReviewScheduler.normalizedReviewDate(item.nextReviewAt, calendar: calendar)
            let today = calendar.startOfDay(for: .now)
            return reviewDay < today ? ("已逾期", .red) : ("今日待复习", .orange)
        }

        return (item.stageBadgeText, item.stageBadgeColor)
    }

    private func typeLabel(for type: ReviewItemType) -> String {
        switch type {
        case .chineseCharacter:
            return "字"
        case .phrase:
            return "词"
        case .englishWord:
            return "EN"
        }
    }

    private func typeColor(for type: ReviewItemType) -> Color {
        switch type {
        case .chineseCharacter:
            return .orange
        case .phrase:
            return .blue
        case .englishWord:
            return .purple
        }
    }

    private func togglePriority(_ item: ReviewItem) {
        item.isPriority.toggle()
        item.updatedAt = .now
        try? modelContext.save()
        AppDataChangeCenter.post()
    }

    private func delete(_ item: ReviewItem) {
        modelContext.delete(item)
        try? modelContext.save()
        AppDataChangeCenter.post()
    }

    private var emptyIcon: String {
        if stageFilter != .all {
            return "line.3.horizontal.decrease.circle"
        }

        switch filter {
        case .all: return "tray"
        case .due: return "clock.badge.checkmark"
        case .priority: return "exclamationmark.triangle"
        case .mastered: return "star.circle"
        }
    }

    private var emptyTitle: String {
        if stageFilter != .all {
            return "当前筛选下没有内容"
        }

        switch filter {
        case .all:
            return "题库还是空的"
        case .due:
            return "暂时没有待复习内容"
        case .priority:
            return "暂时没有重点复习内容"
        case .mastered:
            return "还没有已掌握内容"
        }
    }

    private var emptyDescription: String {
        if stageFilter != .all {
            return "“\(filter.rawValue)”中暂时没有“\(stageFilter.title)”的题目，可以切换其他阶段查看。"
        }

        switch filter {
        case .all:
            return "先录入今天写错的内容，后面就会按遗忘曲线自动安排复习。"
        case .due:
            return "今天到期的内容已经练完，或者还没到下一次复习日期。"
        case .priority:
            return "目前没有连续出错较多、需要重点盯住的内容。"
        case .mastered:
            return "再坚持复习几轮，掌握稳定后会出现在这里。"
        }
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case due = "待复习"
    case priority = "重点复习"
    case mastered = "已掌握"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .all: return .blue
        case .due: return .orange
        case .priority: return .orange
        case .mastered: return .green
        }
    }
}

private enum LibraryStageFilter: Hashable, Identifiable {
    case all
    case stage(Int)
    case dictationFollowUp

    static let options: [LibraryStageFilter] = [
        .all,
        .stage(0),
        .stage(1),
        .stage(2),
        .stage(3),
        .stage(4),
        .stage(5),
        .stage(6),
        .stage(7),
        .dictationFollowUp
    ]

    var id: String {
        switch self {
        case .all:
            return "all"
        case let .stage(stage):
            return "stage-\(stage)"
        case .dictationFollowUp:
            return "dictation-follow-up"
        }
    }

    var title: String {
        switch self {
        case .all:
            return "全部阶段"
        case let .stage(stage):
            return "阶段 \(stage)"
        case .dictationFollowUp:
            return "听写跟进"
        }
    }
}
