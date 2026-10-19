import Foundation
import SwiftUI

nonisolated enum DataSafetyBackup {
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static var backupRoot: URL { support.appendingPathComponent("DataSafetyBackups", isDirectory: true) }

    static func prepareIfNeeded() throws {
        guard UserDefaults.standard.integer(forKey: "entry-schema-version") < 1 else { return }
        let names = ["default.store", "default.store-wal", "default.store-shm"]
        guard FileManager.default.fileExists(atPath: support.appendingPathComponent("default.store").path) else { return }
        let target = backupRoot.appendingPathComponent("before-entry-upgrade-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names {
            let source = support.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: target.appendingPathComponent(name))
        }
        let text = "Pre-migration database snapshot. Media remains in Documents/Recordings. Do not delete or replace the live database without a verified restore procedure.\n"
        try Data(text.utf8).write(to: target.appendingPathComponent("README.txt"))
    }

    static func exportLatest() async throws -> URL {
        try await Task.detached {
            let folders = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.creationDateKey])
            guard let folder = folders.sorted(by: {
                ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }).first else { throw CocoaError(.fileNoSuchFile) }
            let zip = FileManager.default.temporaryDirectory.appendingPathComponent("AudioLife-database-backup-" + UUID().uuidString + ".zip")
            try ZIPArchiveWriter.createArchive(from: folder, at: zip) { _ in }
            return zip
        }.value
    }
}

struct DataStoreRecoveryView: View {
    let message: String
    @State private var backup: URL?
    @State private var exportError: String?
    @State private var exporting = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("暂时无法打开资料库", systemImage: "externaldrive.badge.exclamationmark").font(.title2.bold())
                Text("原数据库没有被清空。请保留当前 App 和资料，先导出升级前的数据库备份用于排查。")
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(exporting ? "正在导出…" : "导出升级前数据库备份") {
                    Task {
                        exporting = true
                        defer { exporting = false }
                        do { backup = try await DataSafetyBackup.exportLatest() }
                        catch { exportError = error.localizedDescription }
                    }
                }.disabled(exporting)
                if let exportError { Text(exportError).foregroundStyle(.orange) }
                Spacer()
            }.padding().navigationTitle("数据保护")
                .sheet(isPresented: Binding(get: { backup != nil }, set: { if !$0 { backup = nil } })) {
                    if let backup { EntryShareSheet(items: [backup]) }
                }
        }
    }
}
