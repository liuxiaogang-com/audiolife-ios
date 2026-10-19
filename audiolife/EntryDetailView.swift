import QuickLook
import SwiftData
import SwiftUI
import UIKit

struct EntryDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var entry: RecordingClip
    @StateObject private var player = AudioPlayerController()
    @State private var showEditor = false
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var exporting = false
    @State private var error: String?
    @State private var confirmTrash = false
    @State private var editingAttachment: EntryAttachment?

    var body: some View {
        List {
            Section {
                Text(entry.displayTitle).font(.title2.bold()).textSelection(.enabled)
                LabeledContent("创建时间", value: entry.createdAt.displayDateTime)
                if let date = entry.day?.date { LabeledContent("日记日期", value: date.displayDate) }
                else { LabeledContent("归属", value: "随手笔记") }
                if !entry.allTags.isEmpty { Text(entry.allTags.map { "#" + $0 }.joined(separator: " ")).foregroundStyle(.tint) }
            }
            if entry.hasAudio {
                Section("录音") {
                    Button { player.toggle(clip: entry) } label: {
                        Label(player.isPlaying ? "暂停" : "播放录音 · " + entry.duration.durationText,
                              systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    }
                    if player.playingClipID == entry.id {
                        ProgressView(value: min(player.currentTime, entry.duration), total: max(entry.duration, 0.1))
                    }
                }
            }
            Section(entry.hasAudio ? "转写正文" : "正文") {
                if entry.transcript.isEmpty { Text("暂无正文").foregroundStyle(.secondary) }
                else { Text(entry.transcript).textSelection(.enabled) }
            }
            if !entry.attachments.isEmpty {
                Section("附件") {
                    ForEach(entry.attachments) { attachment in
                        VStack(alignment: .leading, spacing: 9) {
                            Button {
                                guard let url = EntryFiles.url(for: attachment), FileManager.default.fileExists(atPath: url.path) else {
                                    error = "附件文件不存在，请检查备份。"; return
                                }
                                previewURL = url
                            } label: {
                                HStack {
                                    Image(systemName: attachment.symbol).font(.title3).frame(width: 30)
                                    VStack(alignment: .leading) {
                                        Text(attachment.originalName).lineLimit(2)
                                        Text(attachment.byteCount.storageSizeText).font(.caption).foregroundStyle(.secondary)
                                        if let duration = attachment.duration { Text(duration.durationText).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Image(systemName: "eye").foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                            if ["queued", "running"].contains(attachment.processingState) {
                                HStack { ProgressView().controlSize(.small); Text(attachment.processingState == "queued" ? "等待处理" : (attachment.isImage ? "正在识别图片文字" : "正在转写音频")) }
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("取消处理") { EntryProcessingQueue.shared.cancel(entry, in: context) }.font(.caption)
                            }
                            if attachment.processingState == "failed" {
                                Text(attachment.processingError).font(.caption).foregroundStyle(.orange)
                                Button("重试处理") { EntryProcessingQueue.shared.retry(entry, in: context) }
                            }
                            if attachment.processingState == "cancelled" {
                                Button("已取消 · 重新处理") { EntryProcessingQueue.shared.retry(entry, in: context) }.font(.caption)
                            }
                            if !attachment.extractedText.isEmpty {
                                DisclosureGroup(attachment.isImage ? "图片识别文字" : "音频转写") {
                                    Text(attachment.extractedText).textSelection(.enabled).font(.body)
                                    Button("编辑识别文字") { editingAttachment = attachment }
                                }
                            }
                            if let url = EntryFiles.url(for: attachment) {
                                ShareLink(item: url) { Label("导出原文件", systemImage: "square.and.arrow.up") }.font(.caption)
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }
            if !entry.processingState.isEmpty {
                Section("转写任务") {
                    Text(entry.processingState == "completed" ? "已完成" : entry.processingState == "failed" ? entry.processingError : "正在处理")
                    if entry.processingState == "failed" { Button("重试") { EntryProcessingQueue.shared.retry(entry, in: context) } }
                }
            }
        }
        .navigationTitle("记录详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("编辑内容与归属", systemImage: "square.and.pencil") { showEditor = true }
                    Button("导出整条记录", systemImage: "square.and.arrow.up") { Task { await export() } }.disabled(exporting)
                    Button("移入回收站", systemImage: "trash", role: .destructive) { confirmTrash = true }
                } label: { if exporting { ProgressView() } else { Image(systemName: "ellipsis.circle") } }
            }
        }
        .sheet(isPresented: $showEditor) { EntryComposerView(entry: entry) }
        .sheet(item: $editingAttachment) { attachment in AttachmentTextEditor(entry: entry, attachment: attachment) }
        .quickLookPreview($previewURL)
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { EntryShareSheet(items: [shareURL]) }
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") {}
        } message: { Text(error ?? "") }
        .confirmationDialog("将这条记录移入回收站？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移入回收站", role: .destructive) {
                entry.isTrashed = true; entry.trashedAt = Date()
                do { try context.save(); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
        .onDisappear { player.stop() }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do { shareURL = try await EntryExport.build(entry: entry) }
        catch { self.error = error.localizedDescription }
    }
}

private struct AttachmentTextEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let entry: RecordingClip
    let attachment: EntryAttachment
    @State private var text: String
    @State private var error: String?
    init(entry: RecordingClip, attachment: EntryAttachment) {
        self.entry = entry; self.attachment = attachment
        _text = State(initialValue: attachment.extractedText)
    }
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).padding().navigationTitle("编辑识别文字")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            var items = entry.attachments
                            guard let index = items.firstIndex(where: { $0.id == attachment.id }) else { return }
                            if items[index].originalExtractedText == nil { items[index].originalExtractedText = items[index].extractedText }
                            items[index].extractedText = text
                            items[index].isTextEdited = true
                            entry.attachments = items
                            entry.modifiedAt = Date()
                            do { try context.save(); dismiss() } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("好") {}
                } message: { Text(error ?? "") }
        }
    }
}

struct EntryShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum EntryExport {
    private struct Snapshot: Sendable {
        var id: UUID
        var title: String
        var text: String
        var createdAt: Date
        var diaryDate: Date?
        var tags: [String]
        var audio: URL?
        var attachments: [EntryAttachment]
    }

    @MainActor static func build(entry: RecordingClip) async throws -> URL {
        let snapshot = Snapshot(id: entry.id, title: entry.displayTitle, text: entry.transcript,
                                createdAt: entry.createdAt, diaryDate: entry.day?.date, tags: entry.allTags,
                                audio: AudioRecorderController.fileURL(for: entry.fileName), attachments: entry.attachments)
        return try await Task.detached(priority: .userInitiated) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AudioLifeExports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let folder = root.appendingPathComponent("record", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var text = "# \(snapshot.title)\n\n创建：\(snapshot.createdAt.displayDateTime)\n"
            if let date = snapshot.diaryDate { text += "日记日期：\(date.displayDate)\n" }
            text += "\n\(snapshot.text)\n"
            var manifest: [[String: Any]] = []
            if let audio = snapshot.audio {
                let name = "recording." + audio.pathExtension
                try FileManager.default.copyItem(at: audio, to: folder.appendingPathComponent(name))
                text += "\n[录音](\(name))\n"
            }
            for attachment in snapshot.attachments {
                guard let source = EntryFiles.url(for: attachment) else { throw CocoaError(.fileNoSuchFile) }
                let name = attachment.id.uuidString + "." + source.pathExtension
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
                text += "\n附件：\(attachment.originalName)（\(name)）\n\(attachment.extractedText)\n"
                manifest.append(["id": attachment.id.uuidString, "originalName": attachment.originalName,
                                 "file": name, "sha256": attachment.sha256, "text": attachment.extractedText])
            }
            try Data(text.utf8).write(to: folder.appendingPathComponent("record.md"))
            let info: [String: Any] = ["format": "AudioLifeEntry", "version": 1, "id": snapshot.id.uuidString,
                                      "title": snapshot.title, "text": snapshot.text, "tags": snapshot.tags,
                                      "createdAt": snapshot.createdAt.ISO8601Format(),
                                      "diaryDate": snapshot.diaryDate?.ISO8601Format() as Any? ?? NSNull(), "attachments": manifest]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("manifest.json"))
            let zip = root.appendingPathComponent("AudioLife-\(snapshot.id.uuidString.prefix(8)).zip")
            try ZIPArchiveWriter.createArchive(from: folder, at: zip) { _ in }
            try? FileManager.default.removeItem(at: folder)
            return zip
        }.value
    }
}
