import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Query private var settingsList: [AppSettings]
    @AppStorage("reviewInteractionStyle") private var reviewStyle: ReviewInteractionStyle = .oneByOne

    private var settings: AppSettings? {
        settingsList.first
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
                // Child info card
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("孩子信息")
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("孩子名字")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("孩子名字", text: bind(\.childName))
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("每日题量")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Stepper("每日 \(settings?.dailyLimit ?? 15) 题", value: bind(\.dailyLimit), in: 5...30, step: 5)
                                .padding(12)
                                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                // Reminder card
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "bell.badge.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text("每日提醒")
                            .font(.headline)
                    }

                    DatePicker("提醒时间", selection: reminderDate, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                        .padding(12)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                // Review rules card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("复习规则")
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("复习模式")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("复习模式", selection: $reviewStyle) {
                            ForEach(ReviewInteractionStyle.allCases) { style in
                                Text(style.rawValue).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        Text(reviewStyle == .oneByOne ? "每提示一题，家长立刻确认对错。" : "自动连续报听写，最后家长统一批改。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                    }

                    Text("同一条内容在当天只会复习一次，答对或答错都会安排到之后的日期。系统按照艾宾浩斯遗忘曲线自动安排复习间隔。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)

                    // Review stages visual
                    VStack(alignment: .leading, spacing: 8) {
                        Text("复习阶段间隔")
                            .font(.caption.weight(.semibold))
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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                // Sync card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "icloud.fill")
                            .font(.title2)
                            .foregroundStyle(.cyan)
                        Text("数据同步")
                            .font(.headline)
                    }

                    Text("数据通过 iCloud 同步到同一 Apple ID 下的 iPhone 和 iPad。需要在两台设备上登录同一个 Apple ID。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)

                    HStack {
                        Text("当前状态")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(syncStatusStore.statusText)
                            .fontWeight(.semibold)
                    }
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))

                    Text(syncStatusStore.detailText)
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Button {
                        syncStatusStore.refresh(using: modelContext, trigger: .manual)
                    } label: {
                        HStack {
                            if syncStatusStore.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                                Text("同步检查中...")
                            } else {
                                Image(systemName: "arrow.clockwise.icloud")
                                Text("立即检查同步")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(syncStatusStore.isRefreshing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                // About card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.purple)
                        Text("关于")
                            .font(.headline)
                    }

                    Text("错字复习 — 帮助孩子按遗忘曲线复习写错的汉字、词语和英文单词。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)

                    Text("v1.0")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
            .padding(20)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("设置")
        .task {
            if settings == nil {
                modelContext.insert(AppSettings())
            }
        }
    }

    private func stageChip(_ text: String, stage: Int) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stage.stageColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stage.stageColor.opacity(0.12), in: Capsule())
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
