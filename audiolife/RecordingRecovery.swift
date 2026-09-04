import AVFoundation
import Foundation
import SwiftData

@MainActor
enum RecordingRecovery {
    static func recover(in modelContext: ModelContext) {
        guard let rootDirectory = try? AudioRecorderController.recordingsDirectory(),
              let enumerator = FileManager.default.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        let existingClips = (try? modelContext.fetch(FetchDescriptor<RecordingClip>())) ?? []
        let existingPaths = Set(existingClips.map(\.fileName))
        let existingLeafNames = Set(existingClips.map { URL(fileURLWithPath: $0.fileName).lastPathComponent })
        var days = (try? modelContext.fetch(FetchDescriptor<JournalDay>())) ?? []
        var recoveredSomething = false

        for case let audioURL as URL in enumerator {
            let fileExtension = audioURL.pathExtension.lowercased()
            guard fileExtension == "caf" || fileExtension == "m4a" else { continue }
            guard let relativePath = relativePath(of: audioURL, below: rootDirectory) else { continue }
            guard !existingPaths.contains(relativePath),
                  !existingLeafNames.contains(audioURL.lastPathComponent) else { continue }

            let duration = audioDuration(at: audioURL)
            guard duration >= 0.2 else { continue }

            let resourceValues = try? audioURL.resourceValues(
                forKeys: [.creationDateKey, .contentModificationDateKey]
            )
            let createdAt = resourceValues?.creationDate
                ?? resourceValues?.contentModificationDate
                ?? Date()
            let recordingDate = dateFromFolder(audioURL.deletingLastPathComponent().lastPathComponent)
                ?? createdAt
            let dayStart = Calendar.current.startOfDay(for: recordingDate)

            let day: JournalDay
            if let existingDay = days.first(where: {
                Calendar.current.isDate($0.date, inSameDayAs: dayStart)
            }) {
                day = existingDay
            } else {
                day = JournalDay(date: dayStart)
                days.append(day)
                modelContext.insert(day)
            }

            let checkpointURL = AudioRecorderController.transcriptCheckpointURL(for: audioURL)
            let transcript = (try? String(contentsOf: checkpointURL, encoding: .utf8)) ?? ""
            let clip = RecordingClip(
                createdAt: createdAt,
                duration: duration,
                fileName: relativePath,
                transcript: transcript
            )
            clip.day = day
            day.clips.append(clip)
            modelContext.insert(clip)
            recoveredSomething = true
        }

        if recoveredSomething {
            try? modelContext.save()
        }
    }

    private static func relativePath(of fileURL: URL, below rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count))
    }

    private static func audioDuration(at url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func dateFromFolder(_ folderName: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: folderName)
    }
}
