@preconcurrency import AVFoundation
import Foundation
import Speech

nonisolated private struct SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

final class LiveModernTranscriptionSession: @unchecked Sendable {
    private let bufferContinuation: AsyncStream<SendableAudioBuffer>.Continuation
    private let processingTask: Task<Void, Never>
    private let analysisTask: Task<Void, Never>
    private let resultTask: Task<Void, Never>
    private let analyzer: SpeechAnalyzer

    private init(
        bufferContinuation: AsyncStream<SendableAudioBuffer>.Continuation,
        processingTask: Task<Void, Never>,
        analysisTask: Task<Void, Never>,
        resultTask: Task<Void, Never>,
        analyzer: SpeechAnalyzer
    ) {
        self.bufferContinuation = bufferContinuation
        self.processingTask = processingTask
        self.analysisTask = analysisTask
        self.resultTask = resultTask
        self.analyzer = analyzer
    }

    static func start(
        inputFormat: AVAudioFormat,
        onTranscript: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> LiveModernTranscriptionSession {
        let locale = try await ModernSpeechService.shared.prepare()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: inputFormat
        ) else {
            throw ModernSpeechService.ServiceError.unavailable
        }

        let (bufferStream, bufferContinuation) = AsyncStream.makeStream(
            of: SendableAudioBuffer.self,
            bufferingPolicy: .bufferingNewest(48)
        )
        let (inputStream, inputContinuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(96)
        )

        let resultTask = Task {
            var finalized = ""
            var volatile = ""
            var didLogFirstResult = false
            do {
                for try await result in transcriber.results {
                    if !didLogFirstResult {
                        didLogFirstResult = true
                        DiagnosticLogger.log(
                            "live SpeechAnalyzer produced first result final=\(result.isFinal)"
                        )
                    }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    onTranscript(finalized + volatile)
                }
            } catch {
                // 已经写入磁盘的原始录音不受转写流错误影响。
            }
        }

        let processingTask = Task.detached(priority: .userInitiated) {
            let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
            for await sendableBuffer in bufferStream {
                do {
                    let converted = try convert(
                        sendableBuffer.value,
                        to: analyzerFormat,
                        using: converter
                    )
                    inputContinuation.yield(AnalyzerInput(buffer: converted))
                } catch {
                    continue
                }
            }
            inputContinuation.finish()
        }

        let analysisTask = Task {
            do {
                let lastSample = try await analyzer.analyzeSequence(inputStream)
                if let lastSample {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }

        return LiveModernTranscriptionSession(
            bufferContinuation: bufferContinuation,
            processingTask: processingTask,
            analysisTask: analysisTask,
            resultTask: resultTask,
            analyzer: analyzer
        )
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        bufferContinuation.yield(SendableAudioBuffer(value: copy))
    }

    func finish() async {
        bufferContinuation.finish()
        await processingTask.value
        await analysisTask.value
        await resultTask.value
    }

    func cancel() async {
        bufferContinuation.finish()
        processingTask.cancel()
        analysisTask.cancel()
        resultTask.cancel()
        await analyzer.cancelAndFinishNow()
    }

    nonisolated private static func copy(
        _ source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else { continue }
            let byteCount = min(
                Int(sourceBuffer.mDataByteSize),
                Int(destinationBuffer.mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffer.mDataByteSize = UInt32(byteCount)
            destinationBuffers[index] = destinationBuffer
        }
        return copy
    }

    nonisolated private static func convert(
        _ input: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        using converter: AVAudioConverter?
    ) throws -> AVAudioPCMBuffer {
        guard let converter else { return input }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(input.frameLength) * ratio) + 32)
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw ModernSpeechService.ServiceError.unavailable
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error else {
            throw ModernSpeechService.ServiceError.unavailable
        }
        return output
    }
}
