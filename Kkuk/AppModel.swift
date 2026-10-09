import AppKit
import Darwin
import SwiftUI
import KkukCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedInputCount = 1
    @Published var selectedInput: URL?
    @Published var selectedIsDirectory = false
    @Published var scanning = false
    @Published var showsScanGauge = false
    private var scanGaugeTask: DispatchWorkItem?
    @Published var snapshot: InputSnapshot?
    @Published var preset: CompressionPreset?
    @Published var busy = false
    @Published var acceptsNewInput = true
    @Published var status = ""
    var detail: String { result.map(Self.resultDetail) ?? "" }
    @Published var progress: Double?
    @Published var error: String?
    @Published var result: ArchiveResult?
    private var job: ArchiveJob?
    private var cancellationRequested = false
    @Published private(set) var pendingFinderRequests: [[URL]] = []
    var onFinderTaskStarted: (() -> Void)?
    var onTaskFinished: (() -> Void)?
    var onArchiveSucceeded: (() -> Void)?
    let completionSound = CompletionSoundPlayer()

    var engine: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
    }
    // Only URLs wait in the queue. Scan and choose a memory budget at execution time.
    @discardableResult
    func enqueueFinderInputs(_ inputs: [URL]) -> Bool {
        guard acceptsNewInput, !inputs.isEmpty, inputs.allSatisfy(\.isFileURL) else { return false }
        pendingFinderRequests.append(inputs)
        if !busy, error == nil { resumeFinderQueue() }
        return true
    }
    @discardableResult
    func resumeFinderQueue() -> Bool {
        guard !busy, acceptsNewInput, !pendingFinderRequests.isEmpty else { return false }
        let inputs = pendingFinderRequests.removeFirst()
        analyzeInputs(inputs, compressWhenReady: true)
        onFinderTaskStarted?()
        return true
    }
    func discardFinderQueue() { pendingFinderRequests.removeAll() }

    var canChooseInput: Bool { !busy && acceptsNewInput && pendingFinderRequests.isEmpty }

    func chooseInput() {
        guard canChooseInput else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose a file or folder to compress")
        panel.prompt = L10n.text("Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { analyze(url) }
    }
    func analyze(_ folder: URL, compressWhenReady: Bool = false) {
        guard canChooseInput else { return }
        analyzeInputs([folder], compressWhenReady: compressWhenReady)
    }
    func analyzeInputs(_ inputs: [URL], compressWhenReady: Bool = false) {
        guard !busy, acceptsNewInput, let folder = inputs.first else { return }
        selectedInputCount = Set(inputs).count
        selectedInput = folder
        selectedIsDirectory = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        scanning = true
        showsScanGauge = false
        scanGaugeTask?.cancel()
        let gaugeTask = DispatchWorkItem { [weak self] in
            guard let self, self.scanning else { return }
            self.showsScanGauge = true
        }
        scanGaugeTask = gaugeTask
        // Six frames at 60 Hz; delay only the gauge, never the input metadata.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: gaugeTask)
        busy = true; error = nil; result = nil; snapshot = nil; preset = nil
        status = ""; progress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scanned = try InputScanner.scanInputs(inputs)
                let selected = CompressionPreset.select(inputBytes: scanned.totalBytes, memoryBudgetBytes: MemoryBudget.current())
                DispatchQueue.main.async {
                    self.scanGaugeTask?.cancel(); self.scanGaugeTask = nil
                    self.showsScanGauge = false
                    self.snapshot = scanned; self.preset = selected; self.busy = false; self.scanning = false
                    self.selectedInput = scanned.input; self.selectedIsDirectory = scanned.isDirectory
                    self.selectedInputCount = scanned.inputs.count
                    self.status = L10n.text("Ready to compress")
                    if compressWhenReady { self.start(inputs: scanned.inputs, freshSnapshot: scanned) }
                }
            } catch {
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }
    func start() {
        guard !busy, let inputs = snapshot?.inputs else { return }
        start(inputs: inputs)
    }
    private func start(inputs: [URL], freshSnapshot: InputSnapshot? = nil) {
        guard !busy else { return }
        let job = ArchiveJob(engine: engine)
        self.job = job
        cancellationRequested = false
        busy = true; error = nil; result = nil; progress = nil
        status = L10n.text("Preparing compression")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try job.runner.checkCancellation()
                // Automatic Finder jobs just scanned; manual starts need fresh metadata.
                let current = try freshSnapshot ?? InputScanner.scanInputs(inputs) { try job.runner.checkCancellation() }
                let preset = CompressionPreset.select(inputBytes: current.totalBytes, memoryBudgetBytes: MemoryBudget.current())
                DispatchQueue.main.async { self.snapshot = current; self.preset = preset }
                let result = try job.executeBesideInput(snapshot: current, preset: preset) { stage, value in
                    DispatchQueue.main.async {
                        guard self.job === job, !self.cancellationRequested else { return }
                        self.progress = value
                        switch stage {
                        case .compressing: self.status = L10n.text("Kkuk is compressing")
                        case .verifying: self.status = L10n.text("Verifying archive")
                        case .checkingContents: self.status = L10n.text("Checking archive contents")
                        case .finished: break
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.cancellationRequested = false
                    self.result = result; self.busy = false; self.job = nil; self.progress = nil
                    self.status = L10n.text("Compression and verification complete")
                    self.onTaskFinished?()
                    if self.resumeFinderQueue() { return }
                    self.completionSound.play()
                    self.onArchiveSucceeded?()
                }
            } catch {
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }
    func cancel() {
        guard let job, !cancellationRequested else { return }
        cancellationRequested = true
        status = L10n.text("Canceling")
        job.cancel()
    }
    func fail(_ failure: Error) {
        scanGaugeTask?.cancel(); scanGaugeTask = nil
        showsScanGauge = false
        busy = false; scanning = false; progress = nil; job = nil
        cancellationRequested = false
        if let kkukError = failure as? KkukError, case .cancelled = kkukError {
            error = nil; status = L10n.text("Canceled")
        } else {
            error = Self.userFacingError(failure); status = L10n.text("Could not compress.")
        }
        onTaskFinished?()
    }
    static func userFacingError(_ failure: Error) -> String {
        // Keep engine transcripts, file paths and error codes out of the interface.
        if let error = failure as? KkukError {
            let key: String
            switch error {
            case .inputMissing: key = "Choose a file or folder to compress."
            case .differentInputLocations: key = "Choose items in the same folder."
            case .systemRoot: key = "Choose a file or folder instead of the system root."
            case .unsupportedFileName: key = "Rename files containing line breaks, then choose the input again."
            case .unsupportedInput: key = "Choose a regular file or folder."
            case .engineUnavailable: key = "Reinstall the app, then try again."
            case .unsafeDestination: key = "Move the source to a private folder, then try again."
            case .insufficientMemory: key = "Close other apps, then try again."
            case .sourceChanged: key = "Finish making changes to the source, then compress again."
            case .archiveContentsMismatch: key = "Choose the source again, then compress."
            case .engineFailed: key = "Check the source and destination, then try again."
            case .cancelled: key = "Canceled"
            }
            return L10n.text(key)
        }
        let error = failure as NSError
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ENOSPC, EDQUOT: return L10n.text("Free up disk space, then try again.")
            case EACCES, EPERM: return L10n.text("Check access permissions for the source and destination.")
            case ENOENT, ENOTDIR: return L10n.text("Choose the source file or folder again.")
            default: break
            }
        }
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteOutOfSpace: return L10n.text("Free up disk space, then try again.")
            case .fileReadNoPermission, .fileWriteNoPermission: return L10n.text("Check access permissions for the source and destination.")
            case .fileNoSuchFile, .fileReadNoSuchFile: return L10n.text("Choose the source file or folder again.")
            default: break
            }
        }
        return L10n.text("Check the source and destination, then try again.")
    }
    func reveal() {
        if let result { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
    }
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    static func resultDetail(_ result: ArchiveResult) -> String {
        let change: String
        if result.originalBytes == 0 {
            change = L10n.text("Empty item archived")
        } else if result.archiveBytes > result.originalBytes {
            change = L10n.text("Size increased slightly")
        } else {
            let percent = (1 - Double(result.archiveBytes) / Double(result.originalBytes)) * 100
            change = L10n.format("%.1f%% smaller", percent)
        }
        return "\(bytes(result.originalBytes)) → \(bytes(result.archiveBytes)) · \(change)"
    }
    var canCancel: Bool { job != nil }
}
