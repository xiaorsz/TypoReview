import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct MediaLibraryView: View {
    @Environment(MediaLibraryStore.self) private var mediaLibraryStore

    @State private var isImportingFiles = false
    @State private var importAlert: MediaImportAlert?
    @State private var playbackCoordinator = MediaPlaybackCoordinator()
    @State private var renamingAssetID: UUID?
    @State private var titleDraft = ""

    private var mediaAssets: [MediaLibraryAsset] {
        mediaLibraryStore.mediaAssets
    }

    var body: some View {
        Group {
            if mediaAssets.isEmpty {
                ContentUnavailableView {
                    Label("还没有晨读资源", systemImage: "music.note.list")
                } description: {
                    Text("支持导入音频和视频文件。加入播放列表后，看板会在晨读时段按顺序自动播放。")
                } actions: {
                    Button("导入资源") {
                        isImportingFiles = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    if playbackCoordinator.currentAsset != nil || playbackCoordinator.isWaitingForDownload {
                        Section {
                            previewSection
                        }
                    }

                    Section {
                        ForEach(mediaAssets) { asset in
                            mediaRow(for: asset)
                        }
                        .onMove(perform: moveAssets)
                        .onDelete(perform: deleteAssets)
                    } footer: {
                        Text("拖动右侧把手可以调整播放顺序；关闭“加入播放列表”后，该资源会保留在库里，但晨读时不会自动播放。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("晨读资源库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isImportingFiles = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }

                if !mediaAssets.isEmpty {
                    EditButton()
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .sheet(isPresented: isShowingRenameSheet) {
            renameSheet
        }
        .onDisappear {
            playbackCoordinator.stop()
        }
    }

    private func mediaRow(for asset: MediaLibraryAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: asset.mediaType.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(asset.mediaType == .video ? .orange : .blue)
                    .frame(width: 34, height: 34)
                    .background(
                        (asset.mediaType == .video ? Color.orange : Color.blue).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(asset.title)
                            .font(.headline)

                        Text("#\(asset.playlistOrder + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }

                    Text(asset.originalFilename)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(asset.mediaType.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(asset.mediaType == .video ? .orange : .blue)

                    HStack(spacing: 8) {
                        Text(asset.storageScope.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(asset.storageScope == .iCloud ? .cyan : .secondary)

                        Text(MediaLibraryStorage.syncStatusText(for: asset.storedFilename, storageScope: asset.storageScope))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(syncStatusColor(for: asset))
                    }

                    Text("添加于 \(asset.createdAt.formatted(date: .numeric, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    handlePreviewTap(for: asset)
                } label: {
                    Image(systemName: isPlaying(asset) ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(isPlaying(asset) ? Color.orange : Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying(asset) ? "暂停试听" : "开始试听")

                Button {
                    startRenaming(asset)
                } label: {
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("修改资源标题")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handlePreviewTap(for: asset)
            }

            Toggle("加入播放列表", isOn: Binding(
                get: { asset.isIncludedInPlaylist },
                set: { newValue in
                    do {
                        try mediaLibraryStore.updateInclusion(for: asset.id, isIncludedInPlaylist: newValue)
                    } catch {
                        showError(error, title: "保存失败")
                    }
                }
            ))
            .toggleStyle(.switch)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var previewSection: some View {
        if playbackCoordinator.isWaitingForDownload {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    playbackCoordinator.pendingAssetTitle.map { "“\($0)” 正在准备试听" } ?? "资源正在准备试听",
                    systemImage: "icloud.and.arrow.down"
                )
                .font(.headline)

                Text("文件下载完成后会自动开始播放。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else if let currentAsset = playbackCoordinator.currentAsset {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("正在试听", systemImage: currentAsset.mediaType.systemImage)
                        .font(.headline)

                    Spacer()

                    Button("停止") {
                        playbackCoordinator.stop()
                    }
                    .buttonStyle(.bordered)
                }

                if currentAsset.mediaType == .video {
                    VideoPlayer(player: playbackCoordinator.player)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentAsset.title)
                                .font(.title3.weight(.bold))
                            Text(currentAsset.originalFilename)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func moveAssets(from source: IndexSet, to destination: Int) {
        do {
            try mediaLibraryStore.moveAssets(from: source, to: destination)
        } catch {
            showError(error, title: "调整顺序失败")
        }
    }

    private func deleteAssets(at offsets: IndexSet) {
        do {
            try mediaLibraryStore.deleteAssets(at: offsets)
        } catch {
            showError(error, title: "删除失败")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }

            do {
                try mediaLibraryStore.importFiles(from: urls)
            } catch {
                showError(error, title: "导入失败")
            }
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            showError(error, title: "导入失败")
        }
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return error is CancellationError
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == 3072)
    }

    private func showError(_ error: Error, title: String) {
        importAlert = MediaImportAlert(
            title: title,
            message: error.localizedDescription
        )
    }

    private func handlePreviewTap(for asset: MediaLibraryAsset) {
        if isPlaying(asset) {
            playbackCoordinator.pause()
            return
        }

        playbackCoordinator.play(asset: asset, within: mediaAssets)
    }

    private func isPlaying(_ asset: MediaLibraryAsset) -> Bool {
        playbackCoordinator.isPlaying && playbackCoordinator.currentAsset?.id == asset.id
    }

    private var isShowingRenameSheet: Binding<Bool> {
        Binding(
            get: { renamingAssetID != nil },
            set: { isPresented in
                if !isPresented {
                    renamingAssetID = nil
                    titleDraft = ""
                }
            }
        )
    }

    private var renameSheet: some View {
        NavigationStack {
            Form {
                Section("资源标题") {
                    TextField("请输入标题", text: $titleDraft)
                }
            }
            .navigationTitle("修改标题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        renamingAssetID = nil
                        titleDraft = ""
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        saveTitle()
                    }
                    .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private func startRenaming(_ asset: MediaLibraryAsset) {
        renamingAssetID = asset.id
        titleDraft = asset.title
    }

    private func saveTitle() {
        guard let renamingAssetID else { return }

        do {
            try mediaLibraryStore.updateTitle(for: renamingAssetID, title: titleDraft)
            self.renamingAssetID = nil
            self.titleDraft = ""
        } catch {
            showError(error, title: "保存失败")
        }
    }

    private func syncStatusColor(for asset: MediaLibraryAsset) -> Color {
        switch MediaLibraryStorage.syncStatusText(for: asset.storedFilename, storageScope: asset.storageScope) {
        case "已同步":
            return .green
        case "等待下载", "等待同步":
            return .orange
        case "文件缺失":
            return .red
        default:
            return .secondary
        }
    }
}

private struct MediaImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
