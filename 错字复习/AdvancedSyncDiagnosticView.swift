import SwiftUI
import SwiftData

struct AdvancedSyncDiagnosticView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore

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
                Text("这里显示的是安装收据线索，不足以单独判断 CloudKit 一定在哪个环境。请优先看“同步模式”和“iCloud 账户”这两项。")
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
