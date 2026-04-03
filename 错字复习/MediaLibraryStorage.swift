import Foundation

enum MediaFileAvailability {
    case ready(URL)
    case downloading
    case missing
}

enum MediaLibraryStorage {
    private static let directoryName = "MediaLibrary"
    private static let metadataFilename = "media-library.json"
    private static let ubiquityContainerIdentifier = "iCloud.cc.xiaorsz.typo-review"

    static func fileURL(for storedFilename: String) -> URL {
        resolvedFileURL(for: storedFilename) ?? localDirectoryURL().appendingPathComponent(storedFilename, isDirectory: false)
    }

    static func importFile(from sourceURL: URL) throws -> (storedFilename: String, storageScope: MediaStorageScope) {
        let storage = try preferredStorageLocation()
        let storedFilename = makeStoredFilename(for: sourceURL)
        let destinationURL = storage.directoryURL.appendingPathComponent(storedFilename, isDirectory: false)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return (storedFilename, storage.storageScope)
    }

    static func deleteFile(named storedFilename: String) {
        for url in candidateFileURLs(for: storedFilename) where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func availability(for storedFilename: String) -> MediaFileAvailability {
        for url in candidateFileURLs(for: storedFilename) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else { continue }

            if isUbiquitous(url) {
                if isDownloaded(url) {
                    return .ready(url)
                }

                try? fileManager.startDownloadingUbiquitousItem(at: url)
                return .downloading
            }

            return .ready(url)
        }

        return .missing
    }

    static func syncStatusText(for storedFilename: String, storageScope: MediaStorageScope) -> String {
        switch availability(for: storedFilename) {
        case .ready:
            return storageScope == .iCloud ? "已同步" : "仅本机"
        case .downloading:
            return "等待下载"
        case .missing:
            return storageScope == .iCloud ? "等待同步" : "文件缺失"
        }
    }

    static func fileSize(for storedFilename: String) -> Int64 {
        for url in candidateFileURLs(for: storedFilename) where FileManager.default.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [
                .totalFileSizeKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ])

            if let size = values?.totalFileAllocatedSize {
                return Int64(size)
            }
            if let size = values?.fileAllocatedSize {
                return Int64(size)
            }
            if let size = values?.totalFileSize {
                return Int64(size)
            }
            if let size = values?.fileSize {
                return Int64(size)
            }
        }

        return 0
    }

    static func preferredMetadataURL() throws -> (fileURL: URL, storageScope: MediaStorageScope) {
        let location = try preferredStorageLocation()
        return (
            location.directoryURL.appendingPathComponent(metadataFilename, isDirectory: false),
            location.storageScope
        )
    }

    static func metadataCandidateURLs() -> [URL] {
        var urls: [URL] = []

        if let cloudDirectory = try? iCloudDirectoryURL() {
            urls.append(cloudDirectory.appendingPathComponent(metadataFilename, isDirectory: false))
        }

        urls.append(localDirectoryURL().appendingPathComponent(metadataFilename, isDirectory: false))
        return urls
    }

    private static func preferredStorageLocation() throws -> (directoryURL: URL, storageScope: MediaStorageScope) {
        if let cloudDirectory = try? iCloudDirectoryURL() {
            return (cloudDirectory, .iCloud)
        }

        let localDirectory = try ensureDirectoryExists(at: localDirectoryURL())
        return (localDirectory, .local)
    }

    private static func resolvedFileURL(for storedFilename: String) -> URL? {
        candidateFileURLs(for: storedFilename).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func candidateFileURLs(for storedFilename: String) -> [URL] {
        var urls: [URL] = []

        if let cloudDirectory = try? iCloudDirectoryURL() {
            urls.append(cloudDirectory.appendingPathComponent(storedFilename, isDirectory: false))
        }

        urls.append(localDirectoryURL().appendingPathComponent(storedFilename, isDirectory: false))
        return urls
    }

    private static func iCloudDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.url(forUbiquityContainerIdentifier: ubiquityContainerIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
        let directory = documentsURL.appendingPathComponent(directoryName, isDirectory: true)
        return try ensureDirectoryExists(at: directory)
    }

    private static func localDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func ensureDirectoryExists(at directory: URL) throws -> URL {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }

    private static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? false
    }

    private static func isDownloaded(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])

        if values?.ubiquitousItemDownloadingStatus == .current {
            return true
        }

        return false
    }

    private static func makeStoredFilename(for sourceURL: URL) -> String {
        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if ext.isEmpty {
            return UUID().uuidString
        }

        return "\(UUID().uuidString).\(ext)"
    }
}
