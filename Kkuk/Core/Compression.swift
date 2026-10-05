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
}

public struct InputSnapshot: Sendable {
    public let input: URL
    public let entries: [InputEntry]
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
        func visit(_ url: URL, path: String) throws {
            try checkCancellation()
            guard !path.contains("\n"), !path.contains("\r") else {
                throw KkukError.message("줄바꿈이 포함된 파일 이름은 현재 지원하지 않습니다: \(url.lastPathComponent)")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular || type == .typeSymbolicLink else {
                throw KkukError.message("일반 파일·폴더·심볼릭 링크만 압축할 수 있습니다: \(path)")
            }
            let link = type == .typeSymbolicLink ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            let entry = InputEntry(path: path,
                                   size: type == .typeDirectory ? 0 : (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                                   modified: attributes[.modificationDate] as? Date,
                                   linkTarget: link, isDirectory: type == .typeDirectory)
            entries.append(entry)
            if entry.isDirectory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, path: path + "/" + child.lastPathComponent)
                }
            }
        }
        try visit(folder, path: folder.lastPathComponent)
        return InputSnapshot(input: folder, entries: entries.sorted { $0.path < $1.path })
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
    private var cancelled = false
    public init() {}
    public func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw KkukError.cancelled }
    }
    public func cancel() {
        lock.lock(); cancelled = true; let process = active; lock.unlock()
        if let process, process.isRunning {
            process.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
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
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
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
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? pipe.fileHandleForReading.close()
            lock.lock(); active = nil; lock.unlock()
        }
        var transcript = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
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
    public static func validateDestination(_ destination: URL, source: URL) throws {
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        guard parent.path != root.path, !parent.path.hasPrefix(root.path + "/") else {
            throw KkukError.message("압축 결과는 원본 폴더 바깥에 저장해 주세요.")
        }
        guard destination.pathExtension.lowercased() == "7z" else { throw KkukError.message("저장 파일의 확장자는 .7z여야 합니다.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw KkukError.message("같은 이름의 파일이 있습니다. 다른 이름으로 저장해 주세요.")
        }
    }
    public static func listedPaths(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: .newlines).compactMap {
            $0.hasPrefix("Path = ") ? String($0.dropFirst(7)) : nil
        })
    }
    public func execute(snapshot: InputSnapshot, preset: CompressionPreset, destination: URL,
                        progress: (ArchiveStage, Double?) -> Void = { _, _ in }) throws -> ArchiveResult {
        let fm = FileManager.default
        let start = Date()
        try Self.validateDestination(destination, source: snapshot.input)
        guard fm.isExecutableFile(atPath: engine.path) else { throw KkukError.message("7-Zip 엔진을 찾을 수 없습니다. 앱을 다시 빌드해 주세요.") }
        guard preset.estimatedMemoryBytes <= MemoryBudget.current() else {
            throw KkukError.message("지금은 압축에 사용할 메모리 여유가 부족합니다. 다른 작업을 닫은 뒤 파일이나 폴더를 다시 선택해 주세요.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".kkuk-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("result.7z")
        // Explicit solid limit covers this input; two threads avoid independent block parallelism.
        let solidBytes = max(snapshot.totalBytes + 1_073_741_824, 1_073_741_824)
        let args = ["a", "-t7z", "-m0=lzma2", "-mx=9", "-md=\(preset.dictionaryMiB)m",
                    "-mfb=273", "-ms=\(solidBytes)b", "-mmt=2", "-mqs=on", "-sse", "-snl", "-ssp", "-spd",
                    "-sccUTF-8", "-bb0", "-bsp1", "-y", "--", archive.path, "./" + snapshot.input.lastPathComponent]
        progress(.compressing, 0)
        _ = try runner.run(executable: engine, arguments: args, directory: snapshot.input.deletingLastPathComponent()) { chunk in
            let pattern = #"(?:^|[\s\u0008])(\d{1,3})%"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.matches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)).last,
               let range = Range(match.range(at: 1), in: chunk), let percent = Double(chunk[range]) {
                progress(.compressing, min(percent / 100, 1))
            }
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
        try Self.validateDestination(destination, source: snapshot.input)
        try fm.moveItem(at: archive, to: destination)
        let size = (try fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.uint64Value ?? 0
        progress(.finished, 1)
        return ArchiveResult(url: destination, originalBytes: snapshot.totalBytes, archiveBytes: size,
                             elapsed: Date().timeIntervalSince(start), preset: preset)
    }
}
