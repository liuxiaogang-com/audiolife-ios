import SwiftData
import SwiftUI

struct TrashView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \JournalDay.date, order: .reverse) private var days: [JournalDay]

    @State private var path: [UUID] = []

    private var trashedDays: [JournalDay] {
        days.filter { $0.isTrashed || !$0.trashedClips.isEmpty }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if trashedDays.isEmpty {
                    ContentUnavailableView(
                        "回收站是空的",
                        systemImage: "trash",
                        description: Text("删除的日期和录音会一直保留在这里。")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(trashedDays) { day in
                        Button {
                            path.append(day.id)
                        } label: {
                            TrashDayRow(day: day)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(
                            EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let day = days.first(where: { $0.id == id }) {
                    TrashDayDetailView(day: day)
                }
            }
        }
    }
}

private struct TrashDayRow: View {
    let day: JournalDay

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(day.date.chineseDay)
                    .font(.title2.weight(.bold))
                Text(day.date.chineseMonth)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 54)
            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 15))

            VStack(alignment: .leading, spacing: 5) {
                Text(day.date.chineseMonthDayWeekday)
                    .font(.headline)
                HStack(spacing: 12) {
                    Text("\(day.trashedClips.count) 段录音")
                    Text(day.trashedClips.reduce(0) { $0 + $1.duration }.durationText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 20)
        )
        .contentShape(.rect(cornerRadius: 20))
    }
}

private struct TrashDayDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var day: JournalDay

    @StateObject private var player = AudioPlayerController()
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(day.trashedClips) { clip in
                    TrashRecordingCard(
                        clip: clip,
                        isSelected: player.playingClipID == clip.id,
                        isPlaying: player.playingClipID == clip.id && player.isPlaying,
                        playbackTime: player.playingClipID == clip.id ? player.currentTime : 0,
                        playAction: { player.toggle(clip: clip) },
                        restoreAction: { restore(clip) },
                        deleteAction: { permanentlyDelete(clip) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(day.date.chineseMonthDayWeekday)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        restoreAll()
                    } label: {
                        Label("全部恢复", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("彻底删除这一天", systemImage: "trash.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多操作")
            }
        }
        .alert("彻底删除这一天的回收内容？", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("彻底删除", role: .destructive) {
                permanentlyDeleteAll()
            }
        } message: {
            Text("录音文件和转录内容删除后无法恢复。")
        }
        .onDisappear { player.stop() }
    }

    private func restore(_ clip: RecordingClip) {
        player.stop()
        day.isTrashed = false
        day.trashedAt = nil
        clip.isTrashed = false
        clip.trashedAt = nil
        try? modelContext.save()
        leaveIfEmpty()
    }

    private func restoreAll() {
        player.stop()
        day.isTrashed = false
        day.trashedAt = nil
        for clip in day.trashedClips {
            clip.isTrashed = false
            clip.trashedAt = nil
        }
        try? modelContext.save()
        dismiss()
    }

    private func permanentlyDelete(_ clip: RecordingClip) {
        player.stop()
        let shouldDeleteDay = day.activeClips.isEmpty && day.trashedClips.count == 1
        AudioRecorderController.removeRecordingFiles(for: clip.fileName)
        modelContext.delete(clip)
        if shouldDeleteDay {
            modelContext.delete(day)
        }
        try? modelContext.save()
        if shouldDeleteDay {
            dismiss()
        } else {
            leaveIfEmpty()
        }
    }

    private func permanentlyDeleteAll() {
        player.stop()
        let trashedClips = day.trashedClips
        for clip in trashedClips {
            AudioRecorderController.removeRecordingFiles(for: clip.fileName)
            modelContext.delete(clip)
        }

        if day.isTrashed || day.activeClips.isEmpty {
            modelContext.delete(day)
        }
        try? modelContext.save()
        dismiss()
    }

    private func leaveIfEmpty() {
        if day.trashedClips.isEmpty {
            dismiss()
        }
    }
}

private struct TrashRecordingCard: View {
    let clip: RecordingClip
    let isSelected: Bool
    let isPlaying: Bool
    let playbackTime: TimeInterval
    let playAction: () -> Void
    let restoreAction: () -> Void
    let deleteAction: () -> Void

    @State private var showDeleteConfirmation = false

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

                Text(clip.createdAt.chineseTime)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(clip.duration.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Menu {
                    Button(action: restoreAction) {
                        Label("恢复", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("彻底删除", systemImage: "trash.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 32)
                }
            }

            if isSelected {
                ProgressView(
                    value: min(playbackTime, clip.duration),
                    total: max(clip.duration, 0.1)
                )
                .tint(.accentColor)
                .padding(.leading, 43)
            }

            Text(clip.transcript.isEmpty ? "暂无转录内容" : clip.transcript)
                .font(.subheadline)
                .foregroundStyle(clip.transcript.isEmpty ? .tertiary : .primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 18)
        )
        .animation(.snappy, value: isSelected)
        .alert("彻底删除这段录音？", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("彻底删除", role: .destructive, action: deleteAction)
        } message: {
            Text("录音文件和转录内容删除后无法恢复。")
        }
    }
}
