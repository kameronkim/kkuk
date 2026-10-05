import Foundation
import Darwin

public enum KkukError: LocalizedError {
    case message(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "압축을 취소했습니다."
        }
    }
}

public struct InputEntry: Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let modified: Date?
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
    public let entries: [InputEntry]
    public let excludedPaths: [String]
    public var isDirectory: Bool { entries.first { $0.path == input.lastPathComponent }?.isDirectory ?? false }
    public var totalBytes: UInt64 { entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size } }
    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var archivePaths: Set<String> { Set(entries.map(\.path)) }
}

public enum InputScanner {
    public static func scan(_ input: URL, checkCancellation: () throws -> Void = {}) throws -> InputSnapshot {
        let folder = input.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            throw KkukError.message("압축할 파일이나 폴더를 선택해 주세요.")
        }
        guard folder.path != "/" else { throw KkukError.message("시스템 루트 대신 압축할 파일이나 폴더를 선택해 주세요.") }
        var entries: [InputEntry] = []
        var excludedPaths: [String] = []
        func visit(_ url: URL, path: String) throws {
            try checkCancellation()
            guard !path.contains("\n"), !path.contains("\r") else {
                throw KkukError.message("줄바꿈이 포함된 파일 이름은 현재 지원하지 않습니다: \(url.lastPathComponent)")
            }
            // Read type, identity and timestamps together without following symbolic links.
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let type: FileAttributeType
            switch metadata.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR): type = .typeDirectory
            case mode_t(S_IFREG): type = .typeRegular
            case mode_t(S_IFLNK): type = .typeSymbolicLink
            case mode_t(S_IFSOCK): type = .typeSocket
            default: type = .typeUnknown
            }
            // Unix sockets are live communication endpoints, not archive data.
            // Classify by filesystem type, preserving regular files and symbolic links.
            if type == .typeSocket {
                excludedPaths.append(path)
                return
            }
            guard type == .typeDirectory || type == .typeRegular || type == .typeSymbolicLink else {
                throw KkukError.message("일반 파일·폴더·심볼릭 링크만 압축할 수 있습니다: \(path)")
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
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, path: path + "/" + child.lastPathComponent)
                }
            }
        }
        try visit(folder, path: folder.lastPathComponent)
        return InputSnapshot(input: folder, entries: entries.sorted { $0.path < $1.path }, excludedPaths: excludedPaths.sorted())
    }
}

public struct CompressionPreset: Equatable, Sendable {
    public let name: String
    public let dictionaryMiB: Int
    public let memoryAdjusted: Bool
    public var estimatedMemoryBytes: UInt64 { UInt64(dictionaryMiB * 12 + 128) * 1_048_576 }
    public static func select(inputBytes: UInt64, memoryBudgetBytes: UInt64) -> CompressionPreset {
        let mib: UInt64 = 1_048_576
        let choices = [64, 128, 256, 512, 1024]
        let preferred: Int
        switch inputBytes {
        case ...(256 * mib): preferred = 64
        case ...(1024 * mib): preferred = 128
        case ...(4096 * mib): preferred = 256
        case ...(16384 * mib): preferred = 512
        default: preferred = 1024
        }
        let fitted = choices.last { $0 <= preferred && UInt64($0 * 12 + 128) * mib <= memoryBudgetBytes } ?? 64
        let names = [64: "소형 고압축", 128: "일반 고압축", 256: "대형 고압축", 512: "초대형 고압축", 1024: "극대형 고압축"]
        return CompressionPreset(name: names[fitted]!, dictionaryMiB: fitted, memoryAdjusted: fitted < preferred)
    }
}

public enum MemoryBudget {
    public static func current() -> UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return physical / 3 }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return physical / 3 }
        let reclaimable = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(pageSize)
        return min(physical / 2, reclaimable * 2 / 3)
    }
}

