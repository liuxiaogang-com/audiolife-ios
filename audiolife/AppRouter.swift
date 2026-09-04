import AppIntents
import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var quickRecordingRequest = UUID()
    var shouldPresentQuickRecorder = false

    private init() {}

    func requestQuickRecording() {
        shouldPresentQuickRecorder = true
        quickRecordingRequest = UUID()
    }

    func consumeQuickRecordingRequest() {
        shouldPresentQuickRecorder = false
    }

    func handle(url: URL) {
        guard url.scheme == "audiolife", url.host == "record" else { return }
        requestQuickRecording()
    }
}

struct AudioLifeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BeginInstantRecordingIntent(),
            phrases: [
                "用 \(.applicationName) 快速录音",
                "在 \(.applicationName) 记一段声音"
            ],
            shortTitle: "AudioLife 快速录音",
            systemImageName: "mic.fill"
        )
    }
}
