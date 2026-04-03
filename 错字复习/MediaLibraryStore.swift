import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MediaLibraryStore {
    private struct MetadataDocument: Codable {
        static let currentVersion = 1

        var version: Int
        var assets: [MediaLibraryAsset]

        init(version: Int = currentVersion, assets: [MediaLibraryAsset]) {
            self.version = version
            self.assets = assets
        }
    }

    private(set) var mediaAssets: [MediaLibraryAsset] = []
    private(set) var lastErrorMessage: String?

    init() {
        reload()
    }

    func reload() {
        do {
            let assets = try loadAssets()
            mediaAssets = normalizePlaylistOrder(for: assets)
            lastErrorMessage = nil
        } catch {
            mediaAssets = []
            lastErrorMessage = error.localizedDescription
        }
    }

    func importFiles(from urls: [URL]) throws {
        var importedAssets = mediaAssets
        var nextOrder = (importedAssets.map(\.playlistOrder).max() ?? -1) + 1

        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let importedFile = try MediaLibraryStorage.importFile(from: url)
            let asset = MediaLibraryAsset(
                title: url.deletingPathExtension().lastPathComponent,
                originalFilename: url.lastPathComponent,
                storedFilename: importedFile.storedFilename,
                mediaType: MediaAssetType.detect(from: url),
                storageScope: importedFile.storageScope,
                playlistOrder: nextOrder
            )
            importedAssets.append(asset)
            nextOrder += 1
        }

        try overwrite(with: importedAssets)
    }

    func updateInclusion(for assetID: UUID, isIncludedInPlaylist: Bool) throws {
        guard let index = mediaAssets.firstIndex(where: { $0.id == assetID }) else { return }
        mediaAssets[index].isIncludedInPlaylist = isIncludedInPlaylist
        mediaAssets[index].updatedAt = .now
        try persistCurrentAssets()
    }

    func updateTitle(for assetID: UUID, title: String) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        guard let index = mediaAssets.firstIndex(where: { $0.id == assetID }) else { return }

        mediaAssets[index].title = trimmedTitle
        mediaAssets[index].updatedAt = .now
        try persistCurrentAssets()
    }

    func moveAssets(from source: IndexSet, to destination: Int) throws {
        var reorderedAssets = mediaAssets
        reorderedAssets.move(fromOffsets: source, toOffset: destination)
        try overwrite(with: reorderedAssets)
    }

    func replaceDisplayedOrder(with displayedAssets: [MediaLibraryAsset]) throws {
        try overwrite(with: Array(displayedAssets.reversed()))
    }

    func deleteAssets(at offsets: IndexSet) throws {
        let deletedAssets = offsets.map { mediaAssets[$0] }
        deletedAssets.forEach { MediaLibraryStorage.deleteFile(named: $0.storedFilename) }

        let remainingAssets = mediaAssets.enumerated().compactMap { index, asset in
            offsets.contains(index) ? nil : asset
        }

        try overwrite(with: remainingAssets)
    }

    func deleteAssets(withIDs assetIDs: [UUID]) throws {
        let deletedAssets = mediaAssets.filter { assetIDs.contains($0.id) }
        deletedAssets.forEach { MediaLibraryStorage.deleteFile(named: $0.storedFilename) }

        let remainingAssets = mediaAssets.filter { !assetIDs.contains($0.id) }
        try overwrite(with: remainingAssets)
    }

    func replaceAll(with assets: [MediaLibraryAsset]) throws {
        try overwrite(with: assets)
    }

    func snapshots() -> [MediaLibraryAsset] {
        mediaAssets
    }

    private func loadAssets() throws -> [MediaLibraryAsset] {
        let preferredMetadataURL = try? MediaLibraryStorage.preferredMetadataURL().fileURL

        for url in MediaLibraryStorage.metadataCandidateURLs() where FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let document = try Self.makeDecoder().decode(MetadataDocument.self, from: data)

            if let preferredMetadataURL, preferredMetadataURL.path != url.path {
                try write(document, to: preferredMetadataURL)
            }

            return document.assets
        }

        return []
    }

    private func overwrite(with assets: [MediaLibraryAsset]) throws {
        mediaAssets = normalizePlaylistOrder(for: assets)
        try persistCurrentAssets()
    }

    private func persistCurrentAssets() throws {
        let document = MetadataDocument(assets: mediaAssets)
        let destination = try MediaLibraryStorage.preferredMetadataURL().fileURL
        try write(document, to: destination)
        lastErrorMessage = nil
    }

    private func write(_ document: MetadataDocument, to url: URL) throws {
        let data = try Self.makeEncoder().encode(document)
        try data.write(to: url, options: .atomic)
    }

    private func normalizePlaylistOrder(for assets: [MediaLibraryAsset]) -> [MediaLibraryAsset] {
        let sortedAssets = assets.sorted { lhs, rhs in
            if lhs.playlistOrder == rhs.playlistOrder {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.playlistOrder < rhs.playlistOrder
        }

        return sortedAssets.enumerated().map { index, asset in
            var normalizedAsset = asset
            normalizedAsset.playlistOrder = index
            return normalizedAsset
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
