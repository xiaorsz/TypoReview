import SwiftUI
import AVFoundation
import SwiftData

struct DictationSessionView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex = 0
    @State private var navigateToReview = false
    @State private var isContentRevealed = false
    @StateObject private var speaker = DictationSpeaker()

    let session: DictationSession
    let entries: [DictationEntry]

    private var currentEntry: DictationEntry? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    private var completionProgress: Double {
        Double(currentIndex + 1) / Double(max(entries.count, 1))
    }

    var body: some View {
        Group {
            if let currentEntry {
                GeometryReader { proxy in
                    let isWide = proxy.size.width >= 700

                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 22) {
                                    progressHeader
                                    sessionCard(for: currentEntry, isWide: isWide)
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
            }
        }
        .navigationTitle("今日听写")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToReview) {
            DictationReviewView(
                session: session,
                entries: entries,
                onReturnToList: {
                    dismiss()
                }
            )
        }
        .onAppear {
            if let currentEntry {
                speaker.prepare(content: currentEntry.content, type: currentEntry.type)
            }
        }
        .onChange(of: currentIndex) {
            isContentRevealed = false
            if let currentEntry {
                speaker.prepare(content: currentEntry.content, type: currentEntry.type)
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
                    Text("今日听写")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("第 \(currentIndex + 1) / \(entries.count) 条")
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

            ProgressView(value: Double(currentIndex + 1), total: Double(max(entries.count, 1)))
                .tint(.blue)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
                .animation(.easeInOut(duration: 0.3), value: currentIndex)
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func sessionCard(for entry: DictationEntry, isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            cardHeader(for: entry, isWide: isWide)
            
            speakButton(for: entry)
            
            HStack(alignment: .top) {
                helperFooter
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isContentRevealed.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isContentRevealed ? "eye.slash.fill" : "eye.fill")
                        Text(isContentRevealed ? "隐藏文字" : "显示文字")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color.blue.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if isContentRevealed {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.vertical, 8)
                    Text("听写内容")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(entry.content)
                        .font(.system(isWide ? .title : .title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.blue)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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

    private func cardHeader(for entry: DictationEntry, isWide: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TypeBadge(type: entry.type)

                    Text(session.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.prompt)
                        .font(.system(isWide ? .title : .title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
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

    private func speakButton(for entry: DictationEntry) -> some View {
        Button {
            speaker.speak(content: entry.content, type: entry.type)
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

    private var helperFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text("孩子先把整轮内容都写完，最后再统一批量判定。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bottomActionBar(isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Button("上一条") {
                currentIndex = max(currentIndex - 1, 0)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(Color(uiColor: currentIndex == 0 ? .systemBackground : .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(currentIndex == 0 ? Color.secondary : Color.blue)
            .disabled(currentIndex == 0)

            if currentIndex < entries.count - 1 {
                Button("下一条") {
                    currentIndex += 1
                }
                .buttonStyle(ResultButtonStyle(color: .blue))
            } else {
                Button("进入统一判定") {
                    finishSession()
                }
                .buttonStyle(ResultButtonStyle(color: .green))
            }
        }
        .padding(.horizontal, isWide ? 32 : 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
    }

    private func finishSession() {
        let now = Date()
        session.finishedAt = now
        session.updatedAt = now
        navigateToReview = true
    }
}
