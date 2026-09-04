import AVFoundation
import Foundation
import SwiftData

@MainActor
final class RecordingSessionManager {
    static let shared = RecordingSessionManager()

    let recorder = AudioRecorderController()
    private var recordingDay = Calendar.current.startOfDay(for: Date())
    private var isFinishing = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private init() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
            Task { @MainActor in
                await self?.stopRecording()
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
            Task { @MainActor in
                await self?.stopRecording()
            }
        }
    }

    func toggleRecording() async {
        DiagnosticLogger.log("toggleRecording isRecording=\(recorder.isRecording)")
        if recorder.isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    @discardableResult
    func startRecording(for date: Date = Date()) async -> Bool {
        if recorder.isRecording { return true }
        guard !isFinishing else { return false }

        recordingDay = Calendar.current.startOfDay(for: date)
        DiagnosticLogger.log("startRecording requested")

        guard await recorder.start(for: date) else {
            DiagnosticLogger.log("audio recorder failed: \(recorder.errorMessage ?? "unknown error")")
            return false
        }
        DiagnosticLogger.log("audio recorder started")
        return true
    }

    func stopRecording() async {
        guard !isFinishing else { return }
        isFinishing = true
        DiagnosticLogger.log("stopRecording requested isRecording=\(recorder.isRecording)")

        let result = await recorder.stop()
        if let result {
            let clip = save(result)
            improveTranscriptInBackground(for: clip)
            let configuration = AITextConfiguration.current()
            if !(configuration.isReady && configuration.automaticallyOrganizes) {
                createTodoSuggestions(for: clip)
            }
            DiagnosticLogger.log("recording saved file=\(result.fileName) duration=\(result.duration)")
        } else {
            DiagnosticLogger.log("stopRecording had no active result")
        }

        isFinishing = false
    }

    private func save(_ result: RecordingResult) -> RecordingClip {
        let context = AppModelStore.container.mainContext
        let targetDay = recordingDay
        let descriptor = FetchDescriptor<JournalDay>()
        let days = (try? context.fetch(descriptor)) ?? []

        let day: JournalDay
        if let existing = days.first(where: {
            !$0.isTrashed && Calendar.current.isDate($0.date, inSameDayAs: targetDay)
        }) {
            day = existing
        } else {
            day = JournalDay(date: targetDay)
            context.insert(day)
        }

        let clip = RecordingClip(
            duration: result.duration,
            fileName: result.fileName,
            transcript: result.transcript
        )
        clip.day = day
        day.clips.append(clip)
        context.insert(clip)
        try? context.save()
        DiagnosticLogger.log("SwiftData save completed")
        return clip
    }

    private func improveTranscriptInBackground(for clip: RecordingClip) {
        guard let audioURL = AudioRecorderController.fileURL(for: clip.fileName) else { return }
        let originalTranscript = clip.transcript

        Task {
            do {
                let output = try await ModernSpeechService.shared.transcribeDetailed(
                    audioURL: audioURL
                )
                // 如果未来加入人工编辑，后台结果不应覆盖用户在转写期间做出的修改。
                clip.rawTranscript = output.text
                clip.transcriptSegments = output.segments
                if !clip.isTranscriptEdited, clip.transcript == originalTranscript {
                    clip.transcript = output.text
                }
                try? Data(output.text.utf8).write(
                    to: AudioRecorderController.transcriptCheckpointURL(for: audioURL),
                    options: .atomic
                )
                try AppModelStore.container.mainContext.save()
                DiagnosticLogger.log("modern transcript saved file=\(clip.fileName)")

                let configuration = AITextConfiguration.current()
                if configuration.isReady, configuration.automaticallyOrganizes,
                   !clip.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await AITextOrganizer.organize(
                            clip: clip,
                            configuration: configuration
                        )
                        DiagnosticLogger.log("AI text analysis saved file=\(clip.fileName)")
                    } catch {
                        clip.aiLastError = error.localizedDescription
                        try? AppModelStore.container.mainContext.save()
                        DiagnosticLogger.log(
                            "AI text analysis failed file=\(clip.fileName) "
                            + "message=\(error.localizedDescription)"
                        )
                    }
                }
            } catch {
                DiagnosticLogger.log(
                    "modern transcript unavailable file=\(clip.fileName) "
                    + "message=\(error.localizedDescription)"
                )
            }
        }
    }

    private func createTodoSuggestions(for clip: RecordingClip) {
        let candidates = LocalTodoExtractor.extract(
            from: clip.transcript,
            sourceClipID: clip.id,
            referenceDate: clip.createdAt
        )
        guard !candidates.isEmpty else { return }

        let context = AppModelStore.container.mainContext
        var ids: [UUID] = []
        for candidate in candidates {
            let item = TodoItem(
                title: candidate.title,
                dueDate: candidate.dueDate,
                isSuggested: true,
                sourceClipID: clip.id,
                sourceExcerpt: candidate.sourceExcerpt
            )
            context.insert(item)
            ids.append(item.id)
        }
        try? context.save()
        NotificationCenter.default.post(
            name: .todoSuggestionsCreated,
            object: nil,
            userInfo: ["ids": ids]
        )
    }
}
