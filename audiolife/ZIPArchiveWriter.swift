import Foundation

enum ZIPArchiveWriter {
    private struct Entry {
        let url: URL
        let path: String
        let nameData: Data
        let crc32: UInt32
        let size: UInt32
        let modifiedAt: Date
        let localHeaderOffset: UInt32
    }

    private enum ArchiveError: LocalizedError {
        case fileTooLarge(String)
        case archiveTooLarge

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let name):
                return "文件过大，暂时无法加入压缩包：\(name)"
            case .archiveTooLarge:
                return "导出内容过大，暂时无法创建压缩包。"
            }
        }
    }

    nonisolated static func createArchive(
        from directory: URL,
        at destination: URL,
        progress: (Double) -> Void
    ) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let files = try regularFiles(in: directory)
        let totalBytes = try files.reduce(UInt64(0)) { result, url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return result + UInt64(max(0, size))
        }
        let totalWork = max(UInt64(1), totalBytes * 2)
        var completedWork: UInt64 = 0
        var entries: [Entry] = []
        var offset: UInt64 = 0

        for fileURL in files {
            let relativePath = relativePath(of: fileURL, below: directory)
            let nameData = Data(relativePath.utf8)
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let fileSize = UInt64(values.fileSize ?? 0)
            guard fileSize <= UInt64(UInt32.max) else {
                throw ArchiveError.fileTooLarge(relativePath)
            }
            guard offset <= UInt64(UInt32.max) else {
                throw ArchiveError.archiveTooLarge
            }

            let checksum = try crc32(of: fileURL) { byteCount in
                completedWork += UInt64(byteCount)
                progress(Double(completedWork) / Double(totalWork))
            }
            let modifiedAt = values.contentModificationDate ?? Date()
            let entry = Entry(
                url: fileURL,
                path: relativePath,
                nameData: nameData,
                crc32: checksum,
                size: UInt32(fileSize),
                modifiedAt: modifiedAt,
                localHeaderOffset: UInt32(offset)
            )
            let header = localHeader(for: entry)
            try output.write(contentsOf: header)
            offset += UInt64(header.count)
            try copy(fileURL, to: output) { byteCount in
                offset += UInt64(byteCount)
                completedWork += UInt64(byteCount)
                progress(Double(completedWork) / Double(totalWork))
            }
            entries.append(entry)
        }

        guard offset <= UInt64(UInt32.max) else {
            throw ArchiveError.archiveTooLarge
        }
        let centralDirectoryOffset = UInt32(offset)
        for entry in entries {
            let header = centralDirectoryHeader(for: entry)
            try output.write(contentsOf: header)
            offset += UInt64(header.count)
        }

        let centralSize = offset - UInt64(centralDirectoryOffset)
        guard centralSize <= UInt64(UInt32.max), entries.count <= Int(UInt16.max) else {
            throw ArchiveError.archiveTooLarge
        }
        let footer = endOfCentralDirectory(
            entryCount: UInt16(entries.count),
            directorySize: UInt32(centralSize),
            directoryOffset: centralDirectoryOffset
        )
        try output.write(contentsOf: footer)
        try output.synchronize()
        progress(1)
    }

    nonisolated private static func regularFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted {
            relativePath(of: $0, below: directory) < relativePath(of: $1, below: directory)
        }
    }

    nonisolated private static func relativePath(of file: URL, below directory: URL) -> String {
        let base = directory.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        return String(path.dropFirst(min(path.count, base.count + 1)))
    }

    nonisolated private static func copy(
        _ source: URL,
        to output: FileHandle,
        didWrite: (Int) -> Void
    ) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            didWrite(chunk.count)
        }
    }

    nonisolated private static func crc32(
        of url: URL,
        didRead: (Int) -> Void
    ) throws -> UInt32 {
        let table: [UInt32] = (0..<256).map { value in
            var result = UInt32(value)
            for _ in 0..<8 {
                result = (result & 1) == 1
                    ? (result >> 1) ^ 0xEDB8_8320
                    : result >> 1
            }
            return result
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        var checksum: UInt32 = 0xFFFF_FFFF
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            for byte in chunk {
                checksum = table[Int((checksum ^ UInt32(byte)) & 0xFF)] ^ (checksum >> 8)
            }
            didRead(chunk.count)
        }
        return checksum ^ 0xFFFF_FFFF
    }

    nonisolated private static func localHeader(for entry: Entry) -> Data {
        let timestamp = dosTimestamp(entry.modifiedAt)
        var data = Data()
        data.appendLittleEndian(UInt32(0x0403_4B50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0x0800))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(timestamp.time)
        data.appendLittleEndian(timestamp.date)
        data.appendLittleEndian(entry.crc32)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(UInt16(entry.nameData.count))
        data.appendLittleEndian(UInt16(0))
        data.append(entry.nameData)
        return data
    }

    nonisolated private static func centralDirectoryHeader(for entry: Entry) -> Data {
        let timestamp = dosTimestamp(entry.modifiedAt)
        var data = Data()
        data.appendLittleEndian(UInt32(0x0201_4B50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0x0800))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(timestamp.time)
        data.appendLittleEndian(timestamp.date)
        data.appendLittleEndian(entry.crc32)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(UInt16(entry.nameData.count))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(entry.localHeaderOffset)
        data.append(entry.nameData)
        return data
    }

    nonisolated private static func endOfCentralDirectory(
        entryCount: UInt16,
        directorySize: UInt32,
        directoryOffset: UInt32
    ) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x0605_4B50))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(directorySize)
        data.appendLittleEndian(directoryOffset)
        data.appendLittleEndian(UInt16(0))
        return data
    }

    nonisolated private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max(1980, min(2107, components.year ?? 1980))
        let month = max(1, min(12, components.month ?? 1))
        let day = max(1, min(31, components.day ?? 1))
        let hour = max(0, min(23, components.hour ?? 0))
        let minute = max(0, min(59, components.minute ?? 0))
        let second = max(0, min(59, components.second ?? 0))
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
