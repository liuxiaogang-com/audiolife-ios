import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RecordingClip.createdAt, order: .reverse) private var clips: [RecordingClip]

    @State private var snapshot = StorageSnapshot()
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var modelInfo: ModernSpeechModelInfo?
    @State private var isModelDownloading = false
    @State private var modelDownloadProgress = 0.0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AITextSettingsView()
                    } label: {
                        Label("AI 文本理解", systemImage: "sparkles")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: modelStatusIcon)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(modelStatusTint)
                                .frame(width: 30, height: 30)
                                .background(
                                    modelStatusTint.opacity(0.12),
                                    in: .rect(cornerRadius: 9)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("iOS 26 中文语音模型")
                                    .font(.body.weight(.medium))
                                Text(modelStatusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if shouldShowModelDownloadButton {
                                Button("下载") { downloadSpeechModel() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else if modelInfo == nil {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if isModelDownloading {
                            VStack(spacing: 5) {
                                ProgressView(value: modelDownloadProgress)
                                HStack {
                                    Text("正在下载系统语音模型…")
                                    Spacer()
                                    Text("\(Int(modelDownloadProgress * 100))%")
                                        .monospacedDigit()
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("智能功能")
                } footer: {
                    Text("语音识别使用 iOS 本地模型；AI 文本理解需要单独配置接口。")
                }

                Section {
                    LabeledContent("已使用空间") {
                        HStack(spacing: 8) {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(snapshot.totalBytes.storageSizeText)
                                .foregroundStyle(.secondary)
                        }
                    }

                    DisclosureGroup("空间明细") {
                        StorageCategoryRow(
                            title: "录音",
                            icon: "waveform",
                            tint: .blue,
                            bytes: snapshot.activeRecordingBytes
                        )
                        StorageCategoryRow(
                            title: "回收站",
                            icon: "trash",
                            tint: .orange,
                            bytes: snapshot.trashBytes
                        )
                        StorageCategoryRow(
                            title: "数据库",
                            icon: "cylinder",
                            tint: .green,
                            bytes: snapshot.databaseBytes
                        )
                    }

                    NavigationLink {
                        StorageFilesView()
                    } label: {
                        Label("管理录音文件", systemImage: "externaldrive")
                    }
                } header: {
                    Text("存储")
                } footer: {
                    Text("删除的录音会先进入回收站。")
                }

                Section("维护") {
                    cleanupRow(
                        title: "导出缓存",
                        detail: snapshot.exportCacheBytes.storageSizeText,
                        icon: "archivebox",
                        disabled: snapshot.exportCacheBytes == 0
                    ) {
                        clearExportCache()
                    }

                    cleanupRow(
                        title: "诊断日志",
                        detail: snapshot.diagnosticLogBytes.storageSizeText,
                        icon: "doc.text.magnifyingglass",
                        disabled: snapshot.diagnosticLogBytes == 0
                    ) {
                        clearDiagnosticLog()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { refresh() }
            .refreshable { await refreshAndWait() }
            .alert(
                "操作失败",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好") {}
            } message: {
                Text(errorMessage ?? "请稍后重试。")
            }
        }
    }

    private func cleanupRow(
        title: String,
        detail: String,
        icon: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
            Spacer()
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("清除", action: action)
                .buttonStyle(.borderless)
                .disabled(disabled)
        }
    }

    private func refresh() {
        let descriptors = makeDescriptors()
        isLoading = true
        Task {
            async let storage = StorageManager.scan(descriptors)
            async let speechModel = ModernSpeechService.shared.modelInfo()
            snapshot = await storage
            modelInfo = await speechModel
            isLoading = false
        }
    }

    private func refreshAndWait() async {
        let descriptors = makeDescriptors()
        isLoading = true
        async let storage = StorageManager.scan(descriptors)
        async let speechModel = ModernSpeechService.shared.modelInfo()
        snapshot = await storage
        modelInfo = await speechModel
        isLoading = false
    }

    private func makeDescriptors() -> [StorageClipDescriptor] {
        clips.map { clip in
            StorageClipDescriptor(
                id: clip.id,
                createdAt: clip.createdAt,
                duration: clip.duration,
                fileName: clip.fileName,
                isTrashed: clip.isTrashed,
                audioURL: AudioRecorderController.fileURL(for: clip.fileName)
            )
        }
    }

    private func clearExportCache() {
        do {
            try StorageManager.clearExportCache()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearDiagnosticLog() {
        do {
            try StorageManager.clearDiagnosticLog()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var shouldShowModelDownloadButton: Bool {
        guard !isModelDownloading, let modelInfo else { return false }
        if case .notInstalled = modelInfo.state { return true }
        return false
    }

    private var modelStatusText: String {
        if isModelDownloading { return "正在下载" }
        guard let modelInfo else { return "正在检查…" }
        switch modelInfo.state {
        case .installed:
            return "已下载，可以使用新版实时识别"
        case .notInstalled:
            return "尚未下载"
        case .unsupported:
            return "当前系统暂不支持中文模型"
        case .unavailable:
            return "当前设备不支持新版模型"
        }
    }

    private var modelStatusIcon: String {
        if isModelDownloading { return "arrow.down.circle" }
        guard let modelInfo else { return "ellipsis.circle" }
        switch modelInfo.state {
        case .installed: return "checkmark.circle.fill"
        case .notInstalled: return "arrow.down.circle"
        case .unsupported, .unavailable: return "exclamationmark.triangle"
        }
    }

    private var modelStatusTint: Color {
        if isModelDownloading { return .blue }
        guard let modelInfo else { return .secondary }
        switch modelInfo.state {
        case .installed: return .green
        case .notInstalled: return .blue
        case .unsupported, .unavailable: return .orange
        }
    }

    private func downloadSpeechModel() {
        guard !isModelDownloading else { return }
        isModelDownloading = true
        modelDownloadProgress = 0

        Task {
            let pollingTask = Task { @MainActor in
                while !Task.isCancelled {
                    if let fraction = await ModernSpeechService.shared.downloadFraction() {
                        modelDownloadProgress = fraction
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            do {
                _ = try await ModernSpeechService.shared.prepare()
                modelDownloadProgress = 1
                modelInfo = await ModernSpeechService.shared.modelInfo()
            } catch {
                errorMessage = error.localizedDescription
                modelInfo = await ModernSpeechService.shared.modelInfo()
            }
            pollingTask.cancel()
            isModelDownloading = false
        }
    }
}

private struct StorageCategoryRow: View {
    let title: String
    let icon: String
    let tint: Color
    let bytes: Int64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
            Text(title)
            Spacer()
            Text(bytes.storageSizeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StorageFilesView: View {
    private enum SortMode: String, CaseIterable {
        case size = "按大小"
        case date = "按日期"
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingClip.createdAt, order: .reverse) private var clips: [RecordingClip]

    @State private var usages: [StorageClipUsage] = []
    @State private var isLoading = true
    @State private var sortMode: SortMode = .size
    @State private var pendingPermanentDeleteID: UUID?

    private var sortedUsages: [StorageClipUsage] {
        switch sortMode {
        case .size:
            usages.sorted { $0.bytes == $1.bytes ? $0.createdAt > $1.createdAt : $0.bytes > $1.bytes }
        case .date:
            usages.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        List {
            if isLoading && usages.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在计算文件大小…")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if sortedUsages.isEmpty {
                ContentUnavailableView("没有录音文件", systemImage: "waveform")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(sortedUsages) { usage in
                        StorageFileRow(usage: usage)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if usage.isTrashed {
                                    Button(role: .destructive) {
                                        pendingPermanentDeleteID = usage.id
                                    } label: {
                                        Label("彻底删除", systemImage: "trash.slash")
                                    }
                                } else {
                                    Button(role: .destructive) {
                                        moveToTrash(id: usage.id)
                                    } label: {
                                        Label("移到回收站", systemImage: "trash")
                                    }
                                }
                            }
                    }
                } header: {
                    Text("\(usages.count) 个文件 · \(usages.reduce(0) { $0 + $1.bytes }.storageSizeText)")
                }
            }
        }
        .navigationTitle("录音文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $sortMode) {
                        ForEach(SortMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("排序")
            }
        }
        .onAppear { refresh() }
        .refreshable { await refreshAndWait() }
        .alert("彻底删除这段录音？", isPresented: permanentDeleteBinding) {
            Button("取消", role: .cancel) { pendingPermanentDeleteID = nil }
            Button("彻底删除", role: .destructive) {
                permanentlyDeletePendingClip()
            }
        } message: {
            Text("录音文件和转录内容删除后无法恢复。")
        }
    }

    private var permanentDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingPermanentDeleteID != nil },
            set: { if !$0 { pendingPermanentDeleteID = nil } }
        )
    }

    private func refresh() {
        let descriptors = makeDescriptors()
        isLoading = true
        Task {
            usages = await StorageManager.scan(descriptors).clips
            isLoading = false
        }
    }

    private func refreshAndWait() async {
        let descriptors = makeDescriptors()
        isLoading = true
        usages = await StorageManager.scan(descriptors).clips
        isLoading = false
    }

    private func makeDescriptors() -> [StorageClipDescriptor] {
        clips.map { clip in
            StorageClipDescriptor(
                id: clip.id,
                createdAt: clip.createdAt,
                duration: clip.duration,
                fileName: clip.fileName,
                isTrashed: clip.isTrashed,
                audioURL: AudioRecorderController.fileURL(for: clip.fileName)
            )
        }
    }

    private func moveToTrash(id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        clip.isTrashed = true
        clip.trashedAt = Date()
        try? modelContext.save()
        refresh()
    }

    private func permanentlyDeletePendingClip() {
        guard let id = pendingPermanentDeleteID,
              let clip = clips.first(where: { $0.id == id }),
              clip.isTrashed else { return }
        pendingPermanentDeleteID = nil
        let day = clip.day
        let shouldDeleteDay = day?.clips.allSatisfy { $0.id == clip.id } == true
        AudioRecorderController.removeRecordingFiles(for: clip.fileName)
        modelContext.delete(clip)
        if shouldDeleteDay, let day {
            modelContext.delete(day)
        }
        try? modelContext.save()
        refresh()
    }
}

private struct StorageFileRow: View {
    let usage: StorageClipUsage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: usage.isTrashed ? "trash" : "waveform")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(usage.isTrashed ? .orange : .blue)
                .frame(width: 34, height: 34)
                .background(
                    (usage.isTrashed ? Color.orange : Color.blue).opacity(0.12),
                    in: .circle
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(usage.createdAt.chineseMonthDayWeekday)
                        .font(.subheadline.weight(.semibold))
                    Text(usage.createdAt.chineseTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(usage.duration.durationText) · \(URL(fileURLWithPath: usage.fileName).lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(usage.bytes.storageSizeText)
                    .font(.subheadline.monospacedDigit())
                if usage.isTrashed {
                    Text("回收站")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
