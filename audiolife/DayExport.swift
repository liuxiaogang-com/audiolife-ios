import SwiftUI
import UIKit
import AVFoundation
import Combine

enum DayExportMode: Sendable {
    case documentOnly
    case audioOnly
    case documentAndAudio
}

@MainActor
final class DayExportProgressModel: ObservableObject {
    @Published var fraction = 0.0
    @Published var status = "正在准备导出…"

    func reset() {
        fraction = 0
        status = "正在准备导出…"
    }

    nonisolated func report(_ fraction: Double, status: String) {
        Task { @MainActor in
            self.fraction = min(1, max(0, fraction))
            self.status = status
        }
    }
}

struct DayExportSnapshot: Sendable {
    struct Clip: Sendable {
        let id: UUID
        let createdAt: Date
        let duration: TimeInterval
        let transcript: String
        let audioURL: URL?
    }

    let date: Date
    let clips: [Clip]

    @MainActor
    init(day: JournalDay) {
        date = day.date
        clips = day.sortedClips.reversed().map { clip in
            let audioURL = AudioRecorderController.fileURL(for: clip.fileName)
            return Clip(
                id: clip.id,
                createdAt: clip.createdAt,
                duration: clip.duration,
                transcript: clip.transcript,
                audioURL: audioURL
            )
        }
    }
}