// Mutable process/cancellation state is protected by lock; execution is serial per job.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Process?
    private var stopping: Process?
    private var cancelled = false
    public init() {}
    public func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw KkukError.cancelled }
    }
    public func cancel() {
        lock.lock()
        cancelled = true
        if let process = active { stopLocked(process) }
        lock.unlock()
    }
    // Called with lock held. Escalation belongs only to this active child process.
    private func stopLocked(_ process: Process) {
        guard active === process, stopping !== process, process.isRunning else { return }
        stopping = process
        process.interrupt()
        for (delay, signal) in [(2.0, SIGTERM), (4.0, SIGKILL)] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.active === process, self.stopping === process, process.isRunning else { return }
                // Never signal a replacement job or a process that has already exited.
                _ = Darwin.kill(process.processIdentifier, signal)
            }
        }
    }
    public func run(executable: URL, arguments: [String], directory: URL? = nil,
                    output: (String) -> Void = { _ in }) throws -> String {
        try checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // The engine needs locale and standard filesystem locations, not the app's
        // secrets, loader settings, or custom executable search paths.
        process.environment = [
            "LC_ALL": "en_US.UTF-8",
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw KkukError.cancelled }
        do { try process.run() } catch { lock.unlock(); throw error }
        active = process
        lock.unlock()
        try? pipe.fileHandleForWriting.close()
        defer {
            lock.lock()
            stopLocked(process)
            lock.unlock()
            if process.isRunning { process.waitUntilExit() }
            try? pipe.fileHandleForReading.close()
            lock.lock(); active = nil; stopping = nil; lock.unlock()
        }
        var transcript = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            // A pipe read returns bytes already available instead of waiting to fill the buffer.
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(pipe.fileHandleForReading.fileDescriptor, $0.baseAddress!, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            let chunk = Data(buffer.prefix(count))
            transcript.append(chunk)
            output(String(decoding: chunk, as: UTF8.self))
        }
        process.waitUntilExit()
        try checkCancellation()
        let text = String(decoding: transcript, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let reason = process.terminationStatus == 1 ? "일부 파일을 읽지 못했습니다." : "압축 엔진 작업에 실패했습니다."
            throw KkukError.message("\(reason) (코드 \(process.terminationStatus))\n\(text.suffix(1400))")
        }
        return text
    }
}

// Progress tokens can span reads; retain only the current ASCII token.
struct CompressionProgressParser {
    private var boundary = true
    private var digits = 0
    private var value = 0
    mutating func consume(_ chunk: String) -> Double? {
        var latest: Double?
        for byte in chunk.utf8 {
            if byte >= 48 && byte <= 57, boundary || digits > 0 {
                if digits < 3 {
                    value = value * 10 + Int(byte - 48)
                    digits += 1
                } else {
                    digits = 0; value = 0
                }
                boundary = false
                continue
            }
            if byte == 37 && digits > 0 { latest = min(Double(value) / 100, 1) }
            digits = 0; value = 0
            boundary = byte == 8 || byte == 32 || (byte >= 9 && byte <= 13)
        }
        return latest
    }
}

public enum ArchiveStage: String, Sendable { case compressing, verifying, checkingContents, finished }
public struct ArchiveResult: Sendable {
    public let url: URL
    public let originalBytes: UInt64
    public let archiveBytes: UInt64
    public let elapsed: TimeInterval
    public let preset: CompressionPreset
}

