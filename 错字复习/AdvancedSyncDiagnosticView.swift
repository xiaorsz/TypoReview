import SwiftUI
import SwiftData

struct AdvancedSyncDiagnosticView: View {
    private static let defaultVisibleCloudKitEventCount = 6

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @State private var purgeResultMessage = ""
    @State private var showPurgeConfirm = false

    var body: some View {
        Form {
            Section {
                diagnosticRow(title: "当前存储", value: syncStatusStore.storageModeTitle)
                diagnosticRow(title: "同步模式", value: syncStatusStore.cloudKitModeText)
                diagnosticRow(title: "iCloud 账户", value: syncStatusStore.cloudAccountTitle)
                diagnosticRow(title: "安装线索", value: syncStatusStore.cloudKitEnvironment)
                diagnosticRow(title: "推送环境", value: syncStatusStore.apsEnvironment)
                diagnosticRow(title: "容器 ID", value: syncStatusStore.containerIdentifier, monospaced: true)
                diagnosticRow(title: "本地数据", value: syncStatusStore.localDataSummary)
            } header: {
                Text("诊断指标")
            } footer: {
                Text("这里显示的是安装收据线索，不足以单独判断 CloudKit 一定在哪个环境。请优先看「同步模式」和「iCloud 账户」这两项。")
            }

            Section {
                Text(syncStatusStore.cloudAccountDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !syncStatusStore.cloudKitEnabled {
                    Text("当前这台设备已经退回本地存储模式，所以它不会和其他设备互相同步。常见原因是 CloudKit schema 没同步到后台，或这台设备当前构建无法初始化 CloudKit。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if !syncStatusStore.cloudKitInitializationError.isEmpty {
                    Text(syncStatusStore.cloudKitInitializationError)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("详细说明")
            }

            // MARK: - CloudKit Sync Events

            Section {
                if syncStatusStore.recentCloudKitEvents.isEmpty {
                    Text("还没有捕获到同步事件，请等待 App 自然触发一次同步，或点击下方「强制触发同步」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(syncStatusStore.recentCloudKitEvents.prefix(Self.defaultVisibleCloudKitEventCount))) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: event.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(event.succeeded ? .green : .red)
                                    .font(.caption)

                                Text(event.typeName)
                                    .font(.subheadline.weight(.medium))

                                Spacer()

                                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            if let errorDesc = event.errorDescription {
                                Text(errorDesc)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("CloudKit 同步事件")
                    Spacer()
                    Text("最近 \(min(syncStatusStore.recentCloudKitEvents.count, Self.defaultVisibleCloudKitEventCount)) / \(syncStatusStore.recentCloudKitEvents.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("默认显示最近 6 条同步事件。红色条目表示同步失败，展开可查看错误详情。需要保持 App 打开才能捕获事件。")
            }

            // MARK: - CloudKit Direct Test

            Section {
                Button {
                    Task {
                        await syncStatusStore.testCloudKitDirectly()
                    }
                } label: {
                    HStack {
                        Text("测试 CloudKit 直连")
                        Spacer()
                        if syncStatusStore.isTestingCloudKit {
                            ProgressView()
                        }
                    }
                }
                .disabled(syncStatusStore.isTestingCloudKit)

                if !syncStatusStore.cloudKitDirectTestResult.isEmpty {
                    Text(syncStatusStore.cloudKitDirectTestResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(
                            syncStatusStore.cloudKitDirectTestResult.hasPrefix("❌") ? Color.red : Color.primary
                        )
                        .textSelection(.enabled)
                }
            } header: {
                Text("CloudKit 直连测试")
            } footer: {
                Text("会按记录类型分别写入并删除测试记录，帮助区分是整体 CloudKit 不可写，还是最近新增的任务系统模型还没有部署到生产环境。")
            }

            // MARK: - Actions

            Section {
                Button {
                    Task {
                        await syncStatusStore.refresh(using: modelContext, trigger: .manual)
                    }
                } label: {
                    HStack {
                        Text("重新检查数据同步状态")
                        Spacer()
                        if syncStatusStore.isRefreshing {
                            ProgressView()
                        }
                    }
                }
                .disabled(syncStatusStore.isRefreshing)

                Button {
                    syncStatusStore.triggerForcePush(using: modelContext)
                } label: {
                    Text("强制触发同步")
                }

                Button(role: .destructive) {
                    syncStatusStore.recentCloudKitEvents.removeAll()
                    syncStatusStore.cloudKitDirectTestResult = ""
                } label: {
                    Text("清除诊断记录")
                }
            } header: {
                Text("操作")
            } footer: {
                Text("\"强制触发同步\"会临时写入并删除一条记录，迫使 CloudKit 发起一次上传和下载周期。")
            }

            Section {
                Button(role: .destructive) {
                    showPurgeConfirm = true
                } label: {
                    Text("重置同步状态")
                }
                .confirmationDialog("确定要重置同步状态吗？", isPresented: $showPurgeConfirm, titleVisibility: .visible) {
                    Button("重置", role: .destructive) {
                        purgeResultMessage = syncStatusStore.purgePersistentHistoryAndReset(using: modelContext)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("这会清除本地的同步历史队列，解除卡住的上传。操作后需要完全退出并重新打开 App。数据不会丢失。")
                }

                if !purgeResultMessage.isEmpty {
                    Text(purgeResultMessage)
                        .font(.caption)
                        .foregroundStyle(purgeResultMessage.hasPrefix("✅") ? Color.green : Color.orange)
                        .textSelection(.enabled)
                }
            } header: {
                Text("高级操作")
            } footer: {
                Text("如果上传持续失败，「重置同步状态」可以清除积压的同步队列。操作后请完全退出 App 再打开，CloudKit 会重新评估需要同步的数据。")
            }
        }
        .navigationTitle("同步诊断信息")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagnosticRow(title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
            Spacer()
            Text(value)
                .font(monospaced ? .callout.monospaced() : .body)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }
}
