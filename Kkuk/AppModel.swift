import AppKit
import Combine
import KkukCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var selectedInputCount = 1
    @Published private(set) var selectedInput: URL?
    @Published private(set) var selectedIsDirectory = false
    @Published private(set) var scanning = false
    @Published private(set) var showsScanGauge = false
    private var scanGaugeTask: DispatchWorkItem?
    private var scanRunner: ProcessRunner?
    private var continuesQueueAfterCancellation = false
    private let inputSelection = InputSelectionController()
    @Published private(set) var snapshot: InputSnapshot?
    @Published private(set) var preset: CompressionPreset?
    @Published private(set) var busy = false
    @Published var acceptsNewInput = true
    @Published private(set) var status = ""
    var detail: String { result.map(TaskPresentation.resultDetail) ?? "" }
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var result: ArchiveResult?
    private var job: ArchiveJob?
    private var cancellationRequested = false
    @Published private var finderSession = FinderTaskSession()
    var pendingFinderRequests: [FinderCompressionRequest] { finderSession.pending }
    var failedFinderRequests: [FailedFinderRequest] { finderSession.failures }
    private let memoryBudget: @Sendable () -> UInt64
    let engine: URL
    var onFinderTaskStarted: (() -> Void)?
    var onTaskFinished: (() -> Void)?
    var onArchiveSucceeded: (() -> Void)?
    let completionSound = CompletionSoundPlayer()

    init(engine: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz"),
         memoryBudget: @escaping @Sendable () -> UInt64 = { MemoryBudget.current() }) {
        self.engine = engine
        self.memoryBudget = memoryBudget
    }
    var hasFinderTasks: Bool { finderSession.hasTasks }
    var canRetryFailedRequest: Bool { !busy && acceptsNewInput }
    var canFinishSession: Bool {
        finderSession.canFinish(busy: busy, acceptsInput: acceptsNewInput, hasResult: result != nil)
    }
    @discardableResult
    func retryFailedFinderRequest(id: UUID) -> Bool {
        guard canRetryFailedRequest, let request = finderSession.retryRequest(id: id) else { return false }
        // Keep the failure visible until this exact request succeeds. Start with URLs,
        // never the old snapshot or preset, so source and memory are checked again.
        startFinderRequest(request)
        return true
    }
    func canDismissFailedFinderRequest(id: UUID) -> Bool {
        acceptsNewInput && finderSession.canDismiss(id: id)
    }
    @discardableResult
    func dismissFailedFinderRequest(id: UUID) -> Bool {
        guard acceptsNewInput, finderSession.dismiss(id: id) else { return false }
        // This only forgets the selected session record. The shared completion guard
        // still requires no current/queued work, no failures, and a successful result.
        finishCompletedWork()
        return true
    }
    // Only URLs wait in the queue. Scan and choose a memory budget at execution time.
    @discardableResult
    func enqueueFinderInputs(_ inputs: [URL]) -> Bool {
        guard acceptsNewInput, !inputs.isEmpty, inputs.allSatisfy(\.isFileURL) else { return false }
        inputSelection.invalidatePendingDrop()
        finderSession.enqueue(inputs)
        if !busy, error == nil { resumeFinderQueue() }
        return true
    }
    @discardableResult
    func resumeFinderQueue() -> Bool {
        guard !busy, acceptsNewInput, let request = finderSession.takeNext() else { return false }
        startFinderRequest(request)
        return true
    }
    private func startFinderRequest(_ request: FinderCompressionRequest) {
        finderSession.begin(request)
        analyzeInputs(request.inputs, compressWhenReady: true)
        onFinderTaskStarted?()
    }
    func removeFinderRequest(id: UUID) {
        guard acceptsNewInput else { return }
        finderSession.removePending(id: id)
    }
    func discardFinderQueue() { finderSession.discardPending() }

    var canChooseInput: Bool { !busy && acceptsNewInput && pendingFinderRequests.isEmpty }

    @discardableResult
    func loadDroppedInput(_ provider: NSItemProvider) -> Bool {
        guard canChooseInput else { return false }
        inputSelection.load(provider) { [weak self] url in self?.analyze(url) }
        return true
    }
    @discardableResult
    func chooseInput() -> Bool {
        guard canChooseInput else { return false }
        guard let url = inputSelection.choose(), canChooseInput else { return false }
        analyze(url)
        return true
    }
    func analyze(_ input: URL) {
        guard canChooseInput else { return }
        analyzeInputs([input], compressWhenReady: false)
    }
    private func analyzeInputs(_ inputs: [URL], compressWhenReady: Bool) {
        guard !busy, acceptsNewInput, let folder = inputs.first else { return }
        inputSelection.invalidatePendingDrop()
        let scanRunner = ProcessRunner()
        self.scanRunner = scanRunner
        cancellationRequested = false
        continuesQueueAfterCancellation = false
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
        let memoryBudget = self.memoryBudget
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scanned = try InputScanner.scanInputs(inputs) { try scanRunner.checkCancellation() }
                let selected = CompressionPreset.select(inputBytes: scanned.totalBytes, memoryBudgetBytes: memoryBudget())
                DispatchQueue.main.async {
                    guard !self.cancellationRequested else { self.fail(KkukError.cancelled); return }
                    self.scanRunner = nil
                    self.scanGaugeTask?.cancel(); self.scanGaugeTask = nil
                    self.showsScanGauge = false
                    self.snapshot = scanned; self.preset = selected; self.busy = false; self.scanning = false
                    self.selectedInput = scanned.input; self.selectedIsDirectory = scanned.isDirectory
                    self.selectedInputCount = scanned.inputs.count
                    self.status = L10n.text("Ready to compress")
                    if compressWhenReady { self.start(inputs: scanned.inputs, freshSnapshot: scanned) }
                    else { self.resumeFinderQueue() }
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
        inputSelection.invalidatePendingDrop()
        let job = ArchiveJob(engine: engine)
        self.job = job
        cancellationRequested = false
        continuesQueueAfterCancellation = false
        busy = true; error = nil; result = nil; progress = nil
        status = L10n.text("Preparing compression")
        let memoryBudget = self.memoryBudget
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try job.runner.checkCancellation()
                // Automatic Finder jobs just scanned; manual starts need fresh metadata.
                let current = try freshSnapshot ?? InputScanner.scanInputs(inputs) { try job.runner.checkCancellation() }
                let preset = CompressionPreset.select(inputBytes: current.totalBytes, memoryBudgetBytes: memoryBudget())
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
                    self.continuesQueueAfterCancellation = false
                    self.finderSession.succeed()
                    self.result = result; self.busy = false; self.job = nil; self.progress = nil
                    self.status = L10n.text("Compression and verification complete")
                    self.onTaskFinished?()
                    if self.resumeFinderQueue() { return }
                    self.finishCompletedWork()
                }
            } catch {
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }
    func finishCompletedWork() {
        guard canFinishSession else { return }
        completionSound.play()
        onArchiveSucceeded?()
    }
    var isCancelling: Bool { cancellationRequested }
    var canCancelCurrentTask: Bool { acceptsNewInput && canCancel && !cancellationRequested }
    func cancelCurrentTask() {
        guard canCancelCurrentTask else { return }
        continuesQueueAfterCancellation = true
        cancel()
    }
    // Application termination uses this path and never opts into continuing the queue.
    func cancel() {
        guard canCancel, !cancellationRequested else { return }
        cancellationRequested = true
        status = L10n.text("Canceling")
        job?.cancel()
        scanRunner?.cancel()
    }
    func fail(_ failure: Error) {
        scanGaugeTask?.cancel(); scanGaugeTask = nil
        showsScanGauge = false
        busy = false; scanning = false; progress = nil; job = nil; scanRunner = nil
        let continueQueue = continuesQueueAfterCancellation
        continuesQueueAfterCancellation = false
        cancellationRequested = false
        let wasCancelled: Bool
        if let kkukError = failure as? KkukError, case .cancelled = kkukError {
            wasCancelled = true
            error = nil; status = L10n.text("Canceled")
        } else {
            wasCancelled = false
            let reason = TaskPresentation.userFacingError(failure)
            error = reason; status = L10n.text("Could not compress.")
        }
        finderSession.fail(reason: wasCancelled ? nil : error)
        onTaskFinished?()
        // ArchiveJob has already cleaned its temporary directory before reaching here.
        if wasCancelled && continueQueue { resumeFinderQueue() }
    }
    func reveal() {
        if let result { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
    }
    var canCancel: Bool { job != nil || scanRunner != nil }
}
