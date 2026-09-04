import AVFoundation
import Accelerate
import Combine
import Foundation
import Speech
import SwiftUI

struct RecordingResult {
    let fileName: String
    let duration: TimeInterval
    let transcript: String
    let usedModernTranscription: Bool
}

private struct TimedTranscriptPiece: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

nonisolated private final class AudioLevelSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission = 0.0
    private var smoothedLevel = 0.0

    func sample(_ buffer: AVAudioPCMBuffer) -> Double? {
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        guard now - lastEmission >= 0.045,
              buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0] else { return nil }

        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = min(1, max(0, Double((decibels + 52) / 52)))
        smoothedLevel = smoothedLevel * 0.58 + normalized * 0.42
        lastEmission = now
        return smoothedLevel
    }
}

@MainActor
final class AudioRecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var transcriptLines: [String] = []
    @Published private(set) var audioLevel: Double = 0
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var audioFile: AVAudioFile?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var liveModernSession: LiveModernTranscriptionSession?
    private var relativeFilePath: String?
    private var outputURL: URL?
    private var startedAt: Date?
    private var fullTranscript = ""
    private var transcriptPieces: [TimedTranscriptPiece] = []
    private var recognitionDidFinish = false
    private var usedModernLiveTranscription = false
    private var timer: Timer?
    private let audioLevelSampler = AudioLevelSampler()

    func start(for date: Date) async -> Bool {
        guard !isRecording else { return true }
        errorMessage = nil

        guard await microphonePermission() else {
            errorMessage = "请在系统设置中允许 AudioLife 使用麦克风。"
            DiagnosticLogger.log("microphone permission denied")
            return false
        }
        let canTranscribe = await speechPermission()
        var pendingFileURL: URL?
        var tapInstalled = false
        var pendingModernSession: LiveModernTranscriptionSession?

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .record,
                mode: .measurement,
                options: [.allowBluetoothHFP]
            )
            DiagnosticLogger.log("audio session category configured")
            try session.setActive(true)
            DiagnosticLogger.log("audio session activated")

            let dayFolder = Self.dayFolderName(for: date)
            let leafName = "\(UUID().uuidString).caf"
            let fileName = "\(dayFolder)/\(leafName)"
            let fileURL = try Self.dayDirectory(for: date)
                .appendingPathComponent(leafName)
            pendingFileURL = fileURL

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RecordingError.couldNotStart
            }

            let newAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: inputFormat.settings
            )
            var request: SFSpeechAudioBufferRecognitionRequest?
            if canTranscribe {
                do {
                    let session = try await LiveModernTranscriptionSession.start(
                        inputFormat: inputFormat
                    ) { [weak self] text in
                        self?.replaceLiveTranscript(text)
                    }
                    pendingModernSession = session
                    DiagnosticLogger.log("live transcription using SpeechAnalyzer")
                } catch {
                    DiagnosticLogger.log(
                        "live SpeechAnalyzer unavailable, falling back: "
                        + error.localizedDescription
                    )
                }
            }

            if canTranscribe,
               pendingModernSession == nil,
               let speechRecognizer,
               speechRecognizer.isAvailable {
                let speechRequest = SFSpeechAudioBufferRecognitionRequest()
                speechRequest.shouldReportPartialResults = true
                speechRequest.addsPunctuation = true
                speechRequest.taskHint = .dictation
                if speechRecognizer.supportsOnDeviceRecognition {
                    speechRequest.requiresOnDeviceRecognition = true
                }

                recognitionTask = speechRecognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
                    let update = result.map {
                        Self.transcriptPieces(from: $0.bestTranscription)
                    }
                    let didFinish = result?.isFinal == true || error != nil
                    Task { @MainActor in
                        if let update, !update.isEmpty {
                            self?.updateTranscript(with: update)
                        }
                        if didFinish {
                            self?.recognitionDidFinish = true
                        }
                    }
                }
                request = speechRequest
            }

            let audioLevelSampler = self.audioLevelSampler
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                try? newAudioFile.write(from: buffer)
                pendingModernSession?.append(buffer)
                request?.append(buffer)
                if let level = audioLevelSampler.sample(buffer) {
                    Task { @MainActor in
                        self?.audioLevel = level
                    }
                }
            }
            tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

            audioFile = newAudioFile
            recognitionRequest = request
            liveModernSession = pendingModernSession
            relativeFilePath = fileName
            outputURL = fileURL
            startedAt = Date()
            fullTranscript = ""
            transcriptPieces = []
            recognitionDidFinish = false
            usedModernLiveTranscription = pendingModernSession != nil
            transcriptLines = []
            persistTranscriptCheckpoint()
            elapsed = 0
            audioLevel = 0
            isRecording = true
            startTimer()
            return true
        } catch {
            if tapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            audioEngine.stop()
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            if let pendingModernSession {
                await pendingModernSession.cancel()
            }
            recognitionRequest = nil
            recognitionTask = nil
            audioFile = nil
            relativeFilePath = nil
            outputURL = nil
            startedAt = nil
            timer?.invalidate()
            timer = nil
            if let pendingFileURL {
                try? FileManager.default.removeItem(at: pendingFileURL)
            }
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            let nsError = error as NSError
            DiagnosticLogger.log(
                "audio start failed domain=\(nsError.domain) code=\(nsError.code) "
                + "message=\(error.localizedDescription)"
            )
            errorMessage = "无法开始录音：\(error.localizedDescription)"
            return false
        }
    }

    func stop() async -> RecordingResult? {
        guard isRecording, let relativeFilePath, let outputURL else { return nil }

        let duration = elapsed
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        timer?.invalidate()
        timer = nil
        audioFile = nil
        self.relativeFilePath = nil
        startedAt = nil
        isRecording = false
        elapsed = 0
        audioLevel = 0

        if let liveModernSession {
            await liveModernSession.finish()
            self.liveModernSession = nil
        // 旧模型回退路径：endAudio 后最多等待 1.5 秒取得最终结果。
        } else if recognitionTask != nil {
            for _ in 0..<15 where !recognitionDidFinish {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        persistTranscriptCheckpoint()
        self.outputURL = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard duration >= 0.2 else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return RecordingResult(
            fileName: relativeFilePath,
            duration: duration,
            transcript: fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
            usedModernTranscription: usedModernLiveTranscription
        )
    }

    private func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func speechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    private func updateTranscript(with incoming: [TimedTranscriptPiece]) {
        guard let incomingStart = incoming.map(\.start).min(),
              let incomingEnd = incoming.map(\.end).max() else { return }

        // partial result 会不断修订同一段音频。按音频时间范围替换，而不是把每版文本追加。
        transcriptPieces.removeAll { existing in
            existing.start < incomingEnd && existing.end > incomingStart
        }
        transcriptPieces.append(contentsOf: incoming)
        transcriptPieces.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }
        fullTranscript = transcriptPieces
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        persistTranscriptCheckpoint()
        let recentCharacters = Array(fullTranscript.suffix(54))
        transcriptLines = stride(from: 0, to: recentCharacters.count, by: 18).map { start in
            let end = min(start + 18, recentCharacters.count)
            return String(recentCharacters[start..<end])
        }
    }

    private func replaceLiveTranscript(_ text: String) {
        fullTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        persistTranscriptCheckpoint()
        let recentCharacters = Array(fullTranscript.suffix(54))
        transcriptLines = stride(from: 0, to: recentCharacters.count, by: 18).map { start in
            let end = min(start + 18, recentCharacters.count)
            return String(recentCharacters[start..<end])
        }
    }

    nonisolated private static func transcriptPieces(
        from transcription: SFTranscription
    ) -> [TimedTranscriptPiece] {
        let formatted = transcription.formattedString as NSString
        let segments = transcription.segments

        return segments.enumerated().compactMap { index, segment in
            let location = segment.substringRange.location
            let nextLocation = index + 1 < segments.count
                ? segments[index + 1].substringRange.location
                : formatted.length
            guard location >= 0,
                  nextLocation > location,
                  nextLocation <= formatted.length else { return nil }
            let text = formatted.substring(
                with: NSRange(location: location, length: nextLocation - location)
            )
            return TimedTranscriptPiece(
                start: segment.timestamp,
                end: max(segment.timestamp + segment.duration, segment.timestamp + 0.01),
                text: text
            )
        }
    }

    private func persistTranscriptCheckpoint() {
        guard let outputURL else { return }
        let checkpointURL = Self.transcriptCheckpointURL(for: outputURL)
        try? Data(fullTranscript.utf8).write(to: checkpointURL, options: .atomic)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    static func recordingsDirectory() throws -> URL {
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = baseURL.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func dayDirectory(for date: Date) throws -> URL {
        let directory = try recordingsDirectory()
            .appendingPathComponent(dayFolderName(for: date), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func dayFolderName(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func fileURL(for fileName: String) -> URL? {
        guard let directory = try? recordingsDirectory() else { return nil }
        let directURL = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }

        guard !fileName.contains("/") else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let candidate as URL in enumerator where candidate.lastPathComponent == fileName {
            return candidate
        }
        return nil
    }

    static func transcriptCheckpointURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("transcript.txt")
    }

    static func removeRecordingFiles(for fileName: String) {
        guard let audioURL = fileURL(for: fileName) else { return }
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: transcriptCheckpointURL(for: audioURL))
    }
}

@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var playingClipID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(clip: RecordingClip) {
        if playingClipID == clip.id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                timer?.invalidate()
                timer = nil
            } else {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    guard player.play() else { throw PlaybackError.couldNotStart }
                    isPlaying = true
                    watchPlayback()
                } catch {
                    stop()
                }
            }
            return
        }
        guard let url = AudioRecorderController.fileURL(for: clip.fileName) else { return }

        do {
            stop()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.prepareToPlay()
            guard newPlayer.play() else { throw PlaybackError.couldNotStart }
            player = newPlayer
            playingClipID = clip.id
            isPlaying = true
            currentTime = 0
            duration = newPlayer.duration
            watchPlayback()
        } catch {
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingClipID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func seek(clip: RecordingClip, to time: TimeInterval) {
        if playingClipID != clip.id {
            toggle(clip: clip)
        }
        guard let player, playingClipID == clip.id else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
        if !player.isPlaying {
            player.play()
            isPlaying = true
            watchPlayback()
        }
    }

    private func watchPlayback() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let player = self.player, player.isPlaying else {
                    self.stop()
                    return
                }
                self.currentTime = player.currentTime
            }
        }
    }
}

private enum RecordingError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "录音设备没有成功启动。"
        }
    }
}

private enum PlaybackError: Error {
    case couldNotStart
}
