import AppIntents
import Foundation

struct BeginInstantRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "AudioLife 快速录音"
    static let description = IntentDescription("没有录音时立即开始，正在录音时停止并保存。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @MainActor
    func perform() async throws -> some IntentResult {
#if WIDGET_EXTENSION
        return .result()
#else
        let manager = RecordingSessionManager.shared
        if manager.recorder.isRecording {
            DiagnosticLogger.log("BeginInstantRecordingIntent stopping active recording")
            await manager.stopRecording()
        } else {
            DiagnosticLogger.log("BeginInstantRecordingIntent opening recorder")
            AppRouter.shared.requestQuickRecording()
        }
        return .result()
#endif
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "停止录音"
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
#if WIDGET_EXTENSION
        return .result()
#else
        DiagnosticLogger.log("StopRecordingIntent perform started")
        await RecordingSessionManager.shared.stopRecording()
        DiagnosticLogger.log("StopRecordingIntent perform finished")
        return .result()
#endif
    }
}
