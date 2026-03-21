import SwiftUI
import AVFoundation

struct BatchReviewSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0
    @State private var navigateToReview = false
    @StateObject private var speaker = BatchReviewSpeaker()

    let items: [ReviewItem]

    private var currentItem: ReviewItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    private var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(currentIndex) / Double(items.count)
    }

    private var completionProgress: Double {
        Double(currentIndex + 1) / Double(max(items.count, 1))
    }

    var body: some View {
        Group {
            if let item = currentItem {
                GeometryReader { proxy in
                    let isWide = proxy.size.width >= 700

                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 22) {
                                    progressHeader
                                    sessionCard(for: item, isWide: isWide)
                                }
                                .frame(maxWidth: isWide ? 860 : .infinity)
                                .padding(.horizontal, isWide ? 32 : 20)
                                .padding(.top, 20)
                                .padding(.bottom, 140)
                            }
                    .safeAreaInset(edge: .bottom) {
                        bottomActionBar(isWide: isWide)
                    }
                }
                .id(currentIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .navigationTitle("统一判卷")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToReview) {
            BatchReviewGradingView(
                items: items,
                onReturnFromCompletion: {
                    dismiss()
                }
            )
        }
        .onAppear {
            if let currentItem {
                speaker.prepare(currentItem)
            }
        }
        .onChange(of: currentIndex) {
            if let currentItem {
                speaker.prepare(currentItem)
            }
        }
        .onDisappear {
            speaker.stop()
        }
    }


    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("复习进行中")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("第 \(currentIndex + 1) / \(items.count) 题")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                }

                Spacer()

                Text("\(Int((completionProgress * 100).rounded()))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            }

            ProgressView(value: Double(currentIndex + 1), total: Double(max(items.count, 1)))
                .tint(.blue)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
                .animation(.easeInOut(duration: 0.3), value: currentIndex)
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func sessionCard(for item: ReviewItem, isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            cardHeader(for: item, isWide: isWide)
            speakButton(for: item)
            helperFooter(for: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isWide ? 32 : 24)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
                )
        )
        .shadow(color: .blue.opacity(0.08), radius: 24, y: 10)
    }

    private func cardHeader(for item: ReviewItem, isWide: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TypeBadge(type: item.type)

                    Label("阶段 \(item.stage)", systemImage: "square.stack.3d.up.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.stage.stageColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(item.stage.stageColor.opacity(0.12), in: Capsule())
                }
            }

            Spacer(minLength: 12)

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: isWide ? 24 : 20, weight: .medium))
                .foregroundStyle(.blue.opacity(0.45))
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func speakButton(for item: ReviewItem) -> some View {
        Button {
            speaker.speak(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: speaker.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                    .font(.title3.weight(.bold))
                Text(speaker.isSpeaking ? "正在朗读" : "点击朗读")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
        }
        .buttonStyle(ResultButtonStyle(color: speaker.isSpeaking ? .teal : .blue))
    }

    private func helperFooter(for item: ReviewItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(helperText(for: item))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bottomActionBar(isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Button("上一条") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentIndex = max(currentIndex - 1, 0)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(Color(uiColor: currentIndex == 0 ? .systemBackground : .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(currentIndex == 0 ? Color.secondary : Color.blue)
            .disabled(currentIndex == 0)

            if currentIndex < items.count - 1 {
                Button("下一条") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentIndex += 1
                    }
                }
                .buttonStyle(ResultButtonStyle(color: .blue))
            } else {
                Button("进入统一判定") {
                    navigateToReview = true
                }
                .buttonStyle(ResultButtonStyle(color: .green))
            }
        }
        .padding(.horizontal, isWide ? 32 : 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
    }

    private func helperText(for item: ReviewItem) -> String {
        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "会直接播放要写的内容，孩子整轮写完后，家长再统一判定。"
        }
        return "如果不看文字，也可以直接点击朗读来做听写。"
    }
}

// MARK: - Speech
@MainActor
private final class BatchReviewSpeaker: NSObject, ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var lastUtteranceText = ""
    private var lastType: ReviewItemType = .chineseCharacter

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare(_ item: ReviewItem) {
        lastUtteranceText = item.content
        lastType = item.type
        stop()
    }

    func speak(_ item: ReviewItem) {
        lastUtteranceText = item.content
        lastType = item.type
        speakCurrentText()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        SpeechAudioSession.deactivate()
        isSpeaking = false
    }

    private func speakCurrentText() {
        stop()
        SpeechAudioSession.activate()
        let utterance = AVSpeechUtterance(string: lastUtteranceText)
        utterance.voice = SpeechVoicePicker.voice(for: lastType)
        utterance.rate = lastType == .englishWord ? 0.42 : 0.36
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }
}

extension BatchReviewSpeaker: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        SpeechAudioSession.deactivate()
        isSpeaking = false
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        SpeechAudioSession.deactivate()
        isSpeaking = false
    }
}
