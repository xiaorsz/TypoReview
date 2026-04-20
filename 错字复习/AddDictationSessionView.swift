import SwiftUI
import SwiftData
import Translation
import NaturalLanguage

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
                            Text("正在使用 Apple 翻译补全更完整的单词释义")
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

        let pendingRequests = context.entries.enumerated().reduce(into: [TranslationSession.Request]()) { result, pair in
            let (index, entry) = pair
            guard entry.prompt.isEmpty else { return }
            result.append(contentsOf: translationCandidates(for: entry.content, at: index).map { candidate in
                TranslationSession.Request(
                    sourceText: candidate.sourceText,
                    clientIdentifier: candidate.identifier
                )
            })
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
        var translationsByEntryIndex: [Int: [RankedTranslation]] = [:]

        for response in responses {
            guard let identifier = response.clientIdentifier,
                  let metadata = TranslationRequestIdentifier(identifier: identifier),
                  resolvedEntries.indices.contains(metadata.entryIndex) else {
                continue
            }

            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { continue }
            translationsByEntryIndex[metadata.entryIndex, default: []].append(
                RankedTranslation(priority: metadata.priority, text: translated)
            )
        }

        for (index, translations) in translationsByEntryIndex {
            let mergedPrompt = mergeTranslatedGlosses(
                translations
                    .sorted { $0.priority < $1.priority }
                    .map(\.text)
            )
            guard !mergedPrompt.isEmpty else { continue }
            resolvedEntries[index] = resolvedEntries[index].settingPrompt(to: mergedPrompt)
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
            NotificationCenter.default.post(name: Notification.Name("appDataDidMutate"), object: nil)
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

    private func translationCandidates(for text: String, at index: Int) -> [TranslationCandidate] {
        let seedTerms = translationSeedTerms(for: text)
        return seedTerms.enumerated().map { offset, seedTerm in
            TranslationCandidate(
                sourceText: seedTerm,
                identifier: TranslationRequestIdentifier(entryIndex: index, priority: offset).rawValue
            )
        }
    }

    private func mergeTranslatedGlosses(_ translatedTexts: [String]) -> String {
        var mergedGlosses: [String] = []

        func appendGloss(_ gloss: String) {
            let normalized = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            guard !mergedGlosses.contains(normalized) else { return }
            mergedGlosses.append(normalized)
        }

        for text in translatedTexts {
            let components = text
                .replacingOccurrences(of: "（", with: "；")
                .replacingOccurrences(of: "）", with: "")
                .split(whereSeparator: { "；;、,，/".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if components.isEmpty {
                appendGloss(text)
            } else {
                for component in components {
                    appendGloss(component)
                }
            }
        }

        return mergedGlosses.prefix(4).joined(separator: "；")
    }

    private func translationSeedTerms(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var seedTerms: [String] = []

        func appendSeed(_ candidate: String?) {
            guard let candidate else { return }
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            guard !seedTerms.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else { return }
            seedTerms.append(normalized)
        }

        if isLikelySingleEnglishWord(trimmed) {
            appendSeed(englishLemma(for: trimmed))
            for candidate in englishBaseFormCandidates(for: trimmed) {
                appendSeed(candidate)
            }
        }

        appendSeed(trimmed)

        if seedTerms.count <= 3 {
            return seedTerms
        }

        var prioritizedSeeds = Array(seedTerms.prefix(2))
        if !prioritizedSeeds.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            prioritizedSeeds.append(trimmed)
        }
        return prioritizedSeeds
    }

    private func isLikelySingleEnglishWord(_ text: String) -> Bool {
        let pattern = "^[A-Za-z]+(?:['-][A-Za-z]+)*$"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func englishLemma(for word: String) -> String? {
        let lowercased = word.lowercased()
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = lowercased
        let range = lowercased.startIndex..<lowercased.endIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var resolvedLemma: String?

        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: options) { tag, tokenRange in
            guard tokenRange == range, let rawValue = tag?.rawValue else { return true }
            resolvedLemma = rawValue
            return false
        }

        guard let rawValue = resolvedLemma else { return nil }
        let lemma = rawValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !lemma.isEmpty,
              lemma.caseInsensitiveCompare(lowercased) != ComparisonResult.orderedSame else { return nil }
        return lemma
    }

    private func englishBaseFormCandidates(for word: String) -> [String] {
        let lowercased = word.lowercased()
        guard lowercased.count >= 4 else { return [] }

        var candidates: [String] = []

        func appendCandidate(_ candidate: String?) {
            guard let candidate else { return }
            guard candidate.count >= 3 else { return }
            guard candidate.range(of: "^[a-z]+(?:['-][a-z]+)*$", options: .regularExpression) != nil else { return }
            guard !candidates.contains(candidate), candidate != lowercased else { return }
            candidates.append(candidate)
        }

        if lowercased.hasSuffix("ies"), lowercased.count > 4 {
            appendCandidate(String(lowercased.dropLast(3)) + "y")
        }

        if lowercased.hasSuffix("ves"), lowercased.count > 4 {
            let stem = String(lowercased.dropLast(3))
            appendCandidate(stem + "f")
            appendCandidate(stem + "fe")
        }

        if ["ses", "xes", "zes", "ches", "shes", "oes"].contains(where: { lowercased.hasSuffix($0) }) {
            appendCandidate(String(lowercased.dropLast(2)))
        } else if lowercased.hasSuffix("s"), !lowercased.hasSuffix("ss"), lowercased.count > 4 {
            appendCandidate(String(lowercased.dropLast()))
        }

        if lowercased.hasSuffix("ied"), lowercased.count > 4 {
            appendCandidate(String(lowercased.dropLast(3)) + "y")
        } else if lowercased.hasSuffix("ed"), lowercased.count > 4 {
            let stem = String(lowercased.dropLast(2))
            appendCandidate(stem)
            appendCandidate(stem + "e")
            if let dedoubled = droppingTrailingDoubleConsonant(from: stem) {
                appendCandidate(dedoubled)
            }
        }

        if lowercased.hasSuffix("ing"), lowercased.count > 5 {
            let stem = String(lowercased.dropLast(3))
            appendCandidate(stem)
            appendCandidate(stem + "e")
            if let dedoubled = droppingTrailingDoubleConsonant(from: stem) {
                appendCandidate(dedoubled)
            }
        }

        if lowercased.hasSuffix("er"), lowercased.count > 4 {
            let stem = String(lowercased.dropLast(2))
            appendCandidate(stem)
            appendCandidate(stem + "e")
            if let dedoubled = droppingTrailingDoubleConsonant(from: stem) {
                appendCandidate(dedoubled)
            }
        }

        if lowercased.hasSuffix("est"), lowercased.count > 5 {
            let stem = String(lowercased.dropLast(3))
            appendCandidate(stem)
            appendCandidate(stem + "e")
            if let dedoubled = droppingTrailingDoubleConsonant(from: stem) {
                appendCandidate(dedoubled)
            }
        }

        return Array(candidates.prefix(2))
    }

    private func droppingTrailingDoubleConsonant(from text: String) -> String? {
        guard text.count >= 4 else { return nil }
        let characters = Array(text)
        guard characters.count >= 2,
              characters[characters.count - 1] == characters[characters.count - 2],
              !"aeiou".contains(characters[characters.count - 1]) else {
            return nil
        }
        return String(characters.dropLast())
    }
}

private struct TranslationCandidate {
    let sourceText: String
    let identifier: String
}

private struct RankedTranslation {
    let priority: Int
    let text: String
}

private struct TranslationRequestIdentifier {
    let entryIndex: Int
    let priority: Int

    init(entryIndex: Int, priority: Int) {
        self.entryIndex = entryIndex
        self.priority = priority
    }

    init?(identifier: String) {
        let parts = identifier.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let entryIndex = Int(parts[0]),
              let priority = Int(parts[1]) else {
            return nil
        }
        self.entryIndex = entryIndex
        self.priority = priority
    }

    var rawValue: String {
        "\(entryIndex)#\(priority)"
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
