import SwiftData
import SwiftUI

struct DiaryComposerLauncher: View {
    @Environment(\.modelContext) private var context
    @State private var day: JournalDay?
    @State private var error: String?
    var body: some View {
        Group {
            if let day { EntryComposerView(initialDay: day) }
            else if let error { ContentUnavailableView("无法打开日记", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView() }
        }.task {
            do { day = try EntryLibrary.day(for: Date(), in: context); try context.save() }
            catch { self.error = error.localizedDescription }
        }
    }
}
