import AVFoundation
import Foundation
import SwiftData

@MainActor
final class EntryProcessingQueue {
    static let shared = EntryProcessingQueue()
    private var task: Task<Void, Never>?
    private var activeEntryID: UUID?

    func resume(in context: ModelContext) {
        guard task == nil else { return }
        task = Task {
            // A persisted running state means the previous execution was interrupted.
            let entries = (try? context.fetch(FetchDescriptor<RecordingClip>())) ?? []
            for entry in entries {
                if entry.processingState == "running" { entry.processingState = "queued" }
                var attachments = entry.attachments
                let interrupted = attachments.contains { $0.processingState == "running" }
                for index in attachments.indices where attachments[index].processingState == "running" {
                    attachments[index].processingState = "queued"
                }
                if interrupted { entry.attachments = attachments }
            }
            try? context.save()
            while !Task.isCancelled {
                let all = (try? context.fetch(FetchDescriptor<RecordingClip>())) ?? []
                guard let entry = all.first(where: {
                    !$0.isEffectivelyTrashed && ($0.processingState == "queued"
                        || $0.attachments.contains { $0.processingState == "queued" })
                }) else { break }
                activeEntryID = entry.id
                if entry.processingState == "queued" { await processAudio(entry, context: context) }
                if let attachment = entry.attachments.first(where: { $0.processingState == "queued" }) {
                    await processAttachment(attachment, entry: entry, context: context)
                }
            }
            activeEntryID = nil
            task = nil
            // Cancellation of one job must not strand other queued records.
            if ((try? context.fetch(FetchDescriptor<RecordingClip>())) ?? []).contains(where: {
                !$0.isEffectivelyTrashed && ($0.processingState == "queued" || $0.attachments.contains { $0.processingState == "queued" })
            }) { resume(in: context) }
        }
    }

    func retry(_ entry: RecordingClip, in context: ModelContext) {
        if entry.hasAudio, ["failed", "cancelled"].contains(entry.processingState) {
            entry.processingState = "queued"
            entry.processingError = ""
        }
        var attachments = entry.attachments
        for index in attachments.indices where ["failed", "cancelled"].contains(attachments[index].processingState) {
            attachments[index].processingState = "queued"
            attachments[index].processingError = ""
        }
        entry.attachments = attachments
        try? context.save()
        resume(in: context)
    }

    func cancel(_ entry: RecordingClip, in context: ModelContext) {
        if ["queued", "running"].contains(entry.processingState) { entry.processingState = "cancelled" }
        var attachments = entry.attachments
        for index in attachments.indices where ["queued", "running"].contains(attachments[index].processingState) {
            attachments[index].processingState = "cancelled"
        }
        entry.attachments = attachments
        try? context.save()
        if activeEntryID == entry.id { task?.cancel() }
    }

    private func processAudio(_ entry: RecordingClip, context: ModelContext) async {
        entry.processingState = "running"
        entry.processingError = ""
        try? context.save()
        do {
            guard let url = AudioRecorderController.fileURL(for: entry.fileName) else { throw CocoaError(.fileNoSuchFile) }
            let result = try await ModernSpeechService.shared.transcribeDetailed(audioURL: url)
            guard entry.modelContext != nil, !entry.isDeleted, entry.processingState != "cancelled" else { return }
            entry.rawTranscript = result.text
            entry.transcriptSegments = result.segments
            if !entry.isTranscriptEdited { entry.transcript = result.text }
            entry.processingState = "completed"
        } catch {
            guard entry.modelContext != nil, !entry.isDeleted, entry.processingState != "cancelled" else { return }
            entry.processingState = "failed"
            entry.processingError = error.localizedDescription
        }
        try? context.save()
    }

    private func processAttachment(_ attachment: EntryAttachment, entry: RecordingClip, context: ModelContext) async {
        update(attachment.id, entry: entry) { $0.processingState = "running"; $0.processingError = "" }
        try? context.save()
        do {
            guard let url = EntryFiles.url(for: attachment) else { throw CocoaError(.fileNoSuchFile) }
            let text: String
            if attachment.isImage { text = try await EntryFiles.recognizeText(at: url) }
            else if attachment.isAudio { text = try await ModernSpeechService.shared.transcribe(audioURL: url) }
            else { text = "" }
            guard entry.modelContext != nil, !entry.isDeleted, entry.attachments.first(where: { $0.id == attachment.id })?.processingState != "cancelled" else { return }
            update(attachment.id, entry: entry) {
                $0.originalExtractedText = text
                if !$0.isTextEdited { $0.extractedText = text }
                $0.processingState = "completed"
            }
        } catch {
            guard entry.modelContext != nil, !entry.isDeleted, entry.attachments.first(where: { $0.id == attachment.id })?.processingState != "cancelled" else { return }
            update(attachment.id, entry: entry) { $0.processingState = "failed"; $0.processingError = error.localizedDescription }
        }
        try? context.save()
    }

    private func update(_ id: UUID, entry: RecordingClip, change: (inout EntryAttachment) -> Void) {
        var items = entry.attachments
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        entry.attachments = items
    }
}
