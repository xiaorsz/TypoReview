import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReviewItem.updatedAt, order: .reverse) private var reviewItems: [ReviewItem]
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all

    private let scheduler = ReviewScheduler()

    private var filteredItems: [ReviewItem] {
        let now = Date()
        let scopedItems = reviewItems.filter { item in
            switch filter {
            case .all:
                return true
            case .due:
                return item.nextReviewAt <= now
            case .priority:
                return item.isPriority
            case .mastered:
                return scheduler.isMastered(item)
            }
        }

        guard !searchText.isEmpty else { return scopedItems }
        return scopedItems.filter {
            $0.content.localizedCaseInsensitiveContains(searchText) ||
            $0.prompt.localizedCaseInsensitiveContains(searchText) ||
            $0.source.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("筛选", selection: $filter) {
                ForEach(LibraryFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .background(Color(uiColor: .systemBackground))

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
                List(filteredItems) { item in
                    NavigationLink {
                        AddReviewItemView(item: item)
                    } label: {
                        HStack(spacing: 14) {
                            // Type badge column
                            VStack {
                                TypeBadge(type: item.type)
                            }
                            .frame(width: 42)

                            // Content
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.content)
                                    .font(.headline)

                                Text(subtitle(for: item))
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                                    .lineLimit(2)

                                HStack(spacing: 8) {
                                    if !item.source.isEmpty {
                                        HStack(spacing: 4) {
                                            Image(systemName: "bookmark.fill")
                                                .font(.caption2)
                                            Text(item.source)
                                                .font(.caption)
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(.tertiary)
                                    }

                                    if item.isPriority {
                                        priorityBadge
                                    }
                                }
                            }

                            Spacer()

                            // Stage indicator
                            VStack(spacing: 4) {
                                Text("\(item.stage)")
                                    .font(.system(.title3, design: .rounded, weight: .bold))
                                    .foregroundStyle(item.stage.stageColor)
                                Text("阶段")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 42)
                        }
                    }
                    .padding(.vertical, 6)
                    .swipeActions {
                        Button(role: .destructive) {
                            modelContext.delete(item)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .searchable(text: $searchText, prompt: "搜索词句或英语")
        .navigationTitle("题库")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    MediaLibraryView()
                } label: {
                    Label("晨读资源", systemImage: "music.note.list")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
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
    }

    private func subtitle(for item: ReviewItem) -> String {
        let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            return prompt
        }

        return "听写模式：直接朗读 \(item.type.displayName)"
    }

    private var priorityBadge: some View {
        Label("重点复习", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .labelStyle(PriorityLabelStyle())
    }

    private var emptyIcon: String {
        switch filter {
        case .all: return "tray"
        case .due: return "clock.badge.checkmark"
        case .priority: return "exclamationmark.triangle"
        case .mastered: return "star.circle"
        }
    }

    private var emptyTitle: String {
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
        switch filter {
        case .all:
            return "先录入今天写错的内容，后面就会按遗忘曲线自动安排复习。"
        case .due:
            return "今天到期的内容已经练完，或者还没到下一次复习时间。"
        case .priority:
            return "目前没有连续出错较多、需要重点盯住的内容。"
        case .mastered:
            return "再坚持复习几轮，掌握稳定后会出现在这里。"
        }
    }
}

private struct PriorityLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .foregroundStyle(.orange)
            configuration.title
        }
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case due = "待复习"
    case priority = "重点复习"
    case mastered = "已掌握"

    var id: String { rawValue }
}
