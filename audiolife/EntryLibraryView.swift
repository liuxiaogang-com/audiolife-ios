import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppRouter.self) private var router
    @State private var selection = "notes"

    var body: some View {
        TabView(selection: $selection) {
            EntryLibraryView().tabItem { Label("笔记", systemImage: "note.text") }.tag("notes")
            DiaryHomeView().tabItem { Label("日记", systemImage: "calendar") }.tag("diary")
            NavigationStack {
                ContentUnavailableView("正在开发", systemImage: "sparkles", description: Text("AI 搜索与历史内容问答正在开发。"))
                    .navigationTitle("AI")
            }.tabItem { Label("AI", systemImage: "sparkles") }.tag("ai")
            TodoListView().tabItem { Label("待办", systemImage: "checklist") }.tag("todo")
        }
        .onChange(of: router.quickRecordingRequest) { _, _ in selection = "diary" }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { EntryProcessingQueue.shared.resume(in: context) }
        }
        .task {
#if DEBUG
            if ProcessInfo.processInfo.environment["AUDIOLIFE_VALIDATE"] == "1" {
                await LibraryValidation.run()
                return
            }
            if let requested = ProcessInfo.processInfo.environment["AUDIOLIFE_SCREEN"] { selection = requested == "composer" ? "notes" : requested }
#endif
            RecordingRecovery.recover(in: context)
            EntryProcessingQueue.shared.resume(in: context)
            if router.shouldPresentQuickRecorder { selection = "diary" }
        }
    }
}

struct EntryLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecordingClip.createdAt, order: .reverse) private var entries: [RecordingClip]
    @State private var query = ""
    @State private var scope = "notes"
    @State private var selectedTag = ""
    @State private var showComposer = false
    @State private var showAudioImporter = false
    @State private var showSettings = false
    @State private var showTrash = false
    @State private var importing = false
    @State private var error: String?

    private var tags: [String] {
        Array(Set(entries.filter { !$0.isEffectivelyTrashed }.flatMap(\.allTags))).sorted()
    }
    private var visible: [RecordingClip] {
        entries.filter {
            !$0.isEffectivelyTrashed && (scope == "all" || $0.day == nil)
                && (selectedTag.isEmpty || $0.allTags.contains(selectedTag))
                && (query.isEmpty || $0.searchableText.localizedStandardContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("范围", selection: $scope) {
                        Text("随手笔记").tag("notes")
                        Text("全部记录").tag("all")
                    }.pickerStyle(.segmented)
                    if !tags.isEmpty {
                        Picker("标签", selection: $selectedTag) {
                            Text("全部标签").tag("")
                            ForEach(tags, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                if importing { HStack { ProgressView(); Text("正在导入音频…") } }
                if visible.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "随手记点什么" : "没有找到相关内容",
                        systemImage: "note.text", description: Text(query.isEmpty ? "文字、照片、音频和文件，都可以放在这里。" : "可以搜索正文、标签、附件名称和已识别文字。"))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(visible) { entry in
                        NavigationLink { EntryDetailView(entry: entry) } label: { EntrySummaryRow(entry: entry) }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("删除", role: .destructive) {
                                    entry.isTrashed = true; entry.trashedAt = Date()
                                    do { try context.save() } catch { self.error = error.localizedDescription }
                                }
                            }
                    }
                }
            }
            .navigationTitle("笔记")
            .searchable(text: $query, prompt: "搜索正文、标签、附件和识别文字")
            .onChange(of: tags) { _, available in
                if !selectedTag.isEmpty, !available.contains(selectedTag) { selectedTag = "" }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showComposer = true } label: { Label("写文字 / 添加附件", systemImage: "square.and.pencil") }
                        Button { showAudioImporter = true } label: { Label("导入音频并转写", systemImage: "waveform.badge.plus") }
                    } label: { Image(systemName: "plus") }.disabled(importing)
                    .accessibilityLabel("新建记录").accessibilityIdentifier("entry.new")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("回收站", systemImage: "trash") { showTrash = true }
                        Button("设置与存储", systemImage: "gearshape") { showSettings = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showComposer) { EntryComposerView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showTrash) { TrashView() }
            .task {
#if DEBUG
                if ProcessInfo.processInfo.environment["AUDIOLIFE_SCREEN"] == "composer" { showComposer = true }
#endif
            }
            .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await importAudio(urls) }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") {}
            } message: { Text(error ?? "") }
        }
    }

    private func importAudio(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        for url in urls {
            do {
                let attachment = try await EntryFiles.importFile(url)
                let entry = RecordingClip(duration: 0, fileName: "")
                entry.manualTitle = url.deletingPathExtension().lastPathComponent
                entry.attachments = [attachment]
                context.insert(entry)
                do { try context.save() }
                catch { context.delete(entry); EntryFiles.remove(attachment); throw error }
            } catch { self.error = "\(url.lastPathComponent)：\(error.localizedDescription)" }
        }
        EntryProcessingQueue.shared.resume(in: context)
    }
}

struct EntrySummaryRow: View {
    let entry: RecordingClip
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.displayTitle).font(.headline).lineLimit(2)
            if !entry.transcript.isEmpty { Text(entry.transcript).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            HStack(spacing: 10) {
                Text(entry.createdAt.displayCompactDateTime)
                if entry.hasAudio { Label(entry.duration.durationText, systemImage: "waveform") }
                if !entry.attachments.isEmpty { Label("\(entry.attachments.count)", systemImage: "paperclip") }
                if let date = entry.day?.date { Text(date.displayMonthDay).foregroundStyle(.tint) }
            }.font(.caption).foregroundStyle(.secondary)
            if entry.attachments.contains(where: { ["queued", "running"].contains($0.processingState) }) {
                Label("附件处理中", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }
            if !entry.allTags.isEmpty { Text(entry.allTags.map { "#" + $0 }.joined(separator: " ")).font(.caption).foregroundStyle(.tint).lineLimit(1) }
        }.padding(.vertical, 5)
    }
}
