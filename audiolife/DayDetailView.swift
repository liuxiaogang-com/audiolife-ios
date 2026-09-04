import SwiftData
import SwiftUI

struct DayDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var day: JournalDay

    @StateObject private var player = AudioPlayerController()
    @State private var showRecorder = false
    @State private var showExportOptions = false
    @State private var retranscribingClipIDs: Set<UUID> = []
    @State private var aiOrganizingClipIDs: Set<UUID> = []
    @State private var retranscriptionError: String?
    @State private var aiError: String?
    @State private var editingClip: RecordingClip?
    @State private var tagEditingClip: RecordingClip?
    @State private var originalTranscriptClip: RecordingClip?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                HStack {
                    Text("\(day.activeClips.count) 段录音")
                    Spacer()
                    Text(day.totalDuration.durationText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

                if day.activeClips.isEmpty {
                    ContentUnavailableView(
                        "今天还没有片段",
                        systemImage: "mic",
                        description: Text("点击右下角按钮开始记录。")
                    )
                    .frame(minHeight: 320)
                } else {
                    ForEach(day.sortedClips) { clip in
                        RecordingCard(
                            clip: clip,
                            isSelected: player.playingClipID == clip.id,
                            isPlaying: player.playingClipID == clip.id && player.isPlaying,
                            playbackTime: player.playingClipID == clip.id ? player.currentTime : 0,
                            isRetranscribing: retranscribingClipIDs.contains(clip.id),
                            isAIOrganizing: aiOrganizingClipIDs.contains(clip.id),
                            playAction: { player.toggle(clip: clip) },
                            seekAction: { player.seek(clip: clip, to: $0) },
                            retranscribeAction: { retranscribe(clip) },
                            organizeAction: { organizeWithAI(clip) },
                            editTranscriptAction: { editingClip = clip },
                            editTagsAction: { tagEditingClip = clip },
                            viewOriginalAction: { originalTranscriptClip = clip },
                            deleteAction: { delete(clip) }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(day.date.chineseMonthDayWeekday)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExportOptions = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出这一天")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    showRecorder = true
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .accessibilityLabel("继续录制这一天")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $showRecorder) {
            RecordingSheet(day: day)
        }
        .sheet(item: $editingClip) { clip in
            TranscriptEditorSheet(clip: clip)
        }
        .sheet(item: $tagEditingClip) { clip in
            ManualTagEditorSheet(clip: clip)
        }
        .sheet(item: $originalTranscriptClip) { clip in
            OriginalTranscriptSheet(clip: clip)
        }
        .dayExportDialog(day: day, isPresented: $showExportOptions)
        .alert(
            "重新转写失败",
            isPresented: Binding(
                get: { retranscriptionError != nil },
                set: { if !$0 { retranscriptionError = nil } }
            )
        ) {
            Button("好") {}
        } message: {
            Text(retranscriptionError ?? "请稍后重试。")
        }
        .alert(
            "AI 整理失败",
            isPresented: Binding(
                get: { aiError != nil },
                set: { if !$0 { aiError = nil } }
            )
        ) {
            Button("好") {}
        } message: {
            Text(aiError ?? "请检查设置中的接口配置。")
        }
        .onDisappear {
            player.stop()
        }
    }

    private func delete(_ clip: RecordingClip) {
        player.stop()
        clip.isTrashed = true
        clip.trashedAt = Date()
        try? modelContext.save()
    }

    private func retranscribe(_ clip: RecordingClip) {
        guard !retranscribingClipIDs.contains(clip.id) else { return }
        guard let audioURL = AudioRecorderController.fileURL(for: clip.fileName) else {
            retranscriptionError = "找不到对应的原始录音文件。"
            return
        }

        player.stop()
        retranscribingClipIDs.insert(clip.id)
        Task {
            defer { retranscribingClipIDs.remove(clip.id) }
            do {
                let output = try await ModernSpeechService.shared.transcribeDetailed(
                    audioURL: audioURL
                )
                clip.rawTranscript = output.text
                clip.transcriptSegments = output.segments
                if !clip.isTranscriptEdited {
                    clip.transcript = output.text
                }
                try Data(output.text.utf8).write(
                    to: AudioRecorderController.transcriptCheckpointURL(for: audioURL),
                    options: .atomic
                )
                try modelContext.save()
                DiagnosticLogger.log("manual retranscription saved file=\(clip.fileName)")
            } catch {
                retranscriptionError = error.localizedDescription
                DiagnosticLogger.log(
                    "manual retranscription failed file=\(clip.fileName) "
                    + "message=\(error.localizedDescription)"
                )
            }
        }
    }

    private func organizeWithAI(_ clip: RecordingClip) {
        guard !aiOrganizingClipIDs.contains(clip.id) else { return }
        let configuration = AITextConfiguration.current()
        guard configuration.isReady else {
            aiError = "请先在“设置 → AI 文本理解”中启用并填写接口地址、API Key 和模型。"
            return
        }

        aiOrganizingClipIDs.insert(clip.id)
        Task {
            defer { aiOrganizingClipIDs.remove(clip.id) }
            do {
                try await AITextOrganizer.organize(
                    clip: clip,
                    configuration: configuration
                )
                DiagnosticLogger.log("manual AI text analysis saved file=\(clip.fileName)")
            } catch {
                clip.aiLastError = error.localizedDescription
                try? modelContext.save()
                aiError = error.localizedDescription
                DiagnosticLogger.log(
                    "manual AI text analysis failed file=\(clip.fileName) "
                    + "message=\(error.localizedDescription)"
                )
            }
        }
    }
}

private struct RecordingCard: View {
    let clip: RecordingClip
    let isSelected: Bool
    let isPlaying: Bool
    let playbackTime: TimeInterval
    let isRetranscribing: Bool
    let isAIOrganizing: Bool
    let playAction: () -> Void
    let seekAction: (TimeInterval) -> Void
    let retranscribeAction: () -> Void
    let organizeAction: () -> Void
    let editTranscriptAction: () -> Void
    let editTagsAction: () -> Void
    let viewOriginalAction: () -> Void
    let deleteAction: () -> Void

    @State private var transcriptExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Button(action: playAction) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.tint, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "暂停" : "播放")

                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.createdAt.chineseTime)
                        .font(.subheadline.weight(.medium))
                    if !isSelected {
                        Text(clip.duration.durationText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Text(isPlaying ? "播放中" : "已暂停")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Menu {
                    Button(action: editTranscriptAction) {
                        Label("编辑转写", systemImage: "square.and.pencil")
                    }

                    Button(action: editTagsAction) {
                        Label("编辑标签", systemImage: "tag")
                    }

                    Button(action: viewOriginalAction) {
                        Label("查看原始转写", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(clip.rawTranscript.isEmpty)

                    Button(action: retranscribeAction) {
                        Label("重新转写", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                    .disabled(isRetranscribing)

                    Button(action: organizeAction) {
                        Label(
                            clip.aiAnalyzedAt == nil ? "AI 整理" : "重新 AI 整理",
                            systemImage: "sparkles"
                        )
                    }
                    .disabled(isAIOrganizing || clip.transcript.isEmpty)

                    Button(role: .destructive, action: deleteAction) {
                        Label("删除录音", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 32)
                }
            }

            if isRetranscribing {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在使用新版模型重新转写…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            if isAIOrganizing {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在生成标题、摘要和标签…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            if isSelected {
                VStack(spacing: 5) {
                    ProgressView(
                        value: min(playbackTime, clip.duration),
                        total: max(clip.duration, 0.1)
                    )
                    .tint(.accentColor)

                    HStack {
                        Text(playbackTime.durationText)
                        Spacer()
                        Text(clip.duration.durationText)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 43)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !clip.aiTitle.isEmpty || !clip.aiSummary.isEmpty || !clip.allTags.isEmpty {
                AITextInsightView(clip: clip)
            }

            Button {
                withAnimation(.snappy) {
                    transcriptExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(clip.transcript.isEmpty ? "暂无转录" : "转录内容")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: transcriptExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if transcriptExpanded {
                if isSelected && !clip.transcriptSegments.isEmpty {
                    TimedTranscriptView(
                        segments: clip.transcriptSegments,
                        playbackTime: playbackTime,
                        seekAction: seekAction
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text(clip.transcript.isEmpty ? "等待转录内容…" : clip.transcript)
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(clip.transcript.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .animation(.snappy, value: isSelected)
        .animation(.snappy, value: isRetranscribing)
        .animation(.snappy, value: isAIOrganizing)
    }
}

private struct AITextInsightView: View {
    let clip: RecordingClip
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !clip.aiSummary.isEmpty {
                    Text(clip.aiSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }

                if !clip.allTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(clip.allTags.prefix(4)), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        if clip.allTags.count > 4 {
                            Text("+\(clip.allTags.count - 4)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(clip.aiTitle.isEmpty ? "整理结果" : clip.aiTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .tint(.secondary)
    }
}

private struct ManualTagEditorSheet: View {
    private struct TagDraft: Identifiable {
        let id = UUID()
        var text: String
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var clip: RecordingClip
    @State private var drafts: [TagDraft]
    @State private var newTag = ""

    init(clip: RecordingClip) {
        self.clip = clip
        _drafts = State(initialValue: clip.manualTags.map(TagDraft.init(text:)))
    }

    var body: some View {
        NavigationStack {
            Form {
                if !clip.aiTags.isEmpty {
                    Section {
                        ForEach(clip.aiTags, id: \.self) { tag in
                            Label(tag, systemImage: "sparkles")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("AI 标签")
                    } footer: {
                        Text("AI 标签会在重新整理时更新；手动标签会独立保留。")
                    }
                }

                Section {
                    ForEach($drafts) { $draft in
                        HStack {
                            TextField("标签", text: $draft.text)
                                .textInputAutocapitalization(.never)
                            Button(role: .destructive) {
                                drafts.removeAll { $0.id == draft.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("添加标签", text: $newTag)
                            .submitLabel(.done)
                            .onSubmit(addTags)
                        Button("添加", action: addTags)
                            .disabled(normalized(newTag).isEmpty)
                    }
                } header: {
                    Text("手动标签")
                } footer: {
                    Text("可以添加、修改或删除手动标签。多个标签可用逗号分隔。")
                }
            }
            .navigationTitle("编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        addTags()
                        clip.manualTags = uniqueTags(drafts.map(\.text))
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addTags() {
        let candidates = newTag.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
        for tag in uniqueTags(candidates) where !contains(tag) {
            drafts.append(TagDraft(text: tag))
        }
        newTag = ""
    }

    private func contains(_ tag: String) -> Bool {
        let key = normalized(tag).lowercased()
        return drafts.contains { normalized($0.text).lowercased() == key }
    }

    private func uniqueTags(_ source: [String]) -> [String] {
        var seen = Set<String>()
        return source.compactMap { raw in
            let tag = normalized(raw)
            guard !tag.isEmpty else { return nil }
            let key = tag.lowercased()
            return seen.insert(key).inserted ? tag : nil
        }
    }

    private func normalized(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }
}

private struct TimedTranscriptView: View {
    let segments: [TranscriptSegment]
    let playbackTime: TimeInterval
    let seekAction: (TimeInterval) -> Void

    private var activeSegmentID: UUID? {
        segments.last(where: { segment in
            playbackTime >= segment.startTime - 0.12
                && playbackTime <= segment.endTime + 0.22
        })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        Button {
                            seekAction(segment.startTime)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text(segment.startTime.durationText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .leading)
                                Text(segment.text)
                                    .font(.body)
                                    .lineSpacing(3)
                                    .foregroundStyle(
                                        activeSegmentID == segment.id
                                            ? Color.primary
                                            : Color.secondary
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                activeSegmentID == segment.id
                                    ? Color.accentColor.opacity(0.13)
                                    : Color.clear,
                                in: .rect(cornerRadius: 9)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(segment.id)
                    }
                }
            }
            .frame(maxHeight: 190)
            .onChange(of: activeSegmentID) { _, id in
                guard let id else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct TranscriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var clip: RecordingClip
    @State private var text: String

    init(clip: RecordingClip) {
        self.clip = clip
        _text = State(initialValue: clip.transcript)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .lineSpacing(4)
                .padding(12)
                .navigationTitle("编辑转写")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if clip.rawTranscript.isEmpty {
                                clip.rawTranscript = clip.transcript
                            }
                            clip.transcript = text.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            clip.isTranscriptEdited = clip.transcript != clip.rawTranscript
                            try? modelContext.save()
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct OriginalTranscriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var clip: RecordingClip

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("语音识别原始结果")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(clip.rawTranscript.isEmpty ? "暂无原始转写" : clip.rawTranscript)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .navigationTitle("原始转写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("恢复为原文") {
                        clip.transcript = clip.rawTranscript
                        clip.isTranscriptEdited = false
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(clip.rawTranscript.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension TimeInterval {
    var durationText: String {
        let seconds = max(0, Int(self.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
