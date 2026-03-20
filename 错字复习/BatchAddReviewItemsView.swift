import SwiftUI
import SwiftData

struct BatchAddReviewItemsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var reviewItems: [ReviewItem]

    @State private var type: ReviewItemType = .chineseCharacter
    @State private var rawText = ""
    @State private var defaultSource = ""
    @State private var importSummary: BatchImportSummary?

    private var parsedLines: [BatchReviewLineResult] {
        rawText
            .components(separatedBy: .newlines)
            .enumerated()
            .map { index, rawLine in
                BatchReviewLineResult(lineNumber: index + 1, rawLine: rawLine)
            }
    }

    private var entries: [BatchReviewEntry] {
        parsedLines.compactMap(\.entry)
    }

    private var canImport: Bool {
        !entries.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

            ScrollView {
                VStack(spacing: 20) {
                    introCard
                    configCard
                    editorCard
                    formatCard
                    if let importSummary {
                        resultCard(summary: importSummary)
                    }
                }
                .padding(isWide ? 32 : 20)
                .frame(maxWidth: isWide ? 860 : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("批量录入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导入") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canImport)
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("一次导入多条内容")
                .font(.system(.title, design: .rounded, weight: .bold))

            Text("适合把当天写错的内容整体贴进来。当前批量录入按同一种类型处理。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(
                    LinearGradient(
                        colors: [.indigo.opacity(0.85), .blue.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("类型与来源")
                .font(.headline)

            Picker("类型", selection: $type) {
                ForEach(ReviewItemType.allCases) { itemType in
                    Text(itemType.rawValue).tag(itemType)
                }
            }
            .pickerStyle(.segmented)

            TextField("默认来源，可选，例如 语文听写 / 英语听写", text: $defaultSource)
                .textFieldStyle(.roundedBorder)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("批量内容")
                    .font(.headline)
                Spacer()
                Text(editorStatusText)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $rawText)
                .frame(minHeight: 220)
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

            Text("每行一条，支持这几种写法：")
                .foregroundStyle(.secondary)

            Text("`欢迎`")
                .font(.callout.monospaced())
            Text("`欢迎 | 高兴地接待别人`")
                .font(.callout.monospaced())
            Text("`apple | 苹果 | 英语听写`")
                .font(.callout.monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var placeholderText: String {
        switch type {
        case .chineseCharacter:
            return "睛\n辨 | 容易写成辩\n迎 | 走之旁的迎 | 语文听写"
        case .phrase:
            return "欢迎\n认真 | 做事不马虎\n提醒 | 让别人注意 | 语文听写"
        case .englishWord:
            return "apple\nbanana | 香蕉\norange | 橙子 | 英语听写"
        }
    }

    private var editorStatusText: String {
        let validCount = entries.count
        let invalidCount = parsedLines.filter(\.isInvalid).count

        if invalidCount == 0 {
            return "可导入 \(validCount) 条"
        }

        return "可导入 \(validCount) 条，跳过 \(invalidCount) 行"
    }

    @ViewBuilder
    private func resultCard(summary: BatchImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: summary.importedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(summary.importedCount > 0 ? .green : .orange)
                    .symbolEffect(.bounce, value: summary.importedCount)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.importedCount > 0 ? "导入成功！" : "导入结果")
                        .font(.title3.weight(.bold))
                    Text("成功导入 \(summary.importedCount) 条内容")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                resultPill(title: "成功导入", value: "\(summary.importedCount)", tint: .green)
                resultPill(title: "重复跳过", value: "\(summary.duplicateLines.count)", tint: .orange)
                resultPill(title: "无效行", value: "\(summary.invalidLines.count)", tint: .red)
            }

            if !summary.duplicateLines.isEmpty {
                Text("这些内容已存在，已跳过：")
                    .font(.subheadline.weight(.semibold))
                Text(summary.duplicateLines.map(\.displayText).joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !summary.invalidLines.isEmpty {
                Text("这些行格式无效，未导入：")
                    .font(.subheadline.weight(.semibold))
                Text(summary.invalidLines.map(\.displayText).joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("继续录入") {
                    importSummary = nil
                    rawText = ""
                }
                .buttonStyle(.bordered)

                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func resultPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private func save() {
        let sourceFallback = defaultSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingKeys = Set(
            reviewItems.map {
                BatchImportKey(type: $0.type, content: $0.content)
            }
        )

        var importedCount = 0
        var duplicateLines: [BatchReviewLineResult] = []
        var invalidLines: [BatchReviewLineResult] = []
        var seenInThisBatch = Set<BatchImportKey>()

        for line in parsedLines {
            guard let entry = line.entry else {
                if line.isInvalid {
                    invalidLines.append(line)
                }
                continue
            }

            let key = BatchImportKey(type: type, content: entry.content)
            if existingKeys.contains(key) || seenInThisBatch.contains(key) {
                duplicateLines.append(line)
                continue
            }

            modelContext.insert(
                ReviewItem(
                    type: type,
                    content: entry.content,
                    prompt: entry.prompt,
                    note: "",
                    source: entry.source.isEmpty ? sourceFallback : entry.source,
                    stage: 0,
                    nextReviewAt: .now
                )
            )
            seenInThisBatch.insert(key)
            importedCount += 1
        }

        importSummary = BatchImportSummary(
            importedCount: importedCount,
            duplicateLines: duplicateLines,
            invalidLines: invalidLines
        )
    }
}

private struct BatchImportSummary {
    let importedCount: Int
    let duplicateLines: [BatchReviewLineResult]
    let invalidLines: [BatchReviewLineResult]
}

private struct BatchImportKey: Hashable {
    let type: ReviewItemType
    let content: String

    init(type: ReviewItemType, content: String) {
        self.type = type
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct BatchReviewLineResult: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let rawLine: String
    let entry: BatchReviewEntry?

    init(lineNumber: Int, rawLine: String) {
        self.lineNumber = lineNumber
        self.rawLine = rawLine
        self.entry = BatchReviewEntry(rawLine: rawLine)
    }

    var isInvalid: Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && entry == nil
    }

    var displayText: String {
        let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "第 \(lineNumber) 行: \(text)"
    }
}

private struct BatchReviewEntry {
    let content: String
    let prompt: String
    let source: String

    init?(rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let first = parts.first, !first.isEmpty else { return nil }
        guard parts.count <= 3 else { return nil }

        self.content = first
        self.prompt = parts.count > 1 ? parts[1] : ""
        self.source = parts.count > 2 ? parts[2] : ""
    }
}
