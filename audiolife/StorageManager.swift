import Foundation

struct StorageClipDescriptor: Sendable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let fileName: String
    let isTrashed: Bool
    let audioURL: URL?
}

struct StorageClipUsage: Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let fileName: String
    let isTrashed: Bool
    let bytes: Int64
}

struct StorageSnapshot: Sendable {
    var activeRecordingBytes: Int64 = 0
    var trashBytes: Int64 = 0
    var exportCacheBytes: Int64 = 0
    var diagnosticLogBytes: Int64 = 0
    var databaseBytes: Int64 = 0
    var clips: [StorageClipUsage] = []

    nonisolated init(
        activeRecordingBytes: Int64 = 0,
        trashBytes: Int64 = 0,
        exportCacheBytes: Int64 = 0,
        diagnosticLogBytes: Int64 = 0,
        databaseBytes: Int64 = 0,
        clips: [StorageClipUsage] = []
    ) {
        self.activeRecordingBytes = activeRecordingBytes
        self.trashBytes = trashBytes
        self.exportCacheBytes = exportCacheBytes
        self.diagnosticLogBytes = diagnosticLogBytes
        self.databaseBytes = databaseBytes
        self.clips = clips
    }

    var totalBytes: Int64 {
        activeRecordingBytes + trashBytes + exportCacheBytes + diagnosticLogBytes + databaseBytes
    }
}

enum StorageManager {
    nonisolated static func scan(_ clips: [StorageClipDescriptor]) async -> StorageSnapshot {
        await Task.detached(priority: .utility) {
            scanSynchronously(clips)
        }.value
    }

    nonisolated static func clearExportCache() throws {
        let url = exportCacheDirectory
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static func clearDiagnosticLog() throws {
        let url = diagnosticLogURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static var exportCacheDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioLifeExports", isDirectory: true)
    }

    nonisolated private static var diagnosticLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audiolife-diagnostics.log")
    }

    nonisolated private static func scanSynchronously(
        _ descriptors: [StorageClipDescriptor]
    ) -> StorageSnapshot {
        var snapshot = StorageSnapshot()
        snapshot.clips = descriptors.map { descriptor in
            let audioBytes = descriptor.audioURL.map(fileSize) ?? 0
            let transcriptBytes = descriptor.audioURL.map {
                fileSize($0.appendingPathExtension("transcript.txt"))
            } ?? 0
            let bytes = audioBytes + transcriptBytes
            if descriptor.isTrashed {
                snapshot.trashBytes += bytes
            } else {
                snapshot.activeRecordingBytes += bytes
            }
            return StorageClipUsage(
                id: descriptor.id,
                createdAt: descriptor.createdAt,
                duration: descriptor.duration,
                fileName: descriptor.fileName,
                isTrashed: descriptor.isTrashed,
                bytes: bytes
            )
        }
        snapshot.clips.sort { $0.bytes > $1.bytes }
        snapshot.exportCacheBytes = directorySize(exportCacheDirectory)
        snapshot.diagnosticLogBytes = fileSize(diagnosticLogURL)
        snapshot.databaseBytes = applicationSupportSize()
        return snapshot
    }

    nonisolated private static func applicationSupportSize() -> Int64 {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return 0 }
        return directorySize(directory)
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }
}

extension Int64 {
    var storageSizeText: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
