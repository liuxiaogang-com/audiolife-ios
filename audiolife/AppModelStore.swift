import Foundation
import SwiftData

@MainActor
enum AppModelStore {
    static let loadResult: Result<ModelContainer, Error> = {
        do {
            try DataSafetyBackup.prepareIfNeeded()
            let container = try ModelContainer(
                for: JournalDay.self,
                RecordingClip.self,
                TodoItem.self
            )
            UserDefaults.standard.set(1, forKey: "entry-schema-version")
            return .success(container)
        } catch {
            DiagnosticLogger.log("Database open/migration failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }()

    static var container: ModelContainer {
        guard case .success(let container) = loadResult else {
            preconditionFailure("Database unavailable; present recovery view before accessing models")
        }
        return container
    }

    static func migrateLegacyContentIfNeeded() {
        let context = container.mainContext
        let clips = (try? context.fetch(FetchDescriptor<RecordingClip>())) ?? []
        var changed = false
        for clip in clips where clip.rawTranscript.isEmpty && !clip.transcript.isEmpty {
            clip.rawTranscript = clip.transcript
            changed = true
        }
        if changed {
            try? context.save()
        }
    }
}
