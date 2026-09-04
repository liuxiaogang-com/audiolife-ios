import SwiftUI
import WidgetKit

@main
struct AudioLifeWidgets: WidgetBundle {
    var body: some Widget {
        QuickRecordingControl()
    }
}

struct QuickRecordingControl: ControlWidget {
    static let kind = "com.liuxiaogang.audiolife.instant-recording"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: BeginInstantRecordingIntent()) {
                Label("立即录音", systemImage: "mic.fill")
            }
        }
        .displayName("立即录音")
        .description("开始录音；正在录音时停止并保存。")
    }
}
