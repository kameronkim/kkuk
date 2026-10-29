import Foundation
import Darwin

public struct InputEntry: Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let modified: Date
    public let linkTarget: String?
    public let isDirectory: Bool
    public let deviceID: Int32
    public let fileID: UInt64
    // Unlike modification time, ordinary file operations cannot restore ctime.
    // Keep its full precision so same-size writes and metadata restoration are detected.
    public let changedSeconds: Int
    public let changedNanoseconds: Int
}

public struct InputSnapshot: Sendable {
    public let input: URL
    public let inputs: [URL]
    public let entries: [InputEntry]
    public let excludedPaths: [String]
    public let isDirectory: Bool
    public let totalBytes: UInt64
    public let fileCount: Int

    init(inputs: [URL], entries: [InputEntry], excludedPaths: [String]) {
        self.input = inputs[0]
        self.inputs = inputs
        self.entries = entries
        self.excludedPaths = excludedPaths
        self.isDirectory = entries.first { $0.path == inputs[0].lastPathComponent }?.isDirectory ?? false
        var bytes: UInt64 = 0
        var count = 0
        for entry in entries where !entry.isDirectory {
            bytes += entry.size
            count += 1
        }
        self.totalBytes = bytes
        self.fileCount = count
    }
    public var archivePaths: Set<String> { Set(entries.map(\.path)) }
}

public enum InputScanner {
    public static func scanInputs(_ inputs: [URL], checkCancellation: () throws -> Void = {}) throws -> InputSnapshot {
        guard !inputs.isEmpty else { throw KkukError.inputMissing }
        var selections: [URL] = []
        var seen: Set<URL> = []
        for input in inputs {
            try checkCancellation()
            guard input.isFileURL else { throw KkukError.inputMissing }
            let selected = input.standardizedFileURL
            // Resolve ancestors, preserving a selected symbolic link and its output location.
            let normalized = selected.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(selected.lastPathComponent)
            if seen.insert(normalized).inserted { selections.append(normalized) }
        }
        let parent = selections[0].deletingLastPathComponent()
        guard selections.allSatisfy({ $0.deletingLastPathComponent() == parent }) else {
            throw KkukError.differentInputLocations
        }
        var entries: [InputEntry] = []
        var excludedPaths: [String] = []
        for selected in selections {
            try collect(selected, entries: &entries, excludedPaths: &excludedPaths, checkCancellation: checkCancellation)
        }
        return InputSnapshot(inputs: selections, entries: entries.sorted { $0.path < $1.path },
                             excludedPaths: excludedPaths.sorted())
    }

    public static func scan(_ input: URL, checkCancellation: () throws -> Void = {}) throws -> InputSnapshot {
        try scanInputs([input], checkCancellation: checkCancellation)
    }

    private static func collect(_ folder: URL, entries: inout [InputEntry], excludedPaths: inout [String],
                                checkCancellation: () throws -> Void) throws {
        guard folder.path != "/" else { throw KkukError.systemRoot }
        func visit(_ url: URL, path: String) throws {
            try checkCancellation()
            // Finder's custom folder icon is a regular file named Icon followed by CR.
            // Other line breaks remain unsupported by the engine's line-based lists.
            let isFinderIcon = url.lastPathComponent == "Icon\r" && !path.dropLast().contains("\r")
            guard !path.contains("\n"), !path.contains("\r") || isFinderIcon else {
                throw KkukError.unsupportedFileName(url.lastPathComponent)
            }
            // Read type, identity and timestamps together without following symbolic links.
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                let code = errno
                if url == folder && (code == ENOENT || code == ENOTDIR) { throw KkukError.inputMissing }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            let type: FileAttributeType
            switch metadata.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR): type = .typeDirectory
            case mode_t(S_IFREG): type = .typeRegular
            case mode_t(S_IFLNK): type = .typeSymbolicLink
            case mode_t(S_IFSOCK): type = .typeSocket
            default: type = .typeUnknown
            }
            if isFinderIcon && type != .typeRegular {
                throw KkukError.unsupportedFileName(url.lastPathComponent)
            }
            // Unix sockets are live communication endpoints, not archive data.
            // Classify by filesystem type, preserving regular files and symbolic links.
            if type == .typeSocket {
                guard url != folder else { throw KkukError.unsupportedInput(url.path) }
                excludedPaths.append(path)
                return
            }
            guard type == .typeDirectory || type == .typeRegular || type == .typeSymbolicLink else {
                throw KkukError.unsupportedInput(path)
            }
            let link = type == .typeSymbolicLink ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            let entry = InputEntry(path: path,
                                   size: type == .typeDirectory ? 0 : UInt64(max(0, metadata.st_size)),
                                   modified: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)
                                       + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000),
                                   linkTarget: link, isDirectory: type == .typeDirectory,
                                   deviceID: metadata.st_dev, fileID: metadata.st_ino,
                                   changedSeconds: metadata.st_ctimespec.tv_sec,
                                   changedNanoseconds: metadata.st_ctimespec.tv_nsec)
            entries.append(entry)
            if entry.isDirectory {
                // URL path components can normalize Unicode. Keep the on-disk spelling
                // for literal 7-Zip selection/exclusion matching, including NFC names.
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                    try visit(url.appendingPathComponent(name), path: path + "/" + name)
                }
            }
        }
        let name = (try? folder.resourceValues(forKeys: [.nameKey]).name) ?? folder.lastPathComponent
        try visit(folder, path: name)
    }
}