public final class ArchiveJob: Sendable {
    public let runner = ProcessRunner()
    public let engine: URL
    public init(engine: URL) { self.engine = engine }
    public func cancel() { runner.cancel() }
    public static func validateDestination(_ destination: URL, source: URL, requireAvailable: Bool = true) throws {
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        guard parent.path != root.path, !parent.path.hasPrefix(root.path + "/") else {
            throw KkukError.message("압축 결과는 원본 폴더 바깥에 저장해 주세요.")
        }
        guard destination.pathExtension.lowercased() == "7z" else { throw KkukError.message("저장 파일의 확장자는 .7z여야 합니다.") }
        guard !requireAvailable || (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else {
            throw KkukError.message("같은 이름의 파일이 있습니다. 다른 이름으로 저장해 주세요.")
        }
    }
    public static func listedPaths(_ text: String) -> Set<String> {
        // 7-Zip separates records with LF (or CRLF), not Unicode filename characters.
        // CR and LF inside source names are rejected by InputScanner.
        Set(text.components(separatedBy: "\n").compactMap { line in
            let record = line.hasSuffix("\r") ? String(line.dropLast()) : line
            return record.hasPrefix("Path = ") ? String(record.dropFirst(7)) : nil
        })
    }
    private static func restrictAccess(to url: URL, directory: Bool) throws {
        // Change the opened object, never a symlink target substituted at this path.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let expectedType = mode_t(directory ? S_IFDIR : S_IFREG)
        guard metadata.st_mode & mode_t(S_IFMT) == expectedType else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        // Mode bits alone do not remove inherited grants on macOS.
        guard let acl = acl_init(0) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if acl_set_fd(descriptor, acl) != 0 {
            let code = errno
            // Filesystems without extended ACLs can still enforce POSIX permissions.
            guard code == ENOTSUP else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        let permissions: mode_t = directory ? 0o700 : 0o600
        guard fchmod(descriptor, permissions) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard metadata.st_mode & 0o777 == permissions else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
    }
    private static func nameLimit(in directory: URL) throws -> Int {
        errno = 0
        let limit = pathconf(directory.path, _PC_NAME_MAX)
        let code = errno
        if limit < 0 && code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        return limit > 0 ? Int(limit) : 255
    }
    private static func numberedDestination(_ destination: URL, number: Int, nameLimit: Int) throws -> URL {
        let suffix = (number == 1 ? "" : " (\(number))") + "." + destination.pathExtension
        let budget = nameLimit - suffix.utf8.count
        guard budget > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG)) }
        let base = destination.deletingPathExtension().lastPathComponent
        var stem = ""
        var bytes = 0
        var units = 0
        // Honor both byte and UTF-16 limits conservatively across destination filesystems.
        // Keep whole characters, including composed characters and emoji, where possible.
        for character in base {
            let part = String(character)
            guard bytes + part.utf8.count <= budget, units + part.utf16.count <= budget else { break }
            stem += part
            bytes += part.utf8.count
            units += part.utf16.count
        }
        // One unusually long composed character may exceed the entire budget.
        // A scalar prefix still forms valid Unicode and guarantees progress on collisions.
        if stem.isEmpty {
            for scalar in base.unicodeScalars {
                let part = String(scalar)
                guard bytes + part.utf8.count <= budget, units + part.utf16.count <= budget else { break }
                stem += part
                bytes += part.utf8.count
                units += part.utf16.count
            }
        }
        if stem != base {
            while stem.count > 1 && (stem.hasSuffix(".") || stem.hasSuffix(" ")) { stem.removeLast() }
        }
        guard !stem.isEmpty else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG)) }
        return destination.deletingLastPathComponent().appendingPathComponent(stem + suffix)
    }
    public func executeBesideInput(snapshot: InputSnapshot, preset: CompressionPreset,
                                   progress: (ArchiveStage, Double?) -> Void = { _, _ in }) throws -> ArchiveResult {
        let destination = snapshot.input.deletingLastPathComponent()
            .appendingPathComponent(snapshot.input.lastPathComponent + ".7z")
        return try execute(snapshot: snapshot, preset: preset, destination: destination,
                           numberOnCollision: true, progress: progress)
    }
    public func execute(snapshot: InputSnapshot, preset: CompressionPreset, destination: URL,
                        numberOnCollision: Bool = false,
                        progress: (ArchiveStage, Double?) -> Void = { _, _ in }) throws -> ArchiveResult {
        let fm = FileManager.default
        let start = Date()
        let nameLimit = numberOnCollision ? try Self.nameLimit(in: destination.deletingLastPathComponent()) : 0
        let initialDestination = numberOnCollision
            ? try Self.numberedDestination(destination, number: 1, nameLimit: nameLimit) : destination
        try Self.validateDestination(initialDestination, source: snapshot.input, requireAvailable: !numberOnCollision)
        guard fm.isExecutableFile(atPath: engine.path) else { throw KkukError.message("7-Zip 엔진을 찾을 수 없습니다. 앱을 다시 빌드해 주세요.") }
        guard preset.estimatedMemoryBytes <= MemoryBudget.current() else {
            throw KkukError.message("지금은 압축에 사용할 메모리 여유가 부족합니다. 다른 작업을 닫은 뒤 파일이나 폴더를 다시 선택해 주세요.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".kkuk-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        try Self.restrictAccess(to: temporary, directory: true)
        let archive = temporary.appendingPathComponent("result.7z")
        // Explicit solid limit covers this input; two threads avoid independent block parallelism.
        let solidBytes = max(snapshot.totalBytes + 1_073_741_824, 1_073_741_824)
        var exclusions: [String] = []
        if !snapshot.excludedPaths.isEmpty {
            // Keep the process argument count constant even for thousands of sockets.
            // Outer quotes preserve leading/trailing spaces and literal quotes in names.
            let list = temporary.appendingPathComponent("excluded-paths.txt")
            let contents = snapshot.excludedPaths.map { "\"" + $0 + "\"" }.joined(separator: "\n") + "\n"
            try contents.write(to: list, atomically: false, encoding: .utf8)
            try Self.restrictAccess(to: list, directory: false)
            exclusions = ["-scsUTF-8", "-x@" + list.path]
        }
        let args = ["a", "-t7z", "-m0=lzma2", "-mx=9", "-md=\(preset.dictionaryMiB)m",
                    "-mfb=273", "-ms=\(solidBytes)b", "-mmt=2", "-mqs=on", "-sse", "-snl", "-ssp", "-spd",
                    "-sccUTF-8", "-bb0", "-bsp1", "-y"] + exclusions + ["--", archive.path, "./" + snapshot.input.lastPathComponent]
        progress(.compressing, 0)
        var progressParser = CompressionProgressParser()
        _ = try runner.run(executable: engine, arguments: args, directory: snapshot.input.deletingLastPathComponent()) { chunk in
            if let value = progressParser.consume(chunk) { progress(.compressing, value) }
        }
        progress(.verifying, nil)
        _ = try runner.run(executable: engine, arguments: ["t", "-sccUTF-8", "-bsp0", "--", archive.path])
        progress(.checkingContents, nil)
        let listing = try runner.run(executable: engine, arguments: ["l", "-slt", "-ba", "-sccUTF-8", "--", archive.path])
        let actualPaths = Self.listedPaths(listing)
        guard actualPaths == snapshot.archivePaths else {
            let missing = snapshot.archivePaths.subtracting(actualPaths).sorted().prefix(3).joined(separator: "\n")
            let extra = actualPaths.subtracting(snapshot.archivePaths).sorted().prefix(3).joined(separator: "\n")
            throw KkukError.message("압축 파일에 포함된 항목이 원본 목록과 다릅니다. 결과 파일을 확정하지 않았습니다.\n누락: \(missing)\n추가: \(extra)")
        }
        let current = try InputScanner.scan(snapshot.input) { try self.runner.checkCancellation() }
        guard current.entries == snapshot.entries else {
            throw KkukError.message("압축하는 동안 원본 파일이나 폴더가 변경됐습니다. 작업을 마친 뒤 다시 압축해 주세요.")
        }
        try runner.checkCancellation()
        if !numberOnCollision { try Self.validateDestination(destination, source: snapshot.input) }
        // Establish private permissions before publishing the file with an exclusive rename.
        try Self.restrictAccess(to: archive, directory: false)
        var finalURL = initialDestination
        var number = 1
        while true {
            try runner.checkCancellation()
            // Exclusive rename commits atomically without overwriting even a dangling symlink.
            if renamex_np(archive.path, finalURL.path, UInt32(RENAME_EXCL)) == 0 { break }
            let code = errno
            guard numberOnCollision && code == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            number += 1
            // Always shorten the original base again, reserving space for the full suffix.
            finalURL = try Self.numberedDestination(destination, number: number, nameLimit: nameLimit)
        }
        let size = (try fm.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        progress(.finished, 1)
        return ArchiveResult(url: finalURL, originalBytes: snapshot.totalBytes, archiveBytes: size,
                             elapsed: Date().timeIntervalSince(start), preset: preset)
    }
}
