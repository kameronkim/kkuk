import Foundation
import Darwin

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
                    output: (Data) -> Void = { _ in }) throws {
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
            if transcript.count > 8192 {
                transcript = Data(transcript.suffix(8192))
            }
            output(chunk)
        }
        process.waitUntilExit()
        try checkCancellation()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: transcript, as: UTF8.self)
            throw KkukError.engineFailed(status: process.terminationStatus, details: String(text.suffix(1400)))
        }
    }
}

