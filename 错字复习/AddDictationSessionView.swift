import SwiftUI
import SwiftData

struct AddDictationSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var type: ReviewItemType = .chineseCharacter
    @State private var title = ""
    @State private var scheduledDate: Date = .now
    @State private var defaultSource = ""
    @State private var rawText = ""

    private var entries: [ParsedDictationEntry] {
        rawText
            .components(separatedBy: .newlines)
            .compactMap(ParsedDictationEntry.init(rawLine:))
    }

    private var canSave: Bool {
        !entries.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                introCard
                formCard
                editorCard
                formatCard
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("新增今日听写")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("开始听写") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("先导入要听写的内容，再指定听写日期")
                .font(.system(.title, design: .rounded, weight: .bold))
            Text("可以提前做好明后天的听写计划。孩子只会在指定日期或逾期时在首页看到任务。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(
                    LinearGradient(
                        colors: [.teal.opacity(0.9), .cyan.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("听写设置")
                .font(.headline)

            Picker("类型", selection: $type) {
                ForEach(ReviewItemType.allCases) { itemType in
                    Text(itemType.rawValue).tag(itemType)
                }
            }
            .pickerStyle(.segmented)

            DatePicker("计划听写日期", selection: $scheduledDate, displayedComponents: .date)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)

            TextField("听写标题，例如 3月19日英语听写", text: $title)
                .textFieldStyle(.roundedBorder)

            TextField("默认来源，可选，例如 第五单元 / 语文听写", text: $defaultSource)
                .textFieldStyle(.roundedBorder)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("听写内容")
                    .font(.headline)
                Spacer()
                Text("共 \(entries.count) 条")
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $rawText)
                .frame(minHeight: 240)
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topLeading) {
                    if rawText.isEmpty {
                        Text(placeholderText)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 20)
                    }
                }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var formatCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("格式说明")
                .font(.headline)
            Text("每行一条，支持这些格式：")
                .foregroundStyle(.secondary)
            Text("`欢迎`")
                .font(.callout.monospaced())
            Text("`欢迎 | 高兴地接待别人`")
                .font(.callout.monospaced())
            Text("`apple | 苹果 | 第五单元`")
                .font(.callout.monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var placeholderText: String {
        switch type {
        case .chineseCharacter:
            return "睛\n辨 | 容易和辩混淆\n迎 | 走之旁的迎 | 第三单元"
        case .phrase:
            return "欢迎\n认真 | 做事不马虎\n提醒 | 让别人注意 | 第三单元"
        case .englishWord:
            return "apple\nbanana | 香蕉\norange | 橙子 | Unit 5"
        }
    }

    private func save() {
        let now = Date()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = trimmedTitle.isEmpty ? "\(scheduledDate.formatted(date: .abbreviated, time: .omitted))听写" : trimmedTitle
        let sourceFallback = defaultSource.trimmingCharacters(in: .whitespacesAndNewlines)

        let session = DictationSession(
            title: sessionTitle, 
            type: type, 
            createdAt: now, 
            updatedAt: now, 
            scheduledDate: scheduledDate
        )
        modelContext.insert(session)

        for (index, entry) in entries.enumerated() {
            modelContext.insert(
                DictationEntry(
                    sessionID: session.id,
                    sortOrder: index,
                    type: type,
                    content: entry.content,
                    prompt: entry.prompt,
                    note: "",
                    source: entry.source.isEmpty ? sourceFallback : entry.source,
                    result: .pending,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        dismiss()
    }
}

private struct ParsedDictationEntry {
    let content: String
    let prompt: String
    let source: String

    init?(rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let first = parts.first, !first.isEmpty, parts.count <= 3 else { return nil }

        self.content = first
        self.prompt = parts.count > 1 ? parts[1] : ""
        self.source = parts.count > 2 ? parts[2] : ""
    }
}
