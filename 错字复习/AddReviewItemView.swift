import SwiftUI
import SwiftData

struct AddReviewItemView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let existingItem: ReviewItem?
    @State private var type: ReviewItemType?
    @State private var content = ""
    @State private var prompt = ""
    @State private var note = ""
    @State private var source = ""
    @State private var showSaveToast = false
    @State private var showTypePickerAttention = false
    @State private var isTypeManuallyChosen: Bool

    init(item: ReviewItem? = nil) {
        self.existingItem = item
        _type = State(initialValue: item?.type)
        _content = State(initialValue: item?.content ?? "")
        _prompt = State(initialValue: item?.prompt ?? "")
        _note = State(initialValue: item?.note ?? "")
        _source = State(initialValue: item?.source ?? "")
        _isTypeManuallyChosen = State(initialValue: item != nil)
    }

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

            ScrollView {
                VStack(spacing: 20) {
                    introCard

                    VStack(spacing: 18) {
                        typePicker
                        inputCard
                        tipsCard
                    }
                    .frame(maxWidth: isWide ? 780 : .infinity)
                }
                .padding(isWide ? 32 : 20)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: content) { _, newValue in
            guard !isTypeManuallyChosen else { return }
            type = ReviewItemTypeInference.infer(from: newValue)
        }
        .toast("已保存 ✓", isPresented: $showSaveToast, duration: 0.8)
        .navigationTitle(existingItem == nil ? "新增错题" : "编辑错题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if existingItem == nil {
                    NavigationLink {
                        BatchAddReviewItemsView()
                    } label: {
                        Text("批量录入")
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(existingItem == nil ? "保存" : "完成") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(existingItem == nil ? "录入新错题" : "编辑错题")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text(existingItem == nil ? "录入后会自动进入今天待复习。" : "修改后将同步更新题库内容。")
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
                        colors: [.mint.opacity(0.85), .cyan.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var typePicker: some View {
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
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section 1: Core Content
            VStack(alignment: .leading, spacing: 10) {
                Label("核心内容", systemImage: "star.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                
                TextField(contentLabel, text: $content)
                    .font(.title2.weight(.medium))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            // Section 2: Source
            VStack(alignment: .leading, spacing: 10) {
                Label("来源 (例如: 语文作业)", systemImage: "tag.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                
                TextField("输入错题来源", text: $source)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            Divider()

            // Section 3: Meta info
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField(promptLabel, text: $prompt)
                        .textFieldStyle(.plain)
                }
                
                HStack(spacing: 12) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField("备注记录重点或心得", text: $note)
                        .textFieldStyle(.plain)
                }
            }
            .font(.subheadline)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .bottom) {
            if existingItem == nil {
                Button {
                    save(keepOpen: true)
                } label: {
                    Label("保存并继续录入下一条", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                }
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .padding(20)
                .offset(y: 80)
            }
        }
        .padding(.bottom, existingItem == nil ? 80 : 0)
    }

    private var tipsCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(exampleText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var contentLabel: String {
        switch type {
        case .phrase?:
            "正确词句，例如 欢迎 / 在家休息"
        case .englishWord?:
            "正确英语，例如 apple / good morning"
        default:
            "先选择题目类型"
        }
    }

    private var promptLabel: String {
        switch type {
        case .phrase?:
            "题目提示，可选，例如 根据意思写词句: 高兴地接待别人"
        case .englishWord?:
            "题目提示，可选，例如 看中文写英语: 苹果"
        default:
            "题目提示，可选"
        }
    }

    private var exampleText: String {
        switch type {
        case .phrase?:
            "如果要练词句填空，可补全提示；如果不填，复习时会直接朗读词句。"
        case .englishWord?:
            "英语单词可以直接按听写来播报；如果想要中文释义出题，再补提示。"
        default:
            "请先选择题目类型，再录入内容。"
        }
    }

    private func save(keepOpen: Bool = false) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }
        guard let selectedType = type else {
            flashTypePickerAttention()
            return
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingItem {
            existingItem.type = selectedType
            existingItem.content = trimmedContent
            existingItem.prompt = trimmedPrompt
            existingItem.note = trimmedNote
            existingItem.source = trimmedSource
            existingItem.updatedAt = .now
        } else {
            modelContext.insert(
                ReviewItem(
                    type: selectedType,
                    content: trimmedContent,
                    prompt: trimmedPrompt,
                    note: trimmedNote,
                    source: trimmedSource,
                    stage: 0,
                    nextReviewAt: .now
                )
            )
        }

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        if keepOpen {
            withAnimation {
                showSaveToast = true
                content = ""
                prompt = ""
                // Keep source and note usually for continuous entry from same source
            }
        } else {
            withAnimation {
                showSaveToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dismiss()
            }
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
