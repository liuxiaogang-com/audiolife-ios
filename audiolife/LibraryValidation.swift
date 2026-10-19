#if DEBUG
import AVFoundation
import CryptoKit
import Foundation
import SwiftData
import UIKit

/// Opt-in, simulator-only validation. It never runs in Release or normal launches.
@MainActor enum LibraryValidation {
    private struct Failure: Error { let message: String }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func run() async {
        var checks: [String] = []
        var report: [String: Any] = [:]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let instant = ISO8601DateFormatter().date(from: "2026-10-17T16:30:00Z")!
            let china = TimeZone(identifier: "Asia/Shanghai")!
            let newYork = TimeZone(identifier: "America/New_York")!
            let chinese = AppDateFormatting.string(from: instant, timeStyle: .short,
                locale: Locale(identifier: "zh_CN"), timeZone: china)
            let english = AppDateFormatting.string(from: instant, timeStyle: .short,
                locale: Locale(identifier: "en_US"), timeZone: newYork)
            let twelve = AppDateFormatting.string(from: instant, dateStyle: .none, timeStyle: .short,
                locale: Locale(identifier: "en_US@hours=h12"), timeZone: china)
            let twentyFour = AppDateFormatting.string(from: instant, dateStyle: .none, timeStyle: .short,
                locale: Locale(identifier: "en_US@hours=h23"), timeZone: china)
            try require(chinese.contains("2026年10月18日") && english.contains("Oct 17, 2026"),
                        "Date locale or cross-midnight timezone formatting incorrect")
            try require(twelve.contains("12:30") && twentyFour.contains("00:30"),
                        "12/24-hour preference ignored")
            report["date_format_samples"] = ["chinese": chinese, "english": english,
                                             "12_hour": twelve, "24_hour": twentyFour]
            checks.append("date_display_respects_locale_timezone_and_12_or_24_hour_clock")

            let expectedURL = documents.appendingPathComponent("migration-expectations.json")
            if FileManager.default.fileExists(atPath: expectedURL.path) {
                let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as! [String: Any]
                let context = AppModelStore.container.mainContext
                let clips = try context.fetch(FetchDescriptor<RecordingClip>())
                let days = try context.fetch(FetchDescriptor<JournalDay>())
                let todos = try context.fetch(FetchDescriptor<TodoItem>())
                try require(clips.map { $0.id.uuidString }.sorted() == (expected["clipIDs"] as! [String]).sorted(), "Legacy recording IDs changed")
                try require(days.map { $0.id.uuidString }.sorted() == (expected["dayIDs"] as! [String]).sorted(), "Legacy diary IDs changed")
                try require(todos.map { $0.id.uuidString }.sorted() == (expected["todoIDs"] as! [String]).sorted(), "Legacy todo IDs changed")
                let expectedClips = expected["clips"] as! [String: [String: Any]]
                for clip in clips {
                    let old = expectedClips[clip.id.uuidString]!
                    try require(clip.fileName == old["fileName"] as! String, "Legacy audio path changed")
                    let hash = SHA256.hash(data: Data(clip.transcript.utf8)).map { String(format: "%02x", $0) }.joined()
                    try require(hash == old["transcriptSHA256"] as! String, "Legacy transcript changed")
                    try require(clip.day?.id.uuidString == old["dayID"] as? String, "Legacy day relationship changed")
                    try require(clip.isTrashed == old["isTrashed"] as! Bool, "Legacy trash status changed")
                    try require(clip.attachments.isEmpty && clip.manualTitle.isEmpty, "Additive model defaults incorrect")
                }
                let backups = try FileManager.default.contentsOfDirectory(at: DataSafetyBackup.backupRoot, includingPropertiesForKeys: nil)
                try require(!backups.isEmpty, "Pre-migration backup missing")
                let hashes = expected["databaseFileHashes"] as! [String: String]
                for (name, hash) in hashes {
                    try require(try EntryFiles.hash(backups[0].appendingPathComponent(name)) == hash, "Pre-migration snapshot mismatch: " + name)
                }
                checks.append("old_store_migrated_without_losing_IDs_text_audio_paths_days_todos_or_trash")
                checks.append("pre_migration_database_backup_hashes_match_source_fixture")
                report["migration_counts"] = ["records": clips.count, "days": days.count, "todos": todos.count]
            }

