import SwiftUI

// MARK: - Result Button Style

struct ResultButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Stat Grid Card

struct StatGridCard: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Toast Overlay Modifier

struct ToastOverlay: ViewModifier {
    let message: String
    @Binding var isPresented: Bool
    var duration: Double = 1.2

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(message)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(.ultraThickMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 40)
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isPresented)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                            withAnimation {
                                isPresented = false
                            }
                        }
                    }
                }
            }
    }
}

extension View {
    func toast(_ message: String, isPresented: Binding<Bool>, duration: Double = 1.2) -> some View {
        modifier(ToastOverlay(message: message, isPresented: isPresented, duration: duration))
    }
}

// MARK: - Feedback Answer Overlay

struct AnswerFeedbackOverlay: View {
    let isCorrect: Bool
    @Binding var isVisible: Bool

    var body: some View {
        if isVisible {
            ZStack {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(isCorrect ? .green : .red)
                        .symbolEffect(.bounce, value: isVisible)

                    Text(isCorrect ? "答对了！" : "再加油！")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(isCorrect ? .green : .red)
                }
                .transition(.scale.combined(with: .opacity))
            }
            .onAppear {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(isCorrect ? .success : .error)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isVisible = false
                    }
                }
            }
        }
    }
}

// MARK: - Type Badge

struct TypeBadge: View {
    let type: ReviewItemType

    private var badgeColor: Color {
        switch type {
        case .chineseCharacter: return .orange
        case .phrase: return .blue
        case .englishWord: return .purple
        }
    }

    var body: some View {
        Text(type.rawValue)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor, in: Capsule())
    }
}

// MARK: - Stage Color Helper

extension Int {
    var stageColor: Color {
        switch self {
        case 0...2: return .red
        case 3...5: return .orange
        default: return .green
        }
    }
}
