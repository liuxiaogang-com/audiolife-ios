import Foundation
import SwiftData

@MainActor
enum AppModelStore {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: JournalDay.self,
                RecordingClip.self,
                TodoItem.self
            )
        } catch {
            fatalError("无法创建 AudioLife 数据库：\(error.localizedDescription)")
        }
    }()

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
