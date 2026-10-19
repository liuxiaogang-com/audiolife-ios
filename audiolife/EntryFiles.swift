import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import Vision

nonisolated struct EntryAttachment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var originalName: String
    var relativePath: String
    var contentType: String
    var byteCount: Int64
    var sha256: String
    var extractedText: String = ""
    var processingState: String = ""
    var processingError: String = ""
    var duration: TimeInterval?
    var originalExtractedText: String?
    var isTextEdited: Bool = false

    var type: UTType { UTType(contentType) ?? .data }
    var isImage: Bool { type.conforms(to: .image) }
    var isAudio: Bool { type.conforms(to: .audio) }
    var isVideo: Bool { type.conforms(to: .movie) }
    var symbol: String {
        if isImage { return "photo" }
        if isAudio { return "waveform" }
        if isVideo { return "video" }
        return "doc"
    }
}

nonisolated enum EntryFiles {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    static func url(for attachment: EntryAttachment) -> URL? {
        guard !attachment.relativePath.isEmpty,
              !attachment.relativePath.hasPrefix("/"),
              !attachment.relativePath.split(separator: "/").contains("..") else { return nil }
        let url = root.appendingPathComponent(attachment.relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    static func importFile(_ source: URL) async throws -> EntryAttachment {
        try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let fileManager = FileManager.default
            let id = UUID()
            let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = source.lastPathComponent
            let destination = directory.appendingPathComponent(name)
            do {
                // Coordinate with Files/iCloud providers; retain an independent local copy.
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                    do { try fileManager.copyItem(at: url, to: destination) }
                    catch { copyError = error }
                }
                if let error = coordinationError { throw error }
                if let error = copyError { throw error }
                let digest = try hash(destination)
                let type = values.contentType ?? UTType(filenameExtension: source.pathExtension) ?? .data
                var result = EntryAttachment(
                    id: id, originalName: name, relativePath: id.uuidString + "/" + name,
                    contentType: type.identifier,
                    byteCount: Int64((try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0),
                    sha256: digest
                )
                if result.isImage || result.isAudio { result.processingState = "queued" }
                if result.isAudio {
                    do {
                        let audio = try AVAudioFile(forReading: destination)
                        guard audio.processingFormat.sampleRate > 0 else { throw CocoaError(.fileReadCorruptFile) }
                        result.duration = Double(audio.length) / audio.processingFormat.sampleRate
                    } catch {
                        result.processingState = "failed"
                        result.processingError = "无法解码该音频，原文件已保留：\(error.localizedDescription)"
                    }
                }
                return result
            } catch {
                try? fileManager.removeItem(at: directory)
                throw error
            }
        }.value
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func remove(_ attachment: EntryAttachment) {
        guard let url = url(for: attachment) else { return }
        try? FileManager.default.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    @MainActor static func removeFiles(for entry: RecordingClip) {
        if entry.hasAudio { AudioRecorderController.removeRecordingFiles(for: entry.fileName) }
        for attachment in entry.attachments { remove(attachment) }
    }

    static func recognizeText(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["zh-Hans", "en-US"].filter(supported.contains)
            try VNImageRequestHandler(url: url).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
