import Foundation
import SwiftData

struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var startTime: TimeInterval
    var duration: TimeInterval
    var confidence: Double?

    nonisolated init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        confidence: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.confidence = confidence
    }

    nonisolated var endTime: TimeInterval {
        startTime + duration
    }
}

@Model
final class JournalDay {
    @Attribute(.unique) var id: UUID
    var date: Date
    var createdAt: Date
    var isTrashed: Bool = false
    var trashedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \RecordingClip.day)
    var clips: [RecordingClip]

    init(date: Date) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.createdAt = Date()
        self.clips = []
    }

    var sortedClips: [RecordingClip] {
        activeClips.sorted { $0.createdAt > $1.createdAt }
    }

    var activeClips: [RecordingClip] {
        clips.filter { !$0.isTrashed }
    }

    var trashedClips: [RecordingClip] {
        clips.filter(\.isTrashed).sorted { $0.createdAt > $1.createdAt }
    }

    var totalDuration: TimeInterval {
        activeClips.reduce(0) { $0 + $1.duration }
    }
}

@Model
final class RecordingClip {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var fileName: String
    var transcript: String
    var rawTranscript: String = ""
    var isTranscriptEdited: Bool = false
    var transcriptSegmentsData: Data = Data()
    var aiTitle: String = ""
    var aiSummary: String = ""
    var aiTagsData: Data = Data()
    var manualTagsData: Data = Data()
    var aiProvider: String = ""
    var aiModel: String = ""
    var aiAnalyzedAt: Date?
    var aiLastError: String = ""
    var isTrashed: Bool = false
    var trashedAt: Date?
    var day: JournalDay?

    // Additive fields keep the original SwiftData entity, UUIDs and relationships.
    // A nil day is a free-form note; a day association makes it a diary entry.
    var manualTitle: String = ""
    var attachmentsData: Data = Data()
    var modifiedAt: Date?
    var processingState: String = ""
    var processingError: String = ""

    var hasAudio: Bool { !fileName.isEmpty }

    var attachments: [EntryAttachment] {
        get { (try? JSONDecoder().decode([EntryAttachment].self, from: attachmentsData)) ?? [] }
        set { attachmentsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var displayTitle: String {
        if !manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return manualTitle }
        if !aiTitle.isEmpty { return aiTitle }
        if let line = transcript.split(separator: "\n").first, !line.isEmpty { return String(line.prefix(48)) }
        if let attachment = attachments.first { return attachment.originalName }
        return hasAudio ? "录音" : "未命名笔记"
    }

    var searchableText: String {
        ([manualTitle, transcript, aiTitle, aiSummary] + allTags
         + attachments.flatMap { [$0.originalName, $0.extractedText] }).joined(separator: "\n")
    }

    var isEffectivelyTrashed: Bool { isTrashed || day?.isTrashed == true }

    init(
        createdAt: Date = Date(),
        duration: TimeInterval,
        fileName: String,
        transcript: String = ""
    ) {
        self.id = UUID()
        self.createdAt = createdAt
        self.duration = duration
        self.fileName = fileName
        self.transcript = transcript
        self.rawTranscript = transcript
    }

    var transcriptSegments: [TranscriptSegment] {
        get {
            guard !transcriptSegmentsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode(
                [TranscriptSegment].self,
                from: transcriptSegmentsData
            )) ?? []
        }
        set {
            transcriptSegmentsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var aiTags: [String] {
        get {
            guard !aiTagsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([String].self, from: aiTagsData)) ?? []
        }
        set {
            aiTagsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var manualTags: [String] {
        get {
            guard !manualTagsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([String].self, from: manualTagsData)) ?? []
        }
        set {
            manualTagsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var allTags: [String] {
        var seen = Set<String>()
        return (aiTags + manualTags).compactMap { rawTag in
            let tag = rawTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard !tag.isEmpty else { return nil }
            let key = tag.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "zh_CN")
            )
            return seen.insert(key).inserted ? tag : nil
        }
    }
}

@Model
final class TodoItem {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var title: String
    var notes: String
    var dueDate: Date?
    var isCompleted: Bool
    var completedAt: Date?
    var isSuggested: Bool
    var sourceClipID: UUID?
    var sourceExcerpt: String
    var notificationIdentifier: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        notes: String = "",
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        isSuggested: Bool = false,
        sourceClipID: UUID? = nil,
        sourceExcerpt: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completedAt = nil
        self.isSuggested = isSuggested
        self.sourceClipID = sourceClipID
        self.sourceExcerpt = sourceExcerpt
        self.notificationIdentifier = nil
    }
}
