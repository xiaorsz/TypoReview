import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Query private var settingsList: [AppSettings]

    private var settings: AppSettings? {
        settingsList.first
    }

    private var reviewStyle: Binding<ReviewInteractionStyle> {
        Binding(
            get: { settings?.reviewInteractionStyle ?? AppSettings.defaultReviewInteractionStyle },
            set: { newValue in settings?.reviewInteractionStyle = newValue }
        )
    }

    /// Binding for the reminder time as a Date
    private var reminderDate: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = settings?.remindHour ?? 19
                components.minute = settings?.remindMinute ?? 30
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings?.remindHour = components.hour ?? 19
                settings?.remindMinute = components.minute ?? 30
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                introCard
                childInfoCard
                reminderCard
                reviewCard
                syncCard
                aboutCard
            }
            .padding(20)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("通用设置")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text("调整复习偏好、通知以及数据同步状态。")
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
                        colors: [.gray.opacity(0.85), .secondary.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var childInfoCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("孩子名字", systemImage: "person.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.blue)
                
                TextField("输入孩子名字", text: bind(\.childName))
                    .font(.title2.weight(.medium))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("每日题量", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                
                HStack {
                    Text("\(settings?.dailyLimit ?? 15) 题")
                        .font(.title2.weight(.medium))
                    Spacer()
                    Stepper("", value: bind(\.dailyLimit), in: 5...30, step: 5)
                        .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var reminderCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("每日提醒")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                DatePicker("", selection: reminderDate, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("复习模式")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("复习模式", selection: reviewStyle) {
                    ForEach(ReviewInteractionStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Text(reviewStyle.wrappedValue == .oneByOne ? "提示：每报一题，家长立刻确认对错。" : "提示：连续报听写，最后统一批改。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("阶段复习间隔 (艾宾浩斯曲线)", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)

                Text("同一题目当天只复习一次。答对或答错会自动安排后续复习。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    stageChip("20分", stage: 1)
                    stageChip("1天", stage: 2)
                    stageChip("2天", stage: 3)
                    stageChip("4天", stage: 4)
                    stageChip("7天", stage: 5)
                    stageChip("15天", stage: 6)
                    stageChip("30天", stage: 7)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("数据同步")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(syncStatusStore.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
            }

            Text("数据通过 iCloud 同步到同一 Apple ID 下的设备。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("诊断信息", systemImage: "stethoscope")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 10) {
                    diagnosticRow(title: "同步模式", value: syncStatusStore.cloudKitModeText)
                    diagnosticRow(title: "iCloud 账户", value: syncStatusStore.cloudAccountTitle)
                    diagnosticRow(title: "CloudKit 环境", value: syncStatusStore.cloudKitEnvironment)
                    diagnosticRow(title: "推送环境", value: syncStatusStore.apsEnvironment)
                    diagnosticRow(title: "容器 ID", value: syncStatusStore.containerIdentifier, monospaced: true)
                    diagnosticRow(title: "本地数据", value: syncStatusStore.localDataSummary)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("同步说明", systemImage: "icloud.and.arrow.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)

                Text(syncStatusStore.cloudAccountDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !syncStatusStore.cloudKitEnabled {
                    Text("当前这台设备已经退回本地存储模式，所以它不会和其他设备互相同步。常见原因是 CloudKit schema 没同步到后台，或这台设备当前构建无法初始化 CloudKit。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !syncStatusStore.cloudKitInitializationError.isEmpty {
                    Text(syncStatusStore.cloudKitInitializationError)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                Text("如果 iPad 和 iPhone 里有一台是 Xcode 直接安装，另一台是 TestFlight / App Store 安装，它们会落在不同的 CloudKit 环境里，看起来就像一直同步不过来。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await syncStatusStore.refresh(using: modelContext, trigger: .manual)
                }
            } label: {
                HStack {
                    if syncStatusStore.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                        Text("检查中...")
                    } else {
                        Image(systemName: "arrow.clockwise.icloud")
                        Text("立即检查")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(syncStatusStore.isRefreshing)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var aboutCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "app.badge.fill")
                .font(.title)
                .foregroundStyle(.indigo)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("听写复习本")
                    .font(.headline)
                Text("结合艾宾浩斯遗忘曲线，帮助孩子高效攻克写错的词句和英语内容。")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func stageChip(_ text: String, stage: Int) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stage.stageColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stage.stageColor.opacity(0.12), in: Capsule())
    }

    private func diagnosticRow(title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
    }

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings?[keyPath: keyPath] ?? defaultValue(for: keyPath) },
            set: { newValue in settings?[keyPath: keyPath] = newValue }
        )
    }

    private func defaultValue<Value>(for keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Value {
        AppSettings()[keyPath: keyPath]
    }
}
