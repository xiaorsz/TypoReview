import SwiftUI
import SwiftData

struct AddReviewItemView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let existingItem: ReviewItem?
    @State private var type: ReviewItemType = .chineseCharacter
    @State private var content = ""
    @State private var prompt = ""
    @State private var note = ""
    @State private var source = ""
    @State private var showSaveToast = false

    init(item: ReviewItem? = nil) {
        self.existingItem = item
        _type = State(initialValue: item?.type ?? .chineseCharacter)
        _content = State(initialValue: item?.content ?? "")
        _prompt = State(initialValue: item?.prompt ?? "")
        _note = State(initialValue: item?.note ?? "")
        _source = State(initialValue: item?.source ?? "")
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
        VStack(alignment: .leading, spacing: 10) {
            Text(existingItem == nil ? "把今天写错的内容录进来" : "修改这条错题内容")
                .font(.system(.title, design: .rounded, weight: .bold))

            Text(existingItem == nil ? "录入后会自动进入今天待复习，孩子可以马上开始练，家长再手动判定对错。" : "修改后会直接更新题库和后续复习内容。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 28)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("类型")
                .font(.headline)

            Picker("类型", selection: $type) {
                ForEach(ReviewItemType.allCases) { itemType in
                    Text(itemType.rawValue).tag(itemType)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("录入内容")
                .font(.headline)

            TextField(contentLabel, text: $content)
                .textFieldStyle(.roundedBorder)

            TextField(promptLabel, text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            TextField("来源，例如 语文作业 / 英语听写", text: $source)
                .textFieldStyle(.roundedBorder)

            TextField("备注，可选", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("录入建议")
                .font(.headline)

            Text(exampleText)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var contentLabel: String {
        switch type {
        case .chineseCharacter:
            "正确汉字，例如 睛"
        case .phrase:
            "正确词语，例如 欢迎"
        case .englishWord:
            "正确单词，例如 apple"
        }
    }

    private var promptLabel: String {
        switch type {
        case .chineseCharacter:
            "题目提示，可选，例如 看拼音写汉字: yan jing de jing"
        case .phrase:
            "题目提示，可选，例如 根据意思写词语: 高兴地接待别人"
        case .englishWord:
            "题目提示，可选，例如 看中文写英文: 苹果"
        }
    }

    private var exampleText: String {
        switch type {
        case .chineseCharacter:
            "如果不填提示，复习时会直接朗读这个字，让孩子按听写方式来写。"
        case .phrase:
            "词语可以只录入本身，复习时直接朗读；如果想做填空题，再补提示。"
        case .englishWord:
            "单词可以直接按听写来播报；如果想要中文释义出题，再补提示。"
        }
    }

    private func save() {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingItem {
            existingItem.type = type
            existingItem.content = trimmedContent
            existingItem.prompt = trimmedPrompt
            existingItem.note = trimmedNote
            existingItem.source = trimmedSource
            existingItem.updatedAt = .now
        } else {
            modelContext.insert(
                ReviewItem(
                    type: type,
                    content: trimmedContent,
                    prompt: trimmedPrompt,
                    note: trimmedNote,
                    source: trimmedSource,
                    stage: 0,
                    nextReviewAt: .now
                )
            )
        }

        withAnimation {
            showSaveToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
        }
    }
}