            let container = try ModelContainer(for: JournalDay.self, RecordingClip.self, TodoItem.self,
                                               configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            let entry = RecordingClip(duration: 0, fileName: "", transcript: "文字笔记校验")
            context.insert(entry)
            try context.save()
            try require(!entry.hasAudio && entry.day == nil, "Text entry needs audio or date")
            try require(AudioRecorderController.fileURL(for: "") == nil, "Empty audio path resolved to recording directory")
            let id = entry.id
            entry.day = try EntryLibrary.day(for: Date(timeIntervalSince1970: 1_700_000_000), in: context)
            try context.save()
            try require(entry.day?.clips.contains(where: { $0.id == id }) == true, "Diary inverse association failed")
            entry.day = nil
            try context.save()
            let count = try context.fetchCount(FetchDescriptor<RecordingClip>())
            try require(entry.id == id && count == 1, "Moving note duplicated record")
            checks.append("text_note_and_diary_reassignment_preserve_single_record")

            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let source = temporary.appendingPathComponent("校验附件.txt")
            try Data("独立保存的附件".utf8).write(to: source)
            let attachment = try await EntryFiles.importFile(source)
            let duplicate = try await EntryFiles.importFile(source)
            try FileManager.default.removeItem(at: source)
            defer { EntryFiles.remove(attachment); EntryFiles.remove(duplicate) }
            try require(attachment.sha256 == duplicate.sha256 && attachment.id != duplicate.id, "Import hashing or unique paths failed")
            try require(try EntryFiles.hash(EntryFiles.url(for: attachment)!) == attachment.sha256, "Imported file depended on source")
            var traversal = attachment
            traversal.relativePath = "../outside.txt"
            try require(EntryFiles.url(for: traversal) == nil, "Attachment path escaped storage root")
            checks.append("file_import_copies_bytes_hashes_duplicates_and_rejects_path_escape")

            let imageURL = temporary.appendingPathComponent("ocr-test.png")
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 220))
            let image = renderer.image { canvas in
                UIColor.white.setFill(); canvas.fill(CGRect(x: 0, y: 0, width: 900, height: 220))
                ("AudioLife 2026" as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 72), .foregroundColor: UIColor.black])
            }
            try image.pngData()!.write(to: imageURL)
            let ocr = try await EntryFiles.recognizeText(at: imageURL)
            try require(ocr.lowercased().contains("audiolife"), "Image OCR did not recognize fixture")
            checks.append("image_OCR_recognizes_rendered_fixture")

            var interruptedImage = try await EntryFiles.importFile(imageURL)
            defer { EntryFiles.remove(interruptedImage) }
            interruptedImage.processingState = "running"
            entry.attachments = [interruptedImage]
            try context.save()
            EntryProcessingQueue.shared.resume(in: context)
            for _ in 0..<600 {
                if entry.attachments.first?.processingState == "completed" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(entry.attachments.first?.extractedText.lowercased().contains("audiolife") == true,
                        "Interrupted OCR job did not resume")
            var retryImage = entry.attachments[0]
            retryImage.processingState = "failed"
            retryImage.extractedText = "手工校正文案"
            retryImage.isTextEdited = true
            entry.attachments = [retryImage]
            EntryProcessingQueue.shared.retry(entry, in: context)
            for _ in 0..<600 {
                if entry.attachments.first?.processingState == "completed" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(entry.attachments.first?.processingState == "completed"
                        && entry.attachments.first?.extractedText == "手工校正文案",
                        "Retry failed or overwrote a manual correction")
            checks.append("interrupted_job_resumes_and_retry_preserves_manual_text")

            let wav = temporary.appendingPathComponent("audio-test.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            do {
                let audio = try AVAudioFile(forWriting: wav, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
                buffer.frameLength = 16_000
                buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
                try audio.write(from: buffer)
            }
            let audioAttachment = try await EntryFiles.importFile(wav)
            defer { EntryFiles.remove(audioAttachment) }
            try require(audioAttachment.isAudio && audioAttachment.processingState == "queued", "Audio not queued for transcription")
            try require(abs((audioAttachment.duration ?? 0) - 1) < 0.05, "Imported audio duration incorrect")
            entry.attachments = [attachment, audioAttachment]
            EntryProcessingQueue.shared.cancel(entry, in: context)
            try require(entry.attachments.last?.processingState == "cancelled", "Cancelling transcription did not persist")
            checks.append("audio_import_validates_duration_and_persists_cancellation")

            var withText = attachment
            withText.extractedText = "识别内容可以搜索"
            entry.attachments = [withText, audioAttachment, interruptedImage]
            entry.manualTags = ["校验标签"]
            entry.manualTitle = "本地校验"
            try context.save()
            try require(entry.searchableText.contains("识别内容") && entry.searchableText.contains("校验标签"), "Search missing attachment text or tags")
            let draft = EntryDraft(title: "草稿", text: "退出后保留", attachments: [withText])
            try EntryDraftStore.save(draft, key: "validation")
            try require(EntryDraftStore.load(key: "validation") == draft, "Draft round trip failed")
            EntryDraftStore.clear(key: "validation")
            checks.append("search_includes_OCR_tags_and_drafts_round_trip")
            let zip = try await EntryExport.build(entry: entry)
            try require((try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0, "Entry export empty")
            report["export_zip"] = zip.path
            checks.append("mixed_entry_export_creates_nonempty_archive")
            entry.isTrashed = true
            try context.save()
            try require(entry.isEffectivelyTrashed, "Trash failed")
            entry.isTrashed = false
            try context.save()
            try require(!entry.isEffectivelyTrashed && entry.id == id, "Restoring trash changed identity")
            checks.append("trash_and_restore_preserve_entry_identity")
            let disposableFile = try await EntryFiles.importFile(imageURL)
            let disposable = RecordingClip(duration: 0, fileName: "")
            disposable.attachments = [disposableFile]
            context.insert(disposable)
            try context.save()
            try EntryDeletion.permanentlyDelete([disposable], in: context)
            try require(!FileManager.default.fileExists(atPath: EntryFiles.url(for: disposableFile)!.path)
                        && FileManager.default.fileExists(atPath: EntryFiles.url(for: attachment)!.path),
                        "Permanent deletion removed unrelated files or retained its attachment")
            checks.append("permanent_deletion_removes_only_owned_attachment")
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"
            report["error"] = String(describing: error)
        }
        report["checks"] = checks
        let url = documents.appendingPathComponent("library-validation.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        DiagnosticLogger.log("Library validation result=\(report["status"] ?? "unknown")")
    }
}
#endif
