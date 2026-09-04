//
//  ContentView.swift
//  audiolife
//
//  Created by xiao on 2026/8/29.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Query(sort: \JournalDay.date, order: .reverse) private var days: [JournalDay]
    @StateObject private var searchPlayer = AudioPlayerController()

    @State private var path: [UUID] = []
    @State private var recordingDay: JournalDay?
    @State private var didRecoverRecordings = false
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var selectedDate: Date?
    @State private var calendarAnchor = Date()
    @State private var isCalendarExpanded = false
    @State private var showFilters = false
    @State private var showTrash = false
    @State private var showSettings = false
    @State private var exportDay: JournalDay?
    @State private var showExportOptions = false
    @State private var todoSuggestionBatch: TodoSuggestionBatch?

    private var visibleDays: [JournalDay] {
        days.filter { !$0.isTrashed && !$0.activeClips.isEmpty }
    }

    private var availableTags: [String] {
        var counts: [String: Int] = [:]
        var displayNames: [String: String] = [:]
        for clip in visibleDays.flatMap(\.activeClips) {
            for tag in clip.allTags {
                let key = tag.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "zh_CN")
                )
                counts[key, default: 0] += 1
                displayNames[key] = displayNames[key] ?? tag
            }
        }
        return counts.keys.sorted {
            if counts[$0] == counts[$1] {
                return (displayNames[$0] ?? $0).localizedStandardCompare(
                    displayNames[$1] ?? $1
                ) == .orderedAscending
            }
            return counts[$0, default: 0] > counts[$1, default: 0]
        }.compactMap { displayNames[$0] }
    }

    private var isFiltering: Bool {
        selectedDate != nil
            || selectedTag != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recordingCountsByDate: [Date: Int] {
        Dictionary(uniqueKeysWithValues: visibleDays.map {
            (Calendar.current.startOfDay(for: $0.date), $0.activeClips.count)
        })
    }

    private var matchingClips: [RecordingClip] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleDays.flatMap(\.activeClips).filter { clip in
            let matchesDate = selectedDate == nil || Calendar.current.isDate(
                clip.createdAt,
                inSameDayAs: selectedDate ?? clip.createdAt
            )
            let matchesTag = selectedTag == nil || clip.allTags.contains { tag in
                tag.localizedCaseInsensitiveCompare(selectedTag ?? "") == .orderedSame
            }
            let matchesQuery = query.isEmpty
                || clip.transcript.localizedStandardContains(query)
                || clip.aiTitle.localizedStandardContains(query)
                || clip.aiSummary.localizedStandardContains(query)
                || clip.allTags.contains { $0.localizedStandardContains(query) }
            return matchesDate && matchesTag && matchesQuery
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        TabView {
            NavigationStack(path: $path) {
                List {
                if visibleDays.isEmpty && searchText.isEmpty {
                    ContentUnavailableView(
                        "还没有录音",
                        systemImage: "waveform",
                        description: Text("点击下方按钮，记录今天的第一段声音。")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if isFiltering && matchingClips.isEmpty {
                    ContentUnavailableView(
                        "没有找到相关内容",
                        systemImage: "text.magnifyingglass",
                        description: Text(
                            selectedDate == nil
                                ? "换一个关键词或标签试试。"
                                : "这一天没有符合当前条件的录音，可以取消日期筛选。"
                        )
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if isFiltering {
                    HStack {
                        Text("找到 \(matchingClips.count) 段录音")
                        Spacer()
                        Button("清除筛选") { clearFilters() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .listRowInsets(
                        EdgeInsets(top: 8, leading: 18, bottom: 2, trailing: 18)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    ForEach(matchingClips) { clip in
                        SearchRecordingCard(
                            clip: clip,
                            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                            isSelected: searchPlayer.playingClipID == clip.id,
                            isPlaying: searchPlayer.playingClipID == clip.id
                                && searchPlayer.isPlaying,
                            playbackTime: searchPlayer.playingClipID == clip.id
                                ? searchPlayer.currentTime
                                : 0,
                            playAction: { searchPlayer.toggle(clip: clip) },
                            openDayAction: {
                                guard let dayID = clip.day?.id else { return }
                                searchPlayer.stop()
                                path.append(dayID)
                            }
                        )
                        .listRowInsets(
                            EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } else {
                    ForEach(visibleDays) { day in
                        DayRow(day: day)
                        .contentShape(.rect)
                        .onTapGesture {
                            path.append(day.id)
                        }
                        .accessibilityAddTraits(.isButton)
                        .listRowInsets(
                            EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                moveToTrash(day)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                exportDay = day
                                showExportOptions = true
                            } label: {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("录音日记")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showFilters = true
                        } label: {
                            Image(systemName: isFiltering
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                            )
                        }
                        .accessibilityLabel("筛选")

                        Menu {
                            Button {
                                showSettings = true
                            } label: {
                                Label("设置", systemImage: "gearshape")
                            }
                            Button {
                                showTrash = true
                            } label: {
                                Label("回收站", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("更多")
                    }
                }
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "搜索转写、摘要和标签"
                )
                .searchToolbarBehavior(.minimize)
                .onChange(of: searchText) { _, _ in
                    searchPlayer.stop()
                }
                .onChange(of: selectedTag) { _, _ in
                    searchPlayer.stop()
                }
                .onChange(of: selectedDate) { _, _ in
                    searchPlayer.stop()
                }
                .onChange(of: availableTags) { _, tags in
                    guard let selectedTag else { return }
                    if !tags.contains(where: {
                        $0.localizedCaseInsensitiveCompare(selectedTag) == .orderedSame
                    }) {
                        self.selectedTag = nil
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button {
                            presentTodayRecorder()
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.title3.weight(.semibold))
                                .frame(width: 56, height: 56)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        .accessibilityLabel("录制今天的日记")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }
                .navigationDestination(for: UUID.self) { id in
                    if let day = days.first(where: { $0.id == id }) {
                        DayDetailView(day: day)
                    } else {
                        ContentUnavailableView(
                            "找不到这一天",
                            systemImage: "calendar.badge.exclamationmark"
                        )
                    }
                }
            }
            .tabItem {
                Label("日记", systemImage: "waveform")
            }

            TodoListView()
                .tabItem {
                    Label("待办", systemImage: "checklist")
                }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: router.quickRecordingRequest) { _, _ in
            handleQuickRecordingRequest()
        }
        .sheet(item: $recordingDay) { day in
            RecordingSheet(day: day)
        }
        .sheet(isPresented: $showTrash) {
            TrashView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showFilters) {
            JournalFilterSheet(
                anchorDate: $calendarAnchor,
                selectedDate: $selectedDate,
                isCalendarExpanded: $isCalendarExpanded,
                selectedTag: $selectedTag,
                recordingCounts: recordingCountsByDate,
                availableTags: availableTags
            )
        }
        .sheet(item: $todoSuggestionBatch) { batch in
            TodoSuggestionSheet(batch: batch)
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoSuggestionsCreated)) { note in
            guard let ids = note.userInfo?["ids"] as? [UUID], !ids.isEmpty else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(550))
                todoSuggestionBatch = TodoSuggestionBatch(itemIDs: ids)
            }
        }
        .dayExportDialog(day: exportDay, isPresented: $showExportOptions)
        .task {
            if router.shouldPresentQuickRecorder {
                handleQuickRecordingRequest()
            }
            guard !didRecoverRecordings else { return }
            didRecoverRecordings = true
            RecordingRecovery.recover(in: modelContext)
        }
    }

    private func handleQuickRecordingRequest() {
        guard router.shouldPresentQuickRecorder else { return }
        router.consumeQuickRecordingRequest()
        presentTodayRecorder()
    }

    private func presentTodayRecorder() {
        let today = Calendar.current.startOfDay(for: Date())
        let day: JournalDay

        if let existing = days.first(where: {
            !$0.isTrashed && Calendar.current.isDate($0.date, inSameDayAs: today)
        }) {
            day = existing
        } else {
            day = JournalDay(date: today)
            modelContext.insert(day)
            try? modelContext.save()
        }
        recordingDay = day
    }

    private func moveToTrash(_ day: JournalDay) {
        for clip in day.clips {
            clip.isTrashed = true
            clip.trashedAt = Date()
        }
        day.isTrashed = true
        day.trashedAt = Date()
        try? modelContext.save()
    }

    private func clearFilters() {
        withAnimation(.snappy) {
            selectedDate = nil
            selectedTag = nil
            searchText = ""
        }
    }
}

private struct JournalFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var anchorDate: Date
    @Binding var selectedDate: Date?
    @Binding var isCalendarExpanded: Bool
    @Binding var selectedTag: String?
    let recordingCounts: [Date: Int]
    let availableTags: [String]

    private var hasSelection: Bool {
        selectedDate != nil || selectedTag != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("日期")
                            .font(.headline)
                            .padding(.horizontal, 4)

                        RecordingCalendar(
                            anchorDate: $anchorDate,
                            selectedDate: $selectedDate,
                            isExpanded: $isCalendarExpanded,
                            recordingCounts: recordingCounts
                        )
                    }

                    if !availableTags.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("标签")
                                .font(.headline)
                                .padding(.horizontal, 4)
                            TagFilterBar(tags: availableTags, selection: $selectedTag)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if hasSelection {
                        Button("重置") {
                            withAnimation(.snappy) {
                                selectedDate = nil
                                selectedTag = nil
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct RecordingCalendar: View {
    @Binding var anchorDate: Date
    @Binding var selectedDate: Date?
    @Binding var isExpanded: Bool
    let recordingCounts: [Date: Int]

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 7
    )
    private let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "zh_CN")
        value.timeZone = .current
        value.firstWeekday = 2
        return value
    }

    private var displayedDates: [Date] {
        isExpanded ? monthDates : weekDates
    }

    private var weekDates: [Date] {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: anchorDate)?.start else {
            return []
        }
        return (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
    }

    private var monthDates: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: anchorDate),
              let days = calendar.range(of: .day, in: .month, for: anchorDate) else {
            return []
        }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leadingDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDays,
            to: interval.start
        ) else { return [] }
        let cellCount = Int(ceil(Double(leadingDays + days.count) / 7.0)) * 7
        return (0..<cellCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: gridStart)
        }
    }

    private var headerTitle: String {
        if isExpanded {
            return anchorDate.formatted(
                .dateTime.locale(Locale(identifier: "zh_CN")).year().month(.wide)
            )
        }
        guard let start = weekDates.first, let end = weekDates.last else { return "" }
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(start.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month(.wide)))\(calendar.component(.day, from: start))日–\(calendar.component(.day, from: end))日"
        }
        return "\(start.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()))–\(end.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()))"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    move(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "上个月" : "上一周")

                Text(headerTitle)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())

                Spacer()

                if selectedDate != nil {
                    Button("查看全部") {
                        withAnimation(.snappy) { selectedDate = nil }
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }

                Button {
                    move(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "下个月" : "下一周")

                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "calendar")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(isExpanded ? "收起为一周" : "展开整月")
            }

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(weekdayTitles, id: \.self) { title in
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(displayedDates, id: \.self) { date in
                    dayButton(for: date)
                }
            }
        }
        .padding(12)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 20)
        )
        .animation(.snappy, value: isExpanded)
        .animation(.snappy, value: anchorDate)
    }

    private func dayButton(for date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let count = recordingCounts[day, default: 0]
        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isToday = calendar.isDateInToday(day)
        let isInDisplayedMonth = calendar.isDate(day, equalTo: anchorDate, toGranularity: .month)

        return Button {
            withAnimation(.snappy) {
                selectedDate = isSelected ? nil : day
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(dayForeground(
                        isSelected: isSelected,
                        isInDisplayedMonth: isInDisplayedMonth
                    ))
                    .frame(width: 32, height: 28)
                    .background(isSelected ? Color.accentColor : Color.clear, in: Circle())
                    .overlay {
                        if isToday && !isSelected {
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 1.5)
                        }
                    }

                if count > 0 {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 4, height: 4)
                        if count > 1 {
                            Text("\(count)")
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 8)
                } else {
                    Color.clear.frame(height: 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 39)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(day.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.wide)))，\(count) 段录音"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func dayForeground(
        isSelected: Bool,
        isInDisplayedMonth: Bool
    ) -> Color {
        if isSelected { return .white }
        if isExpanded && !isInDisplayedMonth { return .secondary.opacity(0.45) }
        return .primary
    }

    private func move(by value: Int) {
        let component: Calendar.Component = isExpanded ? .month : .weekOfYear
        guard let next = calendar.date(byAdding: component, value: value, to: anchorDate) else {
            return
        }
        withAnimation(.snappy) { anchorDate = next }
    }
}

