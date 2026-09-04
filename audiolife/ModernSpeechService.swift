import AVFoundation
import CoreMedia
import Foundation
import Speech

struct SpeechTranscriptionOutput: Sendable {
    let text: String
    let segments: [TranscriptSegment]
}

struct ModernSpeechModelInfo: Sendable {
    enum State: Sendable {
        case installed
        case notInstalled
        case unsupported
        case unavailable
    }

    let state: State
    let localeIdentifier: String?
}

actor ModernSpeechService {
    static let shared = ModernSpeechService()

    enum ServiceError: LocalizedError {
        case unavailable
        case unsupportedLocale
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "当前设备不支持新版语音识别模型。"
            case .unsupportedLocale:
                return "新版语音识别模型暂不支持中文。"
            case .emptyResult:
                return "新版语音识别没有返回文本。"
            }
        }
    }

    private var preparedLocale: Locale?
    private var activeDownloadProgress: Progress?

    func modelInfo() async -> ModernSpeechModelInfo {
        guard SpeechTranscriber.isAvailable else {
            return ModernSpeechModelInfo(state: .unavailable, localeIdentifier: nil)
        }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "zh-CN")
        ) else {
            return ModernSpeechModelInfo(state: .unsupported, localeIdentifier: nil)
        }
        if preparedLocale != nil {
            return ModernSpeechModelInfo(
                state: .installed,
                localeIdentifier: locale.identifier
            )
        }
        let targetIdentifier = locale.identifier(.bcp47)
        let installedIdentifiers = await SpeechTranscriber.installedLocales.map {
            $0.identifier(.bcp47)
        }
        return ModernSpeechModelInfo(
            state: installedIdentifiers.contains(targetIdentifier) ? .installed : .notInstalled,
            localeIdentifier: locale.identifier
        )
    }

    func downloadFraction() -> Double? {
        activeDownloadProgress?.fractionCompleted
    }

    @discardableResult
    func prepare() async throws -> Locale {
        if let preparedLocale { return preparedLocale }
        guard SpeechTranscriber.isAvailable else {
            throw ServiceError.unavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "zh-CN")
        ) else {
            throw ServiceError.unsupportedLocale
        }

        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(
            supporting: [probe]
        ) {
            activeDownloadProgress = installation.progress
            defer { activeDownloadProgress = nil }
            try await installation.downloadAndInstall()
        }
        preparedLocale = locale
        return locale
    }

    func transcribe(audioURL: URL) async throws -> String {
        try await transcribeDetailed(audioURL: audioURL).text
    }

    func transcribeDetailed(audioURL: URL) async throws -> SpeechTranscriptionOutput {
        let locale = try await prepare()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioURL)

        let resultTask = Task<SpeechTranscriptionOutput, Error> {
            var text = ""
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
                segments.append(contentsOf: Self.transcriptSegments(
                    from: result.text,
                    fallbackRange: result.range
                ))
            }
            return SpeechTranscriptionOutput(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                segments: Self.mergeTranscriptSegments(segments)
            )
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let result = try await resultTask.value
            guard !result.text.isEmpty else { throw ServiceError.emptyResult }
            return result
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    nonisolated private static func transcriptSegments(
        from attributedText: AttributedString,
        fallbackRange: CMTimeRange
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []

        for run in attributedText.runs {
            let runText = String(attributedText[run.range].characters)
            guard !runText.isEmpty else { continue }
            if let timeRange = run.audioTimeRange {
                let start = max(0, CMTimeGetSeconds(timeRange.start))
                let duration = max(0.01, CMTimeGetSeconds(timeRange.duration))
                guard start.isFinite, duration.isFinite else { continue }
                segments.append(TranscriptSegment(
                    text: runText,
                    startTime: start,
                    duration: duration,
                    confidence: run.transcriptionConfidence
                ))
            } else if !segments.isEmpty {
                segments[segments.count - 1].text += runText
            }
        }

        if segments.isEmpty {
            let text = String(attributedText.characters)
            let start = max(0, CMTimeGetSeconds(fallbackRange.start))
            let duration = max(0.01, CMTimeGetSeconds(fallbackRange.duration))
            if !text.isEmpty, start.isFinite, duration.isFinite {
                segments.append(TranscriptSegment(
                    text: text,
                    startTime: start,
                    duration: duration
                ))
            }
        }
        return segments
    }

    nonisolated private static func mergeTranscriptSegments(
        _ source: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: TranscriptSegment?

        func shouldFinish(_ text: String) -> Bool {
            text.rangeOfCharacter(
                from: CharacterSet(charactersIn: "。！？!?；;\n")
            ) != nil
        }

        for segment in source.sorted(by: { $0.startTime < $1.startTime }) {
            guard var accumulating = current else {
                current = segment
                continue
            }

            let gap = segment.startTime - accumulating.endTime
            let shouldMerge = accumulating.text.count < 20
                && gap < 1.2
                && !shouldFinish(accumulating.text)
            if shouldMerge {
                let newEnd = max(accumulating.endTime, segment.endTime)
                accumulating.text += segment.text
                accumulating.duration = max(0.01, newEnd - accumulating.startTime)
                if let oldConfidence = accumulating.confidence,
                   let newConfidence = segment.confidence {
                    accumulating.confidence = (oldConfidence + newConfidence) / 2
                } else {
                    accumulating.confidence = accumulating.confidence ?? segment.confidence
                }
                current = accumulating
            } else {
                result.append(accumulating)
                current = segment
            }
        }
        if let current {
            result.append(current)
        }
        return result
    }
}
