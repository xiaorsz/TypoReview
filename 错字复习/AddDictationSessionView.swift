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
    @State private var isSaving = false

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
                if isSaving {
                    ProgressView()
                } else {
                    Button("开始听写") {
                        Task {
                            await save()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
        .overlay {
            if isSaving {
                ZStack {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在生成听写计划...")
                            .font(.headline)
                        if type == .englishWord {
                            Text("系统正在自动翻译单词意思")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("新增听写计划")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text("录入内容并指定日期，孩子只在当天看到任务。")
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
                        colors: [.teal.opacity(0.9), .cyan.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("题目类型")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("类型", selection: $type) {
                    Text("词句").tag(ReviewItemType.phrase)
                    Text("英语").tag(ReviewItemType.englishWord)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            DatePicker("计划日期", selection: $scheduledDate, displayedComponents: .date)
                .font(.subheadline.weight(.medium))

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("听写标题", systemImage: "star.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                    
                    TextField("例如：Unit 5 听写", text: $title)
                        .font(.title2.weight(.medium))
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Label("默认来源 (可选)", systemImage: "tag.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.purple)
                    
                    TextField("输入所有错题共用的来源", text: $defaultSource)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("听写内容")
                        .font(.headline)
                    Text("共 \(entries.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Button {
                    rawText += " | "
                } label: {
                    HStack(spacing: 4) {
                        Text("|")
                            .font(.system(.body, design: .monospaced, weight: .bold))
                        Text("分隔符")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }

            PlaceholderTextEditor(text: $rawText, placeholder: placeholderText, minHeight: 240)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var formatCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 6) {
                Text("支持格式：每行一条，可用 | 分隔提示和来源。")
                Text("例如：`apple | 苹果` 或 `欢迎 | 高兴地接待`")
                    .font(.caption.monospaced())
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
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

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        
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

        let currentEntries = entries
        for (index, entry) in currentEntries.enumerated() {
            var prompt = entry.prompt
            
            // Auto translation for English if prompt is empty
            if type == .englishWord && prompt.isEmpty {
                if let translated = await DictationTranslationService.fetchTranslation(for: entry.content) {
                    prompt = translated
                }
            }
            
            modelContext.insert(
                DictationEntry(
                    sessionID: session.id,
                    sortOrder: index,
                    type: type,
                    content: entry.content,
                    prompt: prompt,
                    note: "",
                    source: entry.source.isEmpty ? sourceFallback : entry.source,
                    result: .pending,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        try? modelContext.save()
        isSaving = false
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