enum DayExportBuilder {
    nonisolated static func build(
        snapshot: DayExportSnapshot,
        mode: DayExportMode,
        progress: DayExportProgressModel
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try buildSynchronously(snapshot: snapshot, mode: mode, progress: progress)
        }.value
    }

    nonisolated private static func buildSynchronously(
        snapshot: DayExportSnapshot,
        mode: DayExportMode,
        progress: DayExportProgressModel
    ) throws -> URL {
        progress.report(0.02, status: "正在准备导出…")
        let fileManager = FileManager.default
        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AudioLifeExports", isDirectory: true)
        try? fileManager.removeItem(at: exportRoot)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        let dayName = formatted(snapshot.date, as: "yyyy-MM-dd")
        let packageName = "AudioLife-\(dayName)"

        let documentOnly: Bool
        let audioOnly: Bool
        let includesDocument: Bool
        switch mode {
        case .documentOnly:
            documentOnly = true
            audioOnly = false
            includesDocument = false
        case .audioOnly:
            documentOnly = false
            audioOnly = true
            includesDocument = false
        case .documentAndAudio:
            documentOnly = false
            audioOnly = false
            includesDocument = true
        }

        if documentOnly {
            let markdownURL = exportRoot.appendingPathComponent("\(packageName).md")
            let markdown = markdownDocument(snapshot: snapshot, includeAudioLinks: false)
            try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
            progress.report(1, status: "导出完成")
            return markdownURL
        }

        let packageURL = exportRoot.appendingPathComponent(
            audioOnly ? "\(packageName)-音频" : packageName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

        if includesDocument {
            let markdownURL = packageURL.appendingPathComponent("日记.md")
            try Data(markdownDocument(snapshot: snapshot, includeAudioLinks: true).utf8)
                .write(to: markdownURL, options: .atomic)

            let manifestURL = packageURL.appendingPathComponent("manifest.json")
            try manifestData(snapshot: snapshot).write(to: manifestURL, options: .atomic)
        }

        let audioDirectory: URL
        if includesDocument {
            audioDirectory = packageURL.appendingPathComponent("audio", isDirectory: true)
            try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        } else {
            audioDirectory = packageURL
        }

        let availableClips: [(index: Int, clip: DayExportSnapshot.Clip, sourceURL: URL, weight: Double)] = snapshot.clips.enumerated().compactMap { index, clip in
            guard let sourceURL = clip.audioURL,
                  fileManager.fileExists(atPath: sourceURL.path) else { return nil }
            return (index, clip, sourceURL, max(1.0, clip.duration))
        }
        let totalWeight = max(1.0, availableClips.reduce(0.0) { $0 + $1.weight })
        var completedWeight = 0.0

        for (index, clip, sourceURL, weight) in availableClips {
            let name = audioFileName(for: clip, index: index)
            try convertToWAV(
                sourceURL: sourceURL,
                destinationURL: audioDirectory.appendingPathComponent(name)
            ) { clipProgress in
                let audioProgress = (completedWeight + weight * clipProgress) / totalWeight
                progress.report(
                    0.04 + audioProgress * 0.72,
                    status: "正在转换音频…"
                )
            }
            completedWeight += weight
        }

        let zipURL = exportRoot.appendingPathComponent("\(packageURL.lastPathComponent).zip")
        try ZIPArchiveWriter.createArchive(from: packageURL, at: zipURL) { zipProgress in
            progress.report(
                0.76 + zipProgress * 0.24,
                status: "正在生成 ZIP…"
            )
        }
        try? fileManager.removeItem(at: packageURL)
        progress.report(1, status: "导出完成")
        return zipURL
    }

    nonisolated private static func markdownDocument(
        snapshot: DayExportSnapshot,
        includeAudioLinks: Bool
    ) -> String {
        let totalDuration = snapshot.clips.reduce(0) { $0 + $1.duration }
        var lines = [
            "# \(formatted(snapshot.date, as: "yyyy年M月d日 EEEE"))",
            "",
            "> \(snapshot.clips.count) 段录音 · \(durationText(totalDuration))",
            ""
        ]

        for (index, clip) in snapshot.clips.enumerated() {
            lines.append("## \(formatted(clip.createdAt, as: "HH:mm")) · \(durationText(clip.duration))")
            if includeAudioLinks, clip.audioURL != nil {
                lines.append("")
                lines.append("音频：[\(audioFileName(for: clip, index: index))](audio/\(audioFileName(for: clip, index: index)))")
            }
            lines.append("")
            lines.append(clip.transcript.isEmpty ? "_暂无转录内容_" : clip.transcript)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func manifestData(snapshot: DayExportSnapshot) throws -> Data {
        let clips: [[String: Any]] = snapshot.clips.enumerated().map { index, clip in
            [
                "id": clip.id.uuidString,
                "createdAt": ISO8601DateFormatter().string(from: clip.createdAt),
                "duration": clip.duration,
                "transcript": clip.transcript,
                "audioFile": clip.audioURL == nil ? NSNull() : "audio/\(audioFileName(for: clip, index: index))"
            ]
        }
        let object: [String: Any] = [
            "format": "AudioLifeExport",
            "version": 1,
            "date": formatted(snapshot.date, as: "yyyy-MM-dd"),
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "clips": clips
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    nonisolated private static func audioFileName(
        for clip: DayExportSnapshot.Clip,
        index: Int
    ) -> String {
        let sequence = String(format: "%02d", index + 1)
        return "\(formatted(clip.createdAt, as: "HH-mm-ss"))-\(sequence).wav"
    }

    nonisolated private static func convertToWAV(
        sourceURL: URL,
        destinationURL: URL,
        progress: (Double) -> Void
    ) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outputFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: 16_384
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
            progress(Double(inputFile.framePosition) / Double(max(1, inputFile.length)))
        }
        progress(1)
    }

    nonisolated private static func formatted(_ date: Date, as format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    nonisolated private static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

}

private struct DayExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DayExportModifier: ViewModifier {
    let day: JournalDay?
    @Binding var isPresented: Bool

    @State private var exportItem: DayExportItem?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var pendingMode: DayExportMode?
    @StateObject private var progress = DayExportProgressModel()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: beginPendingExport) {
                DayExportOptionsSheet(date: day?.date) { mode in
                    pendingMode = mode
                    isPresented = false
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $exportItem, onDismiss: clearFinishedExport) { item in
                ActivityShareSheet(items: [item.url])
            }
            .alert(
                "导出失败",
                isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                )
            ) {
                Button("好") {}
            } message: {
                Text(exportError ?? "请稍后重试。")
            }
            .overlay {
                if isExporting {
                    VStack(spacing: 10) {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 210)
                        HStack {
                            Text(progress.status)
                            Spacer()
                            Text("\(Int(progress.fraction * 100))%")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 210)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: .rect(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
                }
            }
    }

    private func beginPendingExport() {
        guard let mode = pendingMode else { return }
        pendingMode = nil
        startExport(mode)
    }

    private func clearFinishedExport() {
        try? StorageManager.clearExportCache()
    }

    private func startExport(_ mode: DayExportMode) {
        guard let day else { return }
        let snapshot = DayExportSnapshot(day: day)
        progress.reset()
        isExporting = true
        Task {
            do {
                let url = try await DayExportBuilder.build(
                    snapshot: snapshot,
                    mode: mode,
                    progress: progress
                )
                isExporting = false
                exportItem = DayExportItem(url: url)
            } catch {
                isExporting = false
                exportError = error.localizedDescription
            }
        }
    }
}

private struct DayExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let date: Date?
    let onSelect: (DayExportMode) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    option(
                        title: "文档和音频",
                        detail: "Markdown、JSON 和 WAV，打包为 ZIP",
                        icon: "shippingbox",
                        mode: .documentAndAudio
                    )
                    option(
                        title: "仅导出文档",
                        detail: "Markdown 格式，方便阅读和检索",
                        icon: "doc.text",
                        mode: .documentOnly
                    )
                    option(
                        title: "仅导出音频",
                        detail: "当天全部录音转换为 WAV 并打包",
                        icon: "waveform",
                        mode: .audioOnly
                    )
                } footer: {
                    Text("音频在导出时转换为通用 WAV；App 内仍保留原始安全录音。")
                }
            }
            .navigationTitle("导出\(date?.chineseMonthDayWeekday ?? "这一天")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func option(
        title: String,
        detail: String,
        icon: String,
        mode: DayExportMode
    ) -> some View {
        Button {
            onSelect(mode)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func dayExportDialog(day: JournalDay?, isPresented: Binding<Bool>) -> some View {
        modifier(DayExportModifier(day: day, isPresented: isPresented))
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
