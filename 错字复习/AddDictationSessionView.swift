import SwiftUI
import SwiftData
import Translation

struct AddDictationSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var type: ReviewItemType?
    @State private var title = ""
    @State private var scheduledDate: Date = .now
    @State private var defaultSource = ""
    @State private var rawText = ""
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var pendingSaveContext: PendingDictationSaveContext?
    @State private var showTypePickerAttention = false
    @State private var isTypeManuallyChosen: Bool

    var editingSession: DictationSession?
    var existingEntries: [DictationEntry]?

    init(editingSession: DictationSession? = nil, existingEntries: [DictationEntry]? = nil) {
        self.editingSession = editingSession
        self.existingEntries = existingEntries

        if let session = editingSession {
            _type = State(initialValue: session.type)
            _title = State(initialValue: session.title)
            _scheduledDate = State(initialValue: session.scheduledDate)

            if let entriesToEdit = existingEntries {
                let text = entriesToEdit
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map { entry in
                        var line = entry.content
                        if !entry.prompt.isEmpty || !entry.source.isEmpty {
                            line += " | \(entry.prompt)"
                        }
                        if !entry.source.isEmpty {
                            line += " | \(entry.source)"
                        }
                        return line
                    }
                    .joined(separator: "\n")
                _rawText = State(initialValue: text)
            }
        }

        _isTypeManuallyChosen = State(initialValue: editingSession != nil)
    }

    private var entries: [ParsedDictationEntry] {
        rawText
            .components(separatedBy: .newlines)
            .compactMap(ParsedDictationEntry.init(rawLine:))
    }

    private var canSave: Bool {
        !entries.isEmpty
    }

    private var content: some View {
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
        .navigationTitle(editingSession != nil ? "编辑听写计划" : "新增今日听写")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: rawText) { _, newValue in
            guard !isTypeManuallyChosen else { return }
            type = ReviewItemTypeInference.infer(from: newValue)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(editingSession != nil ? "完成修改" : "保存计划") {
                        Task {
                            await save()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
        .alert("保存失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
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
                            Text("正在使用 Apple 翻译补全单词释义")
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

    var body: some View {
        if #available(iOS 18.0, *) {
            content.translationTask(activeTranslationConfiguration) { @Sendable session in
                await handlePendingTranslation(using: session)
            }
        } else {
            content
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editingSession != nil ? "编辑听写计划" : "新增听写计划")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text(editingSession != nil ? "修改听写内容和日期，保存后即生效。" : "录入内容并指定日期，孩子只在当天看到任务。")
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
                Picker("类型", selection: Binding(
                    get: { type },
                    set: { newValue in
                        type = newValue
                        isTypeManuallyChosen = true
                    }
                )) {
                    Text("词句").tag(Optional(ReviewItemType.phrase))
                    Text("英语").tag(Optional(ReviewItemType.englishWord))
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.orange.opacity(showTypePickerAttention ? 0.18 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(showTypePickerAttention ? Color.orange : .clear, lineWidth: 2)
            }

            DatePicker("计划日期", selection: $scheduledDate, displayedComponents: .date)
                .font(.subheadline.weight(.medium))

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("听写标题", systemImage: "star.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                    
                    TextField("例如：Unit 5 听写", text: $title)
                        .font(.title2.weight(.medium))
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Label("默认来源 (可选)", systemImage: "tag.fill")
                        .font(.subheadline.weight(.bold))
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
        case .phrase?:
            return "欢迎\n认真 | 做事不马虎\n提醒 | 让别人注意 | 第三单元"
        case .englishWord?:
            return "apple\nbanana | 香蕉\norange | 橙子 | Unit 5"
        default:
            return "请先选择题目类型，再录入听写内容"
        }
    }

    private func save() async {
        guard !isSaving else { return }
        guard let selectedType = type else {
            flashTypePickerAttention()
            return
        }
        isSaving = true
        saveErrorMessage = nil
        
        let now = Date()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = trimmedTitle.isEmpty ? "\(scheduledDate.formatted(date: .abbreviated, time: .omitted))听写" : trimmedTitle
        let sourceFallback = defaultSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentEntries = entries

        let context = PendingDictationSaveContext(
            title: sessionTitle,
            scheduledDate: scheduledDate,
            type: selectedType,
            sourceFallback: sourceFallback,
            entries: currentEntries,
            createdAt: now
        )

        let needsTranslation = selectedType == .englishWord && currentEntries.contains { $0.prompt.isEmpty }
        if needsTranslation, #available(iOS 18.0, *) {
            pendingSaveContext = context
            return
        }

        await persist(context: context)
    }

    @available(iOS 18.0, *)
    private var activeTranslationConfiguration: TranslationSession.Configuration? {
        guard pendingSaveContext != nil else { return nil }
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        )
    }

    @available(iOS 18.0, *)
    private func handlePendingTranslation(using session: TranslationSession) async {
        guard let context = pendingSaveContext else { return }

        let pendingRequests: [TranslationSession.Request] = context.entries.enumerated().compactMap { pair in
            let (index, entry) = pair
            guard entry.prompt.isEmpty else { return nil }
            return TranslationSession.Request(sourceText: entry.content, clientIdentifier: String(index))
        }

        guard !pendingRequests.isEmpty else {
            pendingSaveContext = nil
            await persist(context: context)
            return
        }

        do {
            try await session.prepareTranslation()
            let responses = try await session.translations(from: pendingRequests)
            await applyTranslationResponses(responses, to: context)
        } catch {
            pendingSaveContext = nil
            isSaving = false
            saveErrorMessage = "Apple 翻译暂时不可用。请确认设备已安装需要的翻译语言，或先手动填写中文释义后再保存。"
        }
    }

    @available(iOS 18.0, *)
    private func applyTranslationResponses(
        _ responses: [TranslationSession.Response],
        to context: PendingDictationSaveContext
    ) async {
        var resolvedEntries = context.entries

        for response in responses {
            guard let identifier = response.clientIdentifier,
                  let index = Int(identifier),
                  resolvedEntries.indices.contains(index) else {
                continue
            }

            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { continue }
            resolvedEntries[index] = resolvedEntries[index].settingPrompt(to: translated)
        }

        pendingSaveContext = nil

        if resolvedEntries.contains(where: { $0.prompt.isEmpty }) {
            rawText = resolvedEntries.map(\.serializedLine).joined(separator: "\n")
        }

        await persist(
            context: PendingDictationSaveContext(
                title: context.title,
                scheduledDate: context.scheduledDate,
                type: context.type,
                sourceFallback: context.sourceFallback,
                entries: resolvedEntries,
                createdAt: context.createdAt
            )
        )
    }

    private func persist(context: PendingDictationSaveContext) async {
        let session: DictationSession
        if let existing = editingSession {
            session = existing
            session.title = context.title
            session.type = context.type
            session.scheduledDate = context.scheduledDate
            session.updatedAt = context.createdAt

            if let entriesToDelete = existingEntries {
                for entry in entriesToDelete {
                    modelContext.delete(entry)
                }
            }
        } else {
            session = DictationSession(
                title: context.title,
                type: context.type,
                createdAt: context.createdAt,
                updatedAt: context.createdAt,
                scheduledDate: context.scheduledDate
            )
            modelContext.insert(session)
        }

        for (index, entry) in context.entries.enumerated() {
            modelContext.insert(
                DictationEntry(
                    sessionID: session.id,
                    sortOrder: index,
                    type: context.type,
                    content: entry.content,
                    prompt: entry.prompt,
                    note: "",
                    source: entry.source.isEmpty ? context.sourceFallback : entry.source,
                    result: .pending,
                    createdAt: context.createdAt,
                    updatedAt: context.createdAt
                )
            )
        }

        do {
            try modelContext.save()
            isSaving = false
            dismiss()
        } catch {
            isSaving = false
            saveErrorMessage = "听写计划保存失败，请稍后再试。\(error.localizedDescription)"
        }
    }

    private func flashTypePickerAttention() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showTypePickerAttention = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showTypePickerAttention = false
                }
            }
        }
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

    init(content: String, prompt: String, source: String) {
        self.content = content
        self.prompt = prompt
        self.source = source
    }

    func settingPrompt(to prompt: String) -> ParsedDictationEntry {
        ParsedDictationEntry(content: content, prompt: prompt, source: source)
    }

    var serializedLine: String {
        var line = content
        if !prompt.isEmpty || !source.isEmpty {
            line += " | \(prompt)"
        }
        if !source.isEmpty {
            line += " | \(source)"
        }
        return line
    }
}

private struct PendingDictationSaveContext {
    let title: String
    let scheduledDate: Date
    let type: ReviewItemType
    let sourceFallback: String
    let entries: [ParsedDictationEntry]
    let createdAt: Date
}
