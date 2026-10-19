import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct EntryDraft: Codable, Equatable {
    var title = ""
    var text = ""
    var tags = ""
    var isDiary = false
    var date = Date()
    var attachments: [EntryAttachment] = []
}

enum EntryDraftStore {
    static func url(key: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EntryDrafts", isDirectory: true).appendingPathComponent(key + ".json")
    }
    static func load(key: String) -> EntryDraft? {
        guard let data = try? Data(contentsOf: url(key: key)) else { return nil }
        return try? JSONDecoder().decode(EntryDraft.self, from: data)
    }
    static func save(_ draft: EntryDraft, key: String) throws {
        let target = url(key: key)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    static func clear(key: String) { try? FileManager.default.removeItem(at: url(key: key)) }
}

struct EntryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let entry: RecordingClip?
    let initialDay: JournalDay?
    @State private var draft = EntryDraft()
    @State private var loaded = false
    @State private var restoredDraft = false
    @State private var importing = false
    @State private var showFiles = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var error: String?
    @State private var saved = false
    @State private var showDiscard = false

    init(entry: RecordingClip? = nil, initialDay: JournalDay? = nil) {
        self.entry = entry
        self.initialDay = initialDay
    }

    private var draftKey: String { entry?.id.uuidString ?? initialDay.map { "diary-" + $0.id.uuidString } ?? "new-note" }
    private var canSave: Bool {
        !importing && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty || entry?.hasAudio == true)
    }

    var body: some View {
        NavigationStack {
            Form {
                if restoredDraft { Text("已恢复上次未保存的草稿").font(.caption).foregroundStyle(.secondary) }
                Section {
                    TextField("标题（可选）", text: $draft.title)
                        .accessibilityIdentifier("entry.title")
                    TextEditor(text: $draft.text)
                        .frame(minHeight: 190)
                        .accessibilityLabel("正文")
                        .accessibilityIdentifier("entry.body")
                    if draft.text.isEmpty { Text("写下想法、日常或一段文字…").font(.caption).foregroundStyle(.secondary) }
                }
                Section("归属") {
                    Toggle("放入日记", isOn: $draft.isDiary)
                    if draft.isDiary { DatePicker("日记日期", selection: $draft.date, displayedComponents: .date) }
                    Text(draft.isDiary ? "按选择的日期归入日记，创建时间仍单独保留。" : "作为随手笔记保存，不归入某一天。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("标签，用逗号分隔", text: $draft.tags)
                }
                Section("附件") {
                    ForEach(draft.attachments) { attachment in
                        HStack {
                            Image(systemName: attachment.symbol)
                            VStack(alignment: .leading) {
                                Text(attachment.originalName).lineLimit(1)
                                Text(attachment.byteCount.storageSizeText).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { remove(attachment) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("移除附件 " + attachment.originalName)
                        }
                    }
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                        Label("添加照片或视频", systemImage: "photo.on.rectangle")
                    }.disabled(importing)
                    Button { showFiles = true } label: { Label("添加文件或音频", systemImage: "paperclip") }
                        .disabled(importing)
                    if importing { HStack { ProgressView(); Text("正在保存附件，请稍候…") } }
                    Text("文件保存到 App 内；图片会识别文字，音频会排队转写。视频保留原文件供预览和导出。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if entry == nil {
                    Section {
                        Text("关闭页面会保留草稿。附件也随草稿保存在本机。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("丢弃草稿", role: .destructive) { showDiscard = true }
                    }
                }
            }
            .navigationTitle(entry == nil ? "新建记录" : "编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(entry == nil ? "暂存" : "取消") { dismiss() }.disabled(importing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(!canSave).accessibilityIdentifier("entry.save")
                }
            }
            .interactiveDismissDisabled(importing)
            .task { load() }
            .onChange(of: draft) { _, value in
                guard loaded, !saved else { return }
                do { try EntryDraftStore.save(value, key: draftKey) }
                catch { self.error = "草稿暂存失败：\(error.localizedDescription)" }
            }
            .onChange(of: selectedPhotos) { _, items in Task { await importPhotos(items) } }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await importFiles(urls) }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") {}
            } message: { Text(error ?? "") }
            .confirmationDialog("丢弃这份草稿及其附件？", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("丢弃草稿", role: .destructive) {
                    for attachment in draft.attachments { EntryFiles.remove(attachment) }
                    EntryDraftStore.clear(key: draftKey)
                    saved = true
                    dismiss()
                }
            }
            .onDisappear {
                if entry == nil, loaded, !saved {
                    do { try EntryDraftStore.save(draft, key: draftKey) }
                    catch { DiagnosticLogger.log("Draft persistence failed: \(error.localizedDescription)") }
                }
                // Editing never mutates the persisted entry until Save.
                if entry != nil, !saved {
                    let originalIDs = Set(entry?.attachments.map(\.id) ?? [])
                    for attachment in draft.attachments where !originalIDs.contains(attachment.id) { EntryFiles.remove(attachment) }
                    EntryDraftStore.clear(key: draftKey)
                }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        if let existing = EntryDraftStore.load(key: draftKey) {
            draft = existing
            restoredDraft = true
        } else if let entry {
            draft = EntryDraft(title: entry.manualTitle, text: entry.transcript,
                               tags: entry.manualTags.joined(separator: ", "),
                               isDiary: entry.day != nil, date: entry.day?.date ?? Date(), attachments: entry.attachments)
        } else if let initialDay {
            draft.isDiary = true
            draft.date = initialDay.date
        }
        loaded = true
    }

    private func remove(_ attachment: EntryAttachment) {
        draft.attachments.removeAll { $0.id == attachment.id }
        if entry?.attachments.contains(where: { $0.id == attachment.id }) != true { EntryFiles.remove(attachment) }
    }

    private func append(_ attachment: EntryAttachment) {
        if draft.attachments.contains(where: { $0.sha256 == attachment.sha256 }) {
            EntryFiles.remove(attachment)
            error = "这份附件已在当前记录中，已跳过重复文件。"
        } else { draft.attachments.append(attachment) }
    }

    private func importFiles(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        for url in urls {
            do { append(try await EntryFiles.importFile(url)) }
            catch { self.error = "\(url.lastPathComponent)：\(error.localizedDescription)" }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        importing = true
        defer { importing = false; selectedPhotos = [] }
        for item in items {
            do {
                guard let file = try await item.loadTransferable(type: PhotoImportFile.self) else {
                    throw CocoaError(.fileReadUnknown)
                }
                defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
                append(try await EntryFiles.importFile(file.url))
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        let record = entry ?? RecordingClip(duration: 0, fileName: "")
        let previousAttachments = record.attachments
        record.manualTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.transcript = draft.text
        if entry == nil { record.rawTranscript = draft.text }
        else if record.hasAudio { record.isTranscriptEdited = true }
        record.manualTags = draft.tags.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // Processing can finish while this editor is open. Keep the latest OCR,
        // transcription and task state for existing attachments when saving text.
        record.attachments = draft.attachments.map { attachment in
            previousAttachments.first(where: { $0.id == attachment.id }) ?? attachment
        }
        record.modifiedAt = Date()
        if entry == nil { context.insert(record) }
        do {
            if draft.isDiary { record.day = try EntryLibrary.day(for: draft.date, in: context) }
            else { record.day = nil }
            try context.save()
            for attachment in previousAttachments where !draft.attachments.contains(where: { $0.id == attachment.id }) {
                EntryFiles.remove(attachment)
            }
            saved = true
            EntryDraftStore.clear(key: draftKey)
            EntryProcessingQueue.shared.resume(in: context)
            dismiss()
        } catch {
            context.rollback()
            self.error = "保存失败，草稿已保留：\(error.localizedDescription)"
        }
    }
}

private struct PhotoImportFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try copy(received.file) }
        FileRepresentation(importedContentType: .image) { received in try copy(received.file) }
    }
    private static func copy(_ source: URL) throws -> PhotoImportFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return PhotoImportFile(url: url)
    }
}

@MainActor enum EntryLibrary {
    static func day(for date: Date, in context: ModelContext) throws -> JournalDay {
        let days = try context.fetch(FetchDescriptor<JournalDay>())
        if let day = days.first(where: { !$0.isTrashed && Calendar.current.isDate($0.date, inSameDayAs: date) }) { return day }
        let day = JournalDay(date: date)
        context.insert(day)
        return day
    }
}
