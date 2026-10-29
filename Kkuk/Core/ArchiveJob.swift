import Foundation
import Darwin

public enum ArchiveStage: Equatable, Sendable { case compressing, verifying, checkingContents, finished }
public struct ArchiveResult: Sendable {
    public let url: URL
    public let originalBytes: UInt64
    public let archiveBytes: UInt64
}

public final class ArchiveJob: Sendable {
    public let runner = ProcessRunner()
    public let engine: URL
    public init(engine: URL) { self.engine = engine }
    public func cancel() { runner.cancel() }
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
        let parentURL = snapshot.input.deletingLastPathComponent()
        let base = snapshot.inputs.count == 1 ? snapshot.input.lastPathComponent : parentURL.lastPathComponent
        let destination = parentURL.appendingPathComponent((base.isEmpty ? "Archive" : base) + ".7z")
        let fm = FileManager.default
        let parent = try PinnedDestinationDirectory(destination.deletingLastPathComponent())
        let nameLimit = try ArchiveFileAccess.nameLimit(directoryDescriptor: parent.descriptor)
        let initialDestination = try Self.numberedDestination(destination, number: 1, nameLimit: nameLimit)
        guard fm.isExecutableFile(atPath: engine.path) else { throw KkukError.engineUnavailable }
        guard preset.estimatedMemoryBytes <= MemoryBudget.current() else {
            throw KkukError.insufficientMemory
        }
        let temporaryName = ".kkuk-\(UUID().uuidString)"
        let temporary = parent.url.appendingPathComponent(temporaryName, isDirectory: true)
        guard mkdirat(parent.descriptor, temporaryName, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let temporaryDescriptor = openat(parent.descriptor, temporaryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard temporaryDescriptor >= 0 else {
            let code = errno
            _ = unlinkat(parent.descriptor, temporaryName, AT_REMOVEDIR)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { parent.removeTemporary(temporaryDescriptor, name: temporaryName); close(temporaryDescriptor) }
        try ArchiveFileAccess.restrictAccess(descriptor: temporaryDescriptor, directory: true)
        try parent.verify()
        let archive = temporary.appendingPathComponent("result.7z")
        // Explicit solid limit covers this input; two threads avoid independent block parallelism.
        let solidBytes = max(snapshot.totalBytes + 1_073_741_824, 1_073_741_824)
        var exclusions: [String] = []
        if !snapshot.excludedPaths.isEmpty {
            // Keep the process argument count constant even for thousands of sockets.
            // Outer quotes preserve leading/trailing spaces and literal quotes in names.
            let list = temporary.appendingPathComponent("excluded-paths.txt")
            let contents = snapshot.excludedPaths.map { "\"" + $0 + "\"" }.joined(separator: "\n") + "\n"
            try ArchiveFileAccess.writePrivateList(contents, directoryDescriptor: temporaryDescriptor)
            exclusions = ["-x@" + list.path]
        }
        var inclusions: [String] = []
        // Root entries retain the filesystem spelling; URL components may normalize it.
        var selectionArguments = snapshot.entries.filter { !$0.path.contains("/") }.map { "./" + $0.path }
        if selectionArguments.contains(where: { !$0.contains("\r") }) {
            // A UTF-8 list preserves the on-disk Unicode spelling: Foundation can
            // normalize process arguments. It also avoids command-line size limits.
            // Icon\r cannot go through a line-delimited list. At most one exists
            // among selections in the same parent, so pass that name as an argument.
            let listedSelections = selectionArguments.filter { !$0.contains("\r") }
            let contents = listedSelections.map { "\"" + $0 + "\"" }.joined(separator: "\n") + "\n"
            try ArchiveFileAccess.writePrivateList(contents, directoryDescriptor: temporaryDescriptor, name: "selected-paths.txt")
            inclusions = ["-i@" + temporary.appendingPathComponent("selected-paths.txt").path]
            selectionArguments = selectionArguments.filter { $0.contains("\r") }
        }
        let args = ["a", "-t7z", "-m0=lzma2", "-mx=9", "-md=\(preset.dictionaryMiB)m",
                    "-mfb=273", "-ms=\(solidBytes)b", "-mmt=2", "-mqs=on", "-sse", "-snl", "-ssp", "-spd",
                    "-sccUTF-8", "-scsUTF-8", "-bb0", "-bsp1", "-y"] + exclusions + inclusions + ["--", archive.path] + selectionArguments
        progress(.compressing, 0)
        try parent.verify()
        var progressParser = CompressionProgressParser()
        try runner.run(executable: engine, arguments: args, directory: snapshot.input.deletingLastPathComponent(), output: { chunk in
            if let value = progressParser.consume(chunk) { progress(.compressing, value) }
        })
        progress(.verifying, nil)
        try parent.verify()
        try runner.run(executable: engine, arguments: ["t", "-spd", "-sccUTF-8", "-bsp0", "--", archive.path])
        progress(.checkingContents, nil)
        try parent.verify()
        var pathParser = ArchivePathParser()
        try runner.run(executable: engine, arguments: ["l", "-slt", "-ba", "-spd", "-sccUTF-8", "--", archive.path],
                           output: { pathParser.consume($0) })
        let actualPaths = pathParser.finish()
        let expectedPaths = snapshot.archivePaths
        guard actualPaths == expectedPaths else {
            let missing = Array(expectedPaths.subtracting(actualPaths).sorted().prefix(3))
            let extra = Array(actualPaths.subtracting(expectedPaths).sorted().prefix(3))
            throw KkukError.archiveContentsMismatch(missing: missing, extra: extra)
        }
        try parent.verify()
        let current = try InputScanner.scanInputs(snapshot.inputs) { try self.runner.checkCancellation() }
        guard current.entries == snapshot.entries else {
            throw KkukError.sourceChanged
        }
        try runner.checkCancellation()
        // Establish private permissions before publishing the file with an exclusive rename.
        try parent.verify()
        let archiveDescriptor = openat(temporaryDescriptor, "result.7z", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard archiveDescriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(archiveDescriptor) }
        try ArchiveFileAccess.restrictAccess(descriptor: archiveDescriptor, directory: false)
        var archiveMetadata = stat()
        guard fstat(archiveDescriptor, &archiveMetadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let size = UInt64(max(0, archiveMetadata.st_size))
        var finalURL = initialDestination
        var number = 1
        while true {
            try runner.checkCancellation()
            // Exclusive rename commits atomically without overwriting even a dangling symlink.
            try parent.verify()
            if renameatx_np(temporaryDescriptor, "result.7z", parent.descriptor, finalURL.lastPathComponent, UInt32(RENAME_EXCL)) == 0 { break }
            let code = errno
            guard code == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            number += 1
            // Always shorten the original base again, reserving space for the full suffix.
            finalURL = try Self.numberedDestination(destination, number: number, nameLimit: nameLimit)
        }
        progress(.finished, 1)
        return ArchiveResult(url: finalURL, originalBytes: snapshot.totalBytes, archiveBytes: size)
    }
}
