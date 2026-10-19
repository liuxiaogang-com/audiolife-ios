import Foundation
import SwiftData

@MainActor enum EntryDeletion {
    /// Commit metadata deletion first; a failed database save must not destroy files.
    static func permanentlyDelete(_ entries: [RecordingClip], day: JournalDay? = nil, in context: ModelContext) throws {
        let files = entries.map { ($0.fileName, $0.attachments) }
        for entry in entries { context.delete(entry) }
        if let day { context.delete(day) }
        do { try context.save() }
        catch { context.rollback(); throw error }
        for (audio, attachments) in files {
            if !audio.isEmpty { AudioRecorderController.removeRecordingFiles(for: audio) }
            for attachment in attachments { EntryFiles.remove(attachment) }
        }
    }
}
