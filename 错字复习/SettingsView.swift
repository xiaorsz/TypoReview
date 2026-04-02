import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Environment(MediaLibraryStore.self) private var mediaLibraryStore
    @Query private var settingsList: [AppSettings]

    @State private var exportDocument = DataBackupDocument.empty
    @State private var exportFilename = DataBackupPayload.placeholder.defaultFilename
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var pendingImportPayload: DataBackupPayload?
    @State private var pendingImportFilename = ""
    @State private var infoAlert: InfoAlert?
    @State private var isRestoringBackup = false

    private var settings: AppSettings? {
        settingsList.first
    }

    private var reviewStyle: Binding<ReviewInteractionStyle> {
        Binding(
            get: { settings?.reviewInteractionStyle ?? AppSettings.defaultReviewInteractionStyle },
            set: { newValue in settings?.reviewInteractionStyle = newValue }
        )
    }

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

    private var boardManualPlaybackOption: Binding<BoardManualPlaybackOption> {
        Binding(
            get: { settings?.boardManualPlaybackOption ?? .untilPlaylistEnds },
            set: { settings?.boardManualPlaybackOption = $0 }
        )
    }

    private var boardAutoplaySlots: [BoardAutoplaySlot] {
        settings?.boardAutoplaySlots ?? []
    }

    private let boardAutoplayDurationOptions = [15, 30, 45, 60, 90, 120]
    private let boardManualPlaybackOptions = BoardManualPlaybackOption.allCases

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
                        Text("\(settings?.dailyLimit ?? 15) 题")
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
                Toggle(isOn: bind(\.boardAutoplayEnabled)) {
                    HStack {
                        SettingsIcon(name: "play.fill", color: .green)
                        Text("晨读自动播放")
                    }
                }
                
                if settings?.boardAutoplayEnabled == true {
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
                                        settings?.removeBoardAutoplaySlot(id: slot.id)
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
                        settings?.addBoardAutoplaySlot()
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
                if let settings {
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
            }

            Section {
                HStack {
                    SettingsIcon(name: "icloud.fill", color: .blue)
                    Text("同步状态")
                    Spacer()
                    Text(syncStatusStore.statusText)
                        .foregroundStyle(syncStatusStore.syncNoticeKind == .ready ? .green : .secondary)
                }
                
                HStack {
                    SettingsIcon(name: "externaldrive.fill", color: .green)
                    Text("数据存储")
                    Spacer()
                    Image(systemName: syncStatusStore.isUsingLocalFallback ? "externaldrive.fill.badge.xmark" : "externaldrive.fill.badge.checkmark")
                        .foregroundStyle(syncStatusStore.isUsingLocalFallback ? .red : .green)
                    Text(syncStatusStore.storageModeTitle)
                        .foregroundStyle(syncStatusStore.isUsingLocalFallback ? .red : .green)
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
                Text("数据同步")
            } footer: {
                SettingsNoteRow(
                    icon: "arrow.triangle.2.circlepath.icloud",
                    text: "数据会通过 iCloud 自动同步到同一 Apple ID 下的设备；如果一直显示本地存储，通常是系统网络或当前环境限制。"
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
            } header: {
                Text("关于听写复习本")
            } footer: {
                Text("结合艾宾浩斯遗忘曲线，帮助孩子高效攻克写错的词句和英语内容。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
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

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings?[keyPath: keyPath] ?? defaultValue(for: keyPath) },
            set: { newValue in settings?[keyPath: keyPath] = newValue }
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
                settings?.updateBoardAutoplaySlot(id: slot.id) { slot in
                    slot.startHour = components.hour ?? AppSettings.defaultBoardAutoplayStartHour
                    slot.startMinute = components.minute ?? AppSettings.defaultBoardAutoplayStartMinute
                }
            }
        )
    }

    private func boardAutoplayDurationMinutes(for slot: BoardAutoplaySlot) -> Binding<Int> {
        Binding(
            get: { slot.durationMinutes },
            set: { newValue in
                settings?.updateBoardAutoplaySlot(id: slot.id) { slot in
                    slot.durationMinutes = newValue
                }
            }
        )
    }

    private func defaultValue<Value>(for keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Value {
        AppSettings()[keyPath: keyPath]
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

private struct InfoAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
