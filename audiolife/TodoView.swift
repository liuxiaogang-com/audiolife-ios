import SwiftData
import SwiftUI

struct TodoSuggestionBatch: Identifiable {
    let id = UUID()
    let itemIDs: [UUID]
}

struct TodoListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.createdAt, order: .reverse) private var items: [TodoItem]
    @State private var editor: TodoEditorContext?
    @State private var showsCompleted = false

    private var suggestedItems: [TodoItem] {
        items.filter(\.isSuggested)
    }

    private var activeItems: [TodoItem] {
        items.filter { !$0.isSuggested && !$0.isCompleted }
            .sorted {
                switch ($0.dueDate, $1.dueDate) {
                case let (left?, right?): left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): $0.createdAt > $1.createdAt
                }
            }
    }

    private var completedItems: [TodoItem] {
        items.filter { !$0.isSuggested && $0.isCompleted }
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    ContentUnavailableView(
                        "还没有待办",
                        systemImage: "checklist",
                        description: Text("可以手动添加，也可以在录音完成后确认识别出的候选。")
                    )
                    .listRowBackground(Color.clear)
                }

                if !suggestedItems.isEmpty {
                    Section("待确认") {
                        ForEach(suggestedItems) { item in
                            TodoSuggestionRow(
                                item: item,
                                acceptAction: { accept(item) },
                                editAction: { editor = TodoEditorContext(item: item) },
                                ignoreAction: { delete(item) }
                            )
                        }
                    }
                }

                if !activeItems.isEmpty {
                    Section("待办") {
                        ForEach(activeItems) { item in
                            TodoRow(
                                item: item,
                                toggleAction: { toggle(item) },
                                editAction: { editor = TodoEditorContext(item: item) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { delete(item) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !completedItems.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showsCompleted) {
                            ForEach(completedItems) { item in
                                TodoRow(
                                    item: item,
                                    toggleAction: { toggle(item) },
                                    editAction: { editor = TodoEditorContext(item: item) }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { delete(item) } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        } label: {
                            Label("已完成 \(completedItems.count)", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("待办")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = TodoEditorContext(item: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加待办")
                }
            }
        }
        .sheet(item: $editor) { context in
            TodoEditorSheet(context: context) { title, notes, dueDate in
                saveEditor(
                    context,
                    title: title,
                    notes: notes,
                    dueDate: dueDate
                )
            }
        }
    }

    private func accept(_ item: TodoItem) {
        item.isSuggested = false
        try? modelContext.save()
        Task {
            await TodoNotificationScheduler.schedule(for: item)
            try? modelContext.save()
        }
    }

    private func toggle(_ item: TodoItem) {
        item.isCompleted.toggle()
        item.completedAt = item.isCompleted ? Date() : nil
        if item.isCompleted {
            TodoNotificationScheduler.cancel(for: item)
        } else {
            Task { await TodoNotificationScheduler.schedule(for: item) }
        }
        try? modelContext.save()
    }

    private func delete(_ item: TodoItem) {
        TodoNotificationScheduler.cancel(for: item)
        modelContext.delete(item)
        try? modelContext.save()
    }

    private func saveEditor(
        _ context: TodoEditorContext,
        title: String,
        notes: String,
        dueDate: Date?
    ) {
        let item: TodoItem
        if let existing = context.item {
            item = existing
            TodoNotificationScheduler.cancel(for: item)
            item.title = title
            item.notes = notes
            item.dueDate = dueDate
            item.isSuggested = false
        } else {
            item = TodoItem(title: title, notes: notes, dueDate: dueDate)
            modelContext.insert(item)
        }
        try? modelContext.save()
        Task {
            await TodoNotificationScheduler.schedule(for: item)
            try? modelContext.save()
        }
    }
}

private struct TodoEditorContext: Identifiable {
    let id = UUID()
    let item: TodoItem?
}

private struct TodoRow: View {
    let item: TodoItem
    let toggleAction: () -> Void
    let editAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggleAction) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Button(action: editAction) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        .strikethrough(item.isCompleted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let dueDate = item.dueDate {
                        Label(
                            dueDate.formatted(
                                Date.FormatStyle(date: .abbreviated, time: .shortened)
                                    .locale(Locale(identifier: "zh_CN"))
                            ),
                            systemImage: "bell"
                        )
                        .font(.caption)
                        .foregroundStyle(dueDate < Date() && !item.isCompleted ? .red : .secondary)
                    }
                    if !item.notes.isEmpty {
                        Text(item.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }
}

private struct TodoSuggestionRow: View {
    let item: TodoItem
    let acceptAction: () -> Void
    let editAction: () -> Void
    let ignoreAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(item.title)
                .font(.body.weight(.medium))
            if !item.sourceExcerpt.isEmpty {
                Text("来自录音：“\(item.sourceExcerpt)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let dueDate = item.dueDate {
                Label(
                    dueDate.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .shortened)
                            .locale(Locale(identifier: "zh_CN"))
                    ),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Menu {
                    Button("编辑", systemImage: "pencil", action: editAction)
                    Button("忽略", systemImage: "trash", role: .destructive, action: ignoreAction)
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("加入待办", action: acceptAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct TodoEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let context: TodoEditorContext
    let onSave: (String, String, Date?) -> Void

    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date

    init(
        context: TodoEditorContext,
        onSave: @escaping (String, String, Date?) -> Void
    ) {
        self.context = context
        self.onSave = onSave
        _title = State(initialValue: context.item?.title ?? "")
        _notes = State(initialValue: context.item?.notes ?? "")
        _hasDueDate = State(initialValue: context.item?.dueDate != nil)
        _dueDate = State(initialValue: context.item?.dueDate ?? Date().addingTimeInterval(3_600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("待办") {
                    TextField("要做什么？", text: $title, axis: .vertical)
                        .lineLimit(1...4)
                    TextField("备注（可选）", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section {
                    Toggle("设置提醒时间", isOn: $hasDueDate.animation())
                    if hasDueDate {
                        DatePicker(
                            "提醒时间",
                            selection: $dueDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
                if let excerpt = context.item?.sourceExcerpt, !excerpt.isEmpty {
                    Section("来源录音") {
                        Text(excerpt)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(context.item == nil ? "新建待办" : "编辑待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes.trimmingCharacters(in: .whitespacesAndNewlines),
                            hasDueDate ? dueDate : nil
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TodoSuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [TodoItem]
    @State private var editor: TodoEditorContext?

    let batch: TodoSuggestionBatch

    private var items: [TodoItem] {
        allItems.filter { batch.itemIDs.contains($0.id) && $0.isSuggested }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        TodoSuggestionRow(
                            item: item,
                            acceptAction: { accept(item) },
                            editAction: { editor = TodoEditorContext(item: item) },
                            ignoreAction: { ignore(item) }
                        )
                    }
                } footer: {
                    Text("这是从录音内容中发现的候选，加入前请确认内容和时间。")
                }
            }
            .navigationTitle("发现可能的待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后处理") { dismiss() }
                }
                if !items.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("全部加入") {
                            for item in items { accept(item) }
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $editor) { context in
            TodoEditorSheet(context: context) { title, notes, dueDate in
                guard let item = context.item else { return }
                TodoNotificationScheduler.cancel(for: item)
                item.title = title
                item.notes = notes
                item.dueDate = dueDate
                item.isSuggested = false
                try? modelContext.save()
                Task {
                    await TodoNotificationScheduler.schedule(for: item)
                    try? modelContext.save()
                }
            }
        }
        .onChange(of: items.count) { _, count in
            if count == 0 { dismiss() }
        }
    }

    private func accept(_ item: TodoItem) {
        item.isSuggested = false
        try? modelContext.save()
        Task {
            await TodoNotificationScheduler.schedule(for: item)
            try? modelContext.save()
        }
    }

    private func ignore(_ item: TodoItem) {
        TodoNotificationScheduler.cancel(for: item)
        modelContext.delete(item)
        try? modelContext.save()
    }
}
