import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Environment(MediaLibraryStore.self) private var mediaLibraryStore
    @Environment(AppSettingsStore.self) private var settings

    @State private var exportDocument = DataBackupDocument.empty
    @State private var exportFilename = DataBackupPayload.placeholder.defaultFilename
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var pendingImportPayload: DataBackupPayload?
    @State private var pendingImportFilename = ""
    @State private var infoAlert: InfoAlert?
    @State private var isRestoringBackup = false
    @State private var deepSeekAPIKey = ""
    @State private var isTestingDeepSeekConnection = false
    @State private var isConfirmingDeepSeekAPIKeyClear = false
    @State private var pairingCode = ""
    @State private var savedPairingCode = (try? ServerCredentialStore.loadPairingCode()) ?? ""
    @State private var isPairingCodeVisible = false
    @State private var isLoadingPairingCode = false
    @State private var isPairingServer = false
    @State private var hasServerCredential = ServerAPIConfiguration.current != nil

    private var reviewStyle: Binding<ReviewInteractionStyle> {
        Binding(
            get: { settings.reviewInteractionStyle },
            set: { newValue in
                settings.reviewInteractionStyle = newValue
                settings.persist(using: modelContext)
            }
        )
    }

    private var reminderDate: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = settings.remindHour
                components.minute = settings.remindMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings.remindHour = components.hour ?? 19
                settings.remindMinute = components.minute ?? 30
                settings.persist(using: modelContext)
            }
        )
    }

    private var boardManualPlaybackOption: Binding<BoardManualPlaybackOption> {
        Binding(
            get: { settings.boardManualPlaybackOption },
            set: {
                settings.boardManualPlaybackOption = $0
                settings.persist(using: modelContext)
            }
        )
    }

    private var boardAutoplaySlots: [BoardAutoplaySlot] {
        settings.boardAutoplaySlots
    }

    private let boardAutoplayDurationOptions = [15, 30, 45, 60, 90, 120]
    private let boardManualPlaybackOptions = BoardManualPlaybackOption.allCases

    private var serverSyncCoordinator: ServerSyncCoordinator {
        .shared
    }

    private var serverSyncStatusText: String {
        if serverSyncCoordinator.isSynchronizing {
            return serverSyncCoordinator.serverStatusText
        }
        if serverSyncCoordinator.lastErrorDescription != nil {
            return "等待重试"
        }
        if serverSyncCoordinator.lastSuccessfulPullAt != nil {
            return "已同步"
        }
        return "等待首次同步"
    }

    private var serverSyncStatusColor: Color {
        if serverSyncCoordinator.isSynchronizing {
            return .secondary
        }
        if serverSyncCoordinator.lastErrorDescription != nil
            || serverSyncCoordinator.lastSuccessfulPullAt == nil {
            return .orange
        }
        return .green
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    SettingsIcon(name: "person.text.rectangle.fill", color: .blue)
                    Text("孩子名字")
                    Spacer()
                    TextField("输入名字", text: bind(\.childName))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }

                Stepper(value: bind(\.dailyLimit), in: 5...50, step: 5) {
                    HStack {
                        SettingsIcon(name: "list.number", color: .orange)
                        Text("每日题量")
                        Spacer()
                        Text("\(settings.dailyLimit) 题")
                            .foregroundStyle(.secondary)
                    }
                }
                
                HStack {
                    SettingsIcon(name: "bell.fill", color: .red)
                    DatePicker("每日提醒", selection: reminderDate, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("基本资料")
            }

            Section {
                NavigationLink {
                    PointsDashboardView()
                } label: {
                    HStack {
                        SettingsIcon(name: "star.circle.fill", color: .yellow)
                        Text("积分与兑换")
                    }
                }
            } header: {
                Text("积分")
            } footer: {
                Text("积分按听写、复习和待办完成自动累计，兑换由家长手动扣除。")
            }

            Section {
                Picker(selection: reviewStyle) {
                    ForEach(ReviewInteractionStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                } label: {
                    HStack {
                        SettingsIcon(name: "pencil.and.outline", color: .indigo)
                        Text("复习模式")
                    }
                }
            } header: {
                Text("复习偏好")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reviewStyle.wrappedValue == .oneByOne ? "提示：每报一题，家长立刻确认对错。" : "提示：连续报听写，最后统一批改。")
                    SettingsNoteRow(
                        icon: "calendar.badge.clock",
                        text: "阶段复习间隔：同一题目当天只复习一次。答对或答错会自动按艾宾浩斯记忆曲线安排后续复习。"
                    )
                }
            }

            Section {
                Toggle(isOn: bind(\.aiSummaryEnabled)) {
                    HStack {
                        SettingsIcon(name: "sparkles", color: .purple)
                        Text("启用 AI 今日小结")
                    }
                }

                if settings.aiSummaryEnabled {
                    Picker(selection: bind(\.aiSummaryModelRawValue)) {
                        ForEach(DeepSeekSummaryModel.allCases) { model in
                            Text(model.title).tag(model.rawValue)
                        }
                    } label: {
                        HStack {
                            SettingsIcon(name: "brain.head.profile", color: .indigo)
                            Text("DeepSeek 模型")
                        }
                    }

                    SecureField("DeepSeek API Key", text: $deepSeekAPIKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            saveDeepSeekAPIKey()
                        }

                    HStack {
                        Button {
                            saveDeepSeekAPIKey()
                        } label: {
                            Label("保存 Key", systemImage: "key.fill")
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button(role: .destructive) {
                            isConfirmingDeepSeekAPIKeyClear = true
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(deepSeekAPIKey.isEmpty)
                    }

                    Button {
                        testDeepSeekConnection()
                    } label: {
                        HStack {
                            SettingsIcon(name: "network", color: .blue)
                            Text("测试连接")
                            Spacer()
                            if isTestingDeepSeekConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(isTestingDeepSeekConnection || deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("AI 小结")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsNoteRow(
                        icon: "lock.shield.fill",
                        text: hasServerCredential
                            ? "DeepSeek API Key 会加密保存到家庭服务器，并自动写入各设备的系统 Keychain。"
                            : "DeepSeek API Key 通过系统 iCloud Keychain 安全同步；需要各设备登录同一 Apple ID，并开启 iCloud 密码与钥匙串。"
                    )
                    SettingsNoteRow(
                        icon: "arrow.up.doc.fill",
                        text: "启用后，首页会把当天复习、听写、任务和积分统计发送给 DeepSeek 生成小结；不会上传完整题库和历史记录。"
                    )
                }
            }

            Section {
                Toggle(isOn: bind(\.boardAutoplayEnabled)) {
                    HStack {
                        SettingsIcon(name: "play.fill", color: .green)
                        Text("晨读自动播放")
                    }
                }
                
                if settings.boardAutoplayEnabled {
                    ForEach(Array(boardAutoplaySlots.enumerated()), id: \.element.id) { index, slot in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                HStack(spacing: 8) {
                                    SettingsIcon(name: "clock.badge.checkmark.fill", color: .blue)
                                    Text("时间段 \(index + 1)")
                                        .font(.subheadline.weight(.semibold))
                                }

                                Spacer()

                                if boardAutoplaySlots.count > 1 {
                                    Button(role: .destructive) {
                                        settings.removeBoardAutoplaySlot(id: slot.id)
                                        settings.persist(using: modelContext)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote.weight(.semibold))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            DatePicker(
                                "开始时间",
                                selection: boardAutoplayStartDate(for: slot),
                                displayedComponents: .hourAndMinute
                            )

                            Picker("播放时长", selection: boardAutoplayDurationMinutes(for: slot)) {
                                ForEach(boardAutoplayDurationOptions, id: \.self) { minutes in
                                    Text(durationOptionLabel(minutes))
                                        .tag(minutes)
                                }
                            }
                        }
                    }

                    Button {
                        settings.addBoardAutoplaySlot()
                        settings.persist(using: modelContext)
                    } label: {
                        HStack {
                            SettingsIcon(name: "plus.circle.fill", color: .cyan)
                            Text("添加时间段")
                        }
                    }
                    
                    Toggle(isOn: bind(\.boardAutoplaySkipWeekends)) {
                        HStack {
                            SettingsIcon(name: "calendar.badge.minus", color: .mint)
                            Text("周末不播放")
                        }
                    }
                    
                    Toggle(isOn: bind(\.boardAutoplaySkipChinaHolidays)) {
                        HStack {
                            SettingsIcon(name: "flag.2.crossed.fill", color: .red)
                            Text("法定节假日不播放")
                        }
                    }
                }

                Picker(selection: boardManualPlaybackOption) {
                    ForEach(boardManualPlaybackOptions) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    HStack {
                        SettingsIcon(name: "hand.tap.fill", color: .purple)
                        Text("看板手动播放时长")
                    }
                }
                
                NavigationLink {
                    MediaLibraryView()
                } label: {
                    HStack {
                        SettingsIcon(name: "music.note.list", color: .pink)
                        Text("管理晨读资源库")
                    }
                }
            } header: {
                Text("晨读与看板")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("只有看板打开时自动播放才会生效。")
                    SettingsNoteRow(
                        icon: "clock.arrow.circlepath",
                        text: settings.boardAutoplaySlots.isEmpty ? "当前还没有晨读自动播放时间段。" : "已设置 \(settings.boardAutoplaySlots.count) 个时间段：\(settings.boardAutoplayTimeSummary)"
                    )
                    Text(settings.boardAutoplayRuleSummary)
                    SettingsNoteRow(
                        icon: "flag.2.crossed.fill",
                        text: "法定节假日已内置 \(AppSettings.supportedChinaHolidayYearsSummary) 年国务院办公厅放假安排；后续年份需要跟随官方通知更新。"
                    )
                }
            }

            Section {
                HStack {
                    SettingsIcon(
                        name: hasServerCredential ? "server.rack" : "icloud.fill",
                        color: .blue
                    )
                    Text("同步状态")
                    Spacer()
                    if hasServerCredential {
                        Text(serverSyncStatusText)
                            .foregroundStyle(serverSyncStatusColor)
                    } else {
                        Text(syncStatusStore.statusText)
                            .foregroundStyle(syncStatusStore.syncNoticeKind == .ready ? .green : .secondary)
                    }
                }
                
                HStack {
                    SettingsIcon(name: "externaldrive.fill", color: .green)
                    Text("数据存储")
                    Spacer()
                    if hasServerCredential {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .foregroundStyle(.green)
                        Text("服务器同步存储")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: syncStatusStore.isUsingLocalFallback ? "externaldrive.fill.badge.xmark" : "externaldrive.fill.badge.checkmark")
                            .foregroundStyle(syncStatusStore.isUsingLocalFallback ? .red : .green)
                        Text(syncStatusStore.storageModeTitle)
                            .foregroundStyle(syncStatusStore.isUsingLocalFallback ? .red : .green)
                    }
                }

                if hasServerCredential {
                    Button {
                        Task {
                            await ServerSyncCoordinator.shared.pull(
                                into: modelContext,
                                settingsStore: settings
                            )
                        }
                    } label: {
                        HStack {
                            SettingsIcon(name: "arrow.triangle.2.circlepath", color: .blue)
                            Text(serverSyncCoordinator.isSynchronizing ? serverSyncStatusText : "立即从服务器同步")
                            Spacer()
                            if serverSyncCoordinator.isSynchronizing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(serverSyncCoordinator.isSynchronizing || isRestoringBackup)

                    HStack {
                        SettingsIcon(name: "key.fill", color: .orange)
                        Text("家庭配对码")
                        Spacer()

                        if savedPairingCode.isEmpty {
                            if isLoadingPairingCode {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("暂未读取")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                isPairingCodeVisible.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Text(isPairingCodeVisible ? savedPairingCode : "••••")
                                        .font(.body.monospacedDigit().weight(.semibold))
                                    Image(systemName: isPairingCodeVisible ? "eye.slash.fill" : "eye.fill")
                                }
                            }
                            .buttonStyle(.plain)

                            if isPairingCodeVisible {
                                Button {
                                    UIPasteboard.general.string = savedPairingCode
                                    showInfoAlert(title: "已复制", message: "家庭配对码已复制。")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("复制家庭配对码")
                            }
                        }
                    }
                } else if ServerAPIConfiguration.serverURL != nil {
                    HStack {
                        SettingsIcon(name: "key.fill", color: .orange)
                        TextField("输入 4 位配对码", text: $pairingCode)
                            .keyboardType(.numberPad)
                            .onChange(of: pairingCode) { _, newValue in
                                pairingCode = String(newValue.filter(\.isNumber).prefix(4))
                            }
                        Button(isPairingServer ? "加入中…" : "加入") {
                            pairWithServer()
                        }
                        .disabled(isPairingServer || pairingCode.count != 4)
                    }
                }

                NavigationLink {
                    AdvancedSyncDiagnosticView()
                } label: {
                    HStack {
                        SettingsIcon(name: "stethoscope", color: .gray)
                        Text("高级诊断信息")
                    }
                }
            } header: {
                Text("家庭账号与同步")
            } footer: {
                SettingsNoteRow(
                    icon: hasServerCredential ? "server.rack" : "arrow.triangle.2.circlepath.icloud",
                    text: hasServerCredential
                        ? "题库、复习记录、任务、听写计划、日程和积分由上海服务器同步；听写音视频资源仍保留原来的存储方式。"
                        : (ServerAPIConfiguration.serverURL == nil
                            ? "数据会通过 iCloud 自动同步到同一 Apple ID 下的设备。"
                            : "在多台设备输入同一个家庭账号配对码，就会同步同一份数据。")
                )
            }

            Section {
                Button {
                    exportBackup()
                } label: {
                    HStack {
                        SettingsIcon(name: "square.and.arrow.up.fill", color: .blue)
                        Text("导出数据")
                    }
                }
                .disabled(isRestoringBackup)
                
                Button {
                    isImportingBackup = true
                } label: {
                    HStack {
                        SettingsIcon(name: "square.and.arrow.down.fill", color: .green)
                        Text("导入恢复")
                    }
                }
                .disabled(isRestoringBackup)
                
                if isRestoringBackup {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                        Text("恢复中...")
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                }
            } header: {
                Text("备份管理")
            } footer: {
                SettingsNoteRow(
                    icon: "archivebox.fill",
                    text: "导出会生成包含题库、复习记录、任务和设置的 JSON 备份；导入恢复会覆盖当前设备上的现有数据。"
                )
            }

            Section {
                HStack {
                    SettingsIcon(name: "info.circle.fill", color: .gray)
                    Text("版本号")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    HStack {
                        SettingsIcon(name: "doc.text.fill", color: .blue)
                        Text("开源许可")
                    }
                }
            } header: {
                Text("关于听写复习本")
            } footer: {
                Text("结合艾宾浩斯遗忘曲线，帮助孩子高效攻克写错的词句和英语内容。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadDeepSeekAPIKey()
            loadPairingCodeIfNeeded()
        }
        .fileExporter(
            isPresented: $isExportingBackup,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            handleBackupExport(result)
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleBackupImport(result)
        }
        .confirmationDialog(
            "清空 DeepSeek API Key？",
            isPresented: $isConfirmingDeepSeekAPIKeyClear,
            titleVisibility: .visible
        ) {
            Button("清空 API Key", role: .destructive) {
                clearDeepSeekAPIKey()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(hasServerCredential
                ? "API Key 会从本机和家庭账号中移除，其他设备也将无法继续使用 AI 小结。"
                : "API Key 会从本机的系统 Keychain 中移除，AI 小结将无法继续使用。")
        }
        .confirmationDialog(
            "恢复备份",
            isPresented: Binding(
                get: { pendingImportPayload != nil },
                set: { if !$0 { clearPendingImport() } }
            ),
            titleVisibility: .visible
        ) {
            Button("覆盖当前数据", role: .destructive) {
                restorePendingBackup()
            }
            Button("取消", role: .cancel) {
                clearPendingImport()
            }
        } message: {
            Text(importConfirmationMessage)
        }
        .alert(item: $infoAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettingsStore, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                settings.persist(using: modelContext)
            }
        )
    }

    private func boardAutoplayStartDate(for slot: BoardAutoplaySlot) -> Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = slot.startHour
                components.minute = slot.startMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings.updateBoardAutoplaySlot(id: slot.id) { slot in
                    slot.startHour = components.hour ?? AppSettings.defaultBoardAutoplayStartHour
                    slot.startMinute = components.minute ?? AppSettings.defaultBoardAutoplayStartMinute
                }
                settings.persist(using: modelContext)
            }
        )
    }

    private func boardAutoplayDurationMinutes(for slot: BoardAutoplaySlot) -> Binding<Int> {
        Binding(
            get: { slot.durationMinutes },
            set: { newValue in
                settings.updateBoardAutoplaySlot(id: slot.id) { slot in
                    slot.durationMinutes = newValue
                }
                settings.persist(using: modelContext)
            }
        )
    }

    private var importConfirmationMessage: String {
        guard let pendingImportPayload else {
            return ""
        }

        let exportedAt = pendingImportPayload.exportedAt.formatted(
            .dateTime.year().month().day().hour().minute()
        )

        return """
        文件：\(pendingImportFilename)
        备份时间：\(exportedAt)
        内容：\(pendingImportPayload.summaryText)

        恢复后会覆盖当前这台设备上的现有数据，请确认已经完成导出备份。
        """
    }

    private func exportBackup() {
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }

            let document = try DataBackupService.makeDocument(
                from: modelContext,
                settingsStore: settings,
                mediaAssets: mediaLibraryStore.snapshots()
            )
            exportDocument = document
            exportFilename = document.payload.defaultFilename
            isExportingBackup = true
        } catch {
            showInfoAlert(
                title: "导出失败",
                message: error.localizedDescription
            )
        }
    }

    private func handleBackupExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            showInfoAlert(
                title: "导出成功",
                message: "备份文件已经导出完成，可以保存在 iCloud Drive 或本地文件夹中备用。"
            )
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            showInfoAlert(
                title: "导出失败",
                message: error.localizedDescription
            )
        }
    }

    private func handleBackupImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let document = try DataBackupDocument(data: data)
                pendingImportPayload = document.payload
                pendingImportFilename = url.lastPathComponent
            } catch {
                showInfoAlert(
                    title: "导入失败",
                    message: error.localizedDescription
                )
            }
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            showInfoAlert(
                title: "导入失败",
                message: error.localizedDescription
            )
        }
    }

    private func restorePendingBackup() {
        guard let pendingImportPayload else { return }

        isRestoringBackup = true
        defer {
            isRestoringBackup = false
            clearPendingImport()
        }

        do {
            try DataBackupService.restore(
                pendingImportPayload,
                into: modelContext,
                settingsStore: settings,
                mediaLibraryStore: mediaLibraryStore
            )
            showInfoAlert(
                title: "恢复完成",
                message: "已经根据备份文件恢复数据。\n\n\(pendingImportPayload.summaryText)"
            )
            Task {
                await syncStatusStore.refresh(using: modelContext, trigger: .manual)
            }
        } catch {
            showInfoAlert(
                title: "恢复失败",
                message: error.localizedDescription
            )
        }
    }

    private func loadDeepSeekAPIKey() {
        do {
            deepSeekAPIKey = try DeepSeekAPIKeyStore.loadAPIKey()
        } catch {
            showInfoAlert(title: "读取 API Key 失败", message: error.localizedDescription)
        }
    }

    private func pairWithServer() {
        guard !isPairingServer else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 4, code.allSatisfy(\.isNumber) else { return }
        isPairingServer = true
        Task {
            do {
                let response = try await ServerAPIClient.shared.pair(
                    code: code,
                    deviceName: UIDevice.current.name
                )
                try ServerCredentialStore.saveToken(response.token)
                try ServerCredentialStore.savePairingCode(code)
                await MainActor.run {
                    savedPairingCode = code
                    pairingCode = ""
                    isPairingServer = false
                    hasServerCredential = true
                    showInfoAlert(
                        title: "已加入家庭账号",
                        message: "这台设备的独立凭据已保存到系统 Keychain。请完全退出并重新打开 App，之后会与该家庭账号下的其他设备同步。"
                    )
                }
            } catch {
                await MainActor.run {
                    isPairingServer = false
                    showInfoAlert(title: "配对失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func loadPairingCodeIfNeeded() {
        guard hasServerCredential, savedPairingCode.isEmpty, !isLoadingPairingCode else { return }
        if let localCode = try? ServerCredentialStore.loadPairingCode(), !localCode.isEmpty {
            savedPairingCode = localCode
            return
        }

        isLoadingPairingCode = true
        Task {
            do {
                let response = try await ServerAPIClient.shared.pairingCode()
                try ServerCredentialStore.savePairingCode(response.code)
                await MainActor.run {
                    savedPairingCode = response.code
                    isLoadingPairingCode = false
                }
            } catch {
                await MainActor.run {
                    isLoadingPairingCode = false
                }
            }
        }
    }

    private func saveDeepSeekAPIKey() {
        let trimmedKey = deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            showInfoAlert(title: "缺少 API Key", message: "请先填写 DeepSeek API Key；如果要删除已保存的 Key，请点「清空」。")
            return
        }

        do {
            try DeepSeekAPIKeyStore.saveAPIKey(trimmedKey)
            deepSeekAPIKey = try DeepSeekAPIKeyStore.loadAPIKey()
            Task {
                do {
                    if ServerAPIConfiguration.current != nil {
                        _ = try await ServerAPIClient.shared.saveDeepSeekAPIKey(trimmedKey)
                    }
                    await MainActor.run {
                        showInfoAlert(
                            title: "保存成功",
                            message: ServerAPIConfiguration.current != nil
                                ? "DeepSeek API Key 已加密保存到家庭服务器，并会同步到其他设备。"
                                : "DeepSeek API Key 已保存到系统 Keychain，并会通过 iCloud 钥匙串同步到其他设备。"
                        )
                    }
                } catch {
                    await MainActor.run {
                        showInfoAlert(
                            title: "服务器同步失败",
                            message: "API Key 已保存在本机，但尚未同步到家庭服务器：\(error.localizedDescription)"
                        )
                    }
                }
            }
        } catch {
            showInfoAlert(title: "保存失败", message: error.localizedDescription)
        }
    }

    private func clearDeepSeekAPIKey() {
        DeepSeekAPIKeyStore.deleteAPIKey()
        deepSeekAPIKey = ""
        Task {
            do {
                if ServerAPIConfiguration.current != nil {
                    try await ServerAPIClient.shared.deleteDeepSeekAPIKey()
                }
                await MainActor.run {
                    showInfoAlert(title: "已清空", message: "DeepSeek API Key 已从本机和家庭账号移除。")
                }
            } catch {
                await MainActor.run {
                    showInfoAlert(
                        title: "服务器同步失败",
                        message: "本机 Key 已清空，但家庭服务器删除失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func testDeepSeekConnection() {
        let trimmedKey = deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            showInfoAlert(title: "缺少 API Key", message: "请先填写 DeepSeek API Key。")
            return
        }

        isTestingDeepSeekConnection = true
        Task {
            do {
                try DeepSeekAPIKeyStore.saveAPIKey(trimmedKey)
                if ServerAPIConfiguration.current != nil {
                    _ = try await ServerAPIClient.shared.saveDeepSeekAPIKey(trimmedKey)
                }
                let model = DeepSeekSummaryModel(rawValue: settings.aiSummaryModelRawValue) ?? .flash
                let response = try await DeepSeekSummaryClient(apiKey: trimmedKey, model: model.rawValue)
                    .testConnection()

                await MainActor.run {
                    isTestingDeepSeekConnection = false
                    deepSeekAPIKey = trimmedKey
                    showInfoAlert(title: "连接成功", message: "\(model.title)：\(response)")
                }
            } catch {
                await MainActor.run {
                    isTestingDeepSeekConnection = false
                    showInfoAlert(title: "连接失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func clearPendingImport() {
        pendingImportPayload = nil
        pendingImportFilename = ""
    }

    private func showInfoAlert(title: String, message: String) {
        infoAlert = InfoAlert(title: title, message: message)
    }

    private func durationOptionLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            return "\(minutes / 60) 小时"
        }
        return "\(minutes) 分钟"
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return error is CancellationError
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == 3072)
    }
}

private struct SettingsIcon: View {
    let name: String
    let color: Color

    private var resolvedName: String {
        UIImage(systemName: name) == nil ? "questionmark.circle.fill" : name
    }
    
    var body: some View {
        Image(systemName: resolvedName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.trailing, 4)
    }
}

private struct SettingsNoteRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)

            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct OpenSourceLicensesView: View {
    private var ecdictLicenseText: String {
        guard let url = Bundle.main.url(forResource: "ECDICT_LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "ECDICT 使用 MIT License。许可文件未能加载，请检查应用资源。"
        }
        return text
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ECDICT")
                        .font(.headline)
                    Text("英汉词典数据用于本地释义和音标显示。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link("GitHub: skywind3000/ECDICT", destination: URL(string: "https://github.com/skywind3000/ECDICT")!)
                }
                .padding(.vertical, 4)
            } header: {
                Text("词典数据")
            }

            Section {
                Text(ecdictLicenseText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("MIT License")
            }
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InfoAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