private struct DayRow: View {
    let day: JournalDay

    private var displayTitle: String {
        if Calendar.current.isDateInToday(day.date) { return "今天" }
        if Calendar.current.isDateInYesterday(day.date) { return "昨天" }
        return day.date.chineseMonthDayWeekday
    }

    private var transcriptPreview: String? {
        let candidates = day.sortedClips.filter { !$0.transcript.isEmpty }
        return candidates.first?.transcript
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(day.date.chineseDay)
                    .font(.title2.weight(.bold))
                Text(day.date.chineseMonth)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 54)
            .background(.tint.opacity(0.12), in: .rect(cornerRadius: 15))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayTitle)
                        .font(.headline)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("\(day.activeClips.count) 段录音")
                    Text(day.totalDuration.durationText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let transcriptPreview {
                    Text(transcriptPreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
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

private struct TagFilterBar: View {
    let tags: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                tagButton(title: "全部", tag: nil)
                ForEach(tags, id: \.self) { tag in
                    tagButton(title: "#\(tag)", tag: tag)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
    }

    private func tagButton(title: String, tag: String?) -> some View {
        let isSelected: Bool
        if let tag, let selection {
            isSelected = tag.localizedCaseInsensitiveCompare(selection) == .orderedSame
        } else {
            isSelected = tag == nil && selection == nil
        }

        return Button {
            withAnimation(.snappy) { selection = tag }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.purple : Color(uiColor: .secondarySystemGroupedBackground),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SearchRecordingCard: View {
    let clip: RecordingClip
    let query: String
    let isSelected: Bool
    let isPlaying: Bool
    let playbackTime: TimeInterval
    let playAction: () -> Void
    let openDayAction: () -> Void

    @State private var transcriptExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Button(action: playAction) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.tint, in: Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.createdAt.chineseMonthDayWeekday)
                        .font(.subheadline.weight(.semibold))
                    Text(clip.createdAt.chineseTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(clip.duration.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button(action: openDayAction) {
                    Image(systemName: "calendar")
                        .frame(width: 28, height: 28)
                }
                    .buttonStyle(.plain)
                    .disabled(clip.day == nil)
                    .accessibilityLabel("查看当天")
            }

            if isSelected {
                VStack(spacing: 4) {
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
            }

            if !clip.aiTitle.isEmpty {
                HighlightedResultText(
                    text: clip.aiTitle,
                    query: query,
                    font: .subheadline.bold()
                )
            }

            if !clip.aiSummary.isEmpty {
                HighlightedResultText(
                    text: clip.aiSummary,
                    query: query,
                    font: .subheadline
                )
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            if !clip.allTags.isEmpty {
                HStack(spacing: 7) {
                    ForEach(Array(clip.allTags.prefix(3)), id: \.self) { tag in
                        Text("#\(tag)")
                            .lineLimit(1)
                    }
                    if clip.allTags.count > 3 {
                        Text("+\(clip.allTags.count - 3)")
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }

            if clip.transcript.isEmpty {
                Text("暂无转写内容")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else {
                HighlightedResultText(
                    text: clip.transcript,
                    query: query,
                    font: .body
                )
                .lineSpacing(3)
                .lineLimit(transcriptExpanded ? nil : 4)

                Button {
                    withAnimation(.snappy) { transcriptExpanded.toggle() }
                } label: {
                    Text(transcriptExpanded ? "收起" : "展开全文")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 18)
        )
        .animation(.snappy, value: isSelected)
    }
}

private struct HighlightedResultText: View {
    let text: String
    let query: String
    let font: Font

    var body: some View {
        Text(attributedText)
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributedText: AttributedString {
        guard !query.isEmpty else { return AttributedString(text) }
        let mutable = NSMutableAttributedString(string: text)
        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let range = source.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard range.location != NSNotFound else { break }
            mutable.addAttributes(
                [
                    .backgroundColor: UIColor.systemYellow.withAlphaComponent(0.28),
                    .foregroundColor: UIColor.label
                ],
                range: range
            )
            let nextLocation = range.location + range.length
            guard nextLocation < source.length else { break }
            searchRange = NSRange(
                location: nextLocation,
                length: source.length - nextLocation
            )
        }
        return AttributedString(mutable)
    }
}

#Preview {
    ContentView()
        .environment(AppRouter.shared)
        .modelContainer(for: [JournalDay.self, RecordingClip.self], inMemory: true)
}
