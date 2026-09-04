import AVFoundation
import SwiftUI

struct RecordingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var day: JournalDay

    @ObservedObject private var recorder = RecordingSessionManager.shared.recorder

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(day.date.chineseFullDate)
                    .font(.headline)
                HStack(spacing: 7) {
                    Circle()
                        .fill(recorder.isRecording ? .red : .secondary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(1 + recorder.audioLevel * 0.35)
                        .shadow(
                            color: .red.opacity(recorder.audioLevel * 0.7),
                            radius: 3 + recorder.audioLevel * 7
                        )
                    Text(recorder.isRecording ? "正在录音 · 新版实时识别" : "准备录音")
                }
                .font(.subheadline)
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
            }

            LiveAudioWaveform(
                level: recorder.audioLevel,
                isActive: recorder.isRecording
            )
            .frame(height: 56)

            liveTranscript

            Text(recorder.elapsed.durationText)
                .font(.system(size: 38, weight: .medium, design: .monospaced))
                .contentTransition(.numericText())

            Button {
                if recorder.isRecording {
                    Task { await finishAndDismiss() }
                } else {
                    Task { _ = await RecordingSessionManager.shared.startRecording(for: day.date) }
                }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title2)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .accessibilityLabel(recorder.isRecording ? "停止并保存" : "开始录音")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(recorder.isRecording)
        .alert(
            "无法录音",
            isPresented: Binding(
                get: { recorder.errorMessage != nil },
                set: { if !$0 { recorder.errorMessage = nil } }
            )
        ) {
            Button("关闭") { dismiss() }
        } message: {
            Text(recorder.errorMessage ?? "请稍后重试。")
        }
        .task {
            _ = await RecordingSessionManager.shared.startRecording(for: day.date)
        }
        .onChange(of: recorder.isRecording) { wasRecording, isRecording in
            if wasRecording && !isRecording {
                dismiss()
            }
        }
        .onDisappear {
            if recorder.isRecording {
                Task {
                    await RecordingSessionManager.shared.stopRecording()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard recorder.isRecording,
                  let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
            Task { await finishAndDismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            guard recorder.isRecording,
                  let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
            Task { await finishAndDismiss() }
        }
    }

    private func finishAndDismiss() async {
        await RecordingSessionManager.shared.stopRecording()
        dismiss()
    }

    private var liveTranscript: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.thinMaterial)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color.red.opacity(recorder.audioLevel * 0.16),
                            Color.clear
                        ],
                        center: .bottomTrailing,
                        startRadius: 4,
                        endRadius: 150
                    )
                )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.secondary)
                        .frame(width: 5, height: 5)
                        .scaleEffect(1 + recorder.audioLevel * 0.55)
                    Text("实时文字")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                    Spacer()
                    if recorder.isRecording && recorder.audioLevel > 0.035 {
                        Text("识别中")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .foregroundStyle(.secondary)

                if recorder.transcriptLines.isEmpty {
                    HStack(spacing: 8) {
                        VoiceListeningDots(
                            level: recorder.audioLevel,
                            isActive: recorder.isRecording
                        )
                        Text(
                            recorder.isRecording
                                ? (recorder.audioLevel > 0.035 ? "正在捕捉你的声音…" : "正在聆听…")
                                : "说点什么吧"
                        )
                        .font(.headline)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(recorder.transcriptLines.enumerated()), id: \.offset) { index, line in
                            let distance = recorder.transcriptLines.count - 1 - index
                            if distance == 0 {
                                LiveCurrentTranscriptLine(
                                    text: line,
                                    level: recorder.audioLevel,
                                    isActive: recorder.isRecording
                                )
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            } else {
                                Text(line)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary.opacity(distance == 1 ? 0.62 : 0.28))
                                    .blur(radius: distance > 1 ? 0.45 : 0)
                                    .scaleEffect(distance == 1 ? 0.97 : 0.94, anchor: .leading)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 118)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            Color.red.opacity(recorder.audioLevel * 0.28),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: Color.red.opacity(recorder.audioLevel * 0.1), radius: 18, y: 7)
        .animation(.snappy, value: recorder.transcriptLines)
        .animation(.smooth(duration: 0.2), value: recorder.audioLevel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("实时转写")
    }
}

private struct LiveCurrentTranscriptLine: View {
    let text: String
    let level: Double
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isActive)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2.4) / 2.4
            let highlight = UnitPoint(x: phase * 1.8 - 0.4, y: 0.5)

            Text(text)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.primary,
                            Color.primary,
                            Color.red.opacity(0.9),
                            Color.pink,
                            Color.primary
                        ],
                        startPoint: UnitPoint(x: highlight.x - 0.28, y: 0.5),
                        endPoint: UnitPoint(x: highlight.x + 0.28, y: 0.5)
                    )
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaleEffect(1 + min(level, 1) * 0.012, anchor: .leading)
                .shadow(color: Color.red.opacity(level * 0.22), radius: 7)
                .id(text)
        }
        .accessibilityLabel(text)
    }
}

private struct VoiceListeningDots: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let pulse = (sin(time * 5.5 + Double(index) * 1.35) + 1) / 2
                    Circle()
                        .fill(Color.red.opacity(0.36 + pulse * 0.5))
                        .frame(width: 5, height: 5)
                        .offset(y: -pulse * max(1.5, level * 5))
                }
            }
            .frame(width: 22, height: 15)
        }
        .accessibilityHidden(true)
    }
}

private struct LiveAudioWaveform: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<25, id: \.self) { index in
                    let position = Double(index) / 24.0
                    let envelope = sin(position * .pi)
                    let motion = (sin(time * 9 + Double(index) * 0.78) + 1) / 2
                    let activeLevel = isActive ? max(0.025, level) : 0
                    let height = 4 + envelope * activeLevel * 48 * (0.58 + motion * 0.42)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .red.opacity(0.55 + activeLevel * 0.35),
                                    .pink.opacity(0.9)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 3, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.12), value: level)
        }
        .accessibilityHidden(true)
    }
}
