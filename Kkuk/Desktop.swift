import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import KkukCore

@MainActor
final class AppModel: ObservableObject {
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
    @Published var detail = ""
    @Published var progress: Double?
    @Published var error: String?
    @Published var result: ArchiveResult?
    private var job: ArchiveJob?
    private var cancellationRequested = false
    var onTaskFinished: (() -> Void)?
    var onArchiveSucceeded: (() -> Void)?
    private var completionSound: NSSound?
    private(set) var completionSoundEndsAt = Date.distantPast

    var engine: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
    }
    func chooseInput() {
        guard !busy, acceptsNewInput else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose a file or folder to compress")
        panel.prompt = L10n.text("Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { analyze(url) }
    }
    func analyze(_ folder: URL, compressWhenReady: Bool = false) {
        guard !busy, acceptsNewInput else { return }
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
        status = ""; detail = ""; progress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scanned = try InputScanner.scan(folder)
                let selected = CompressionPreset.select(inputBytes: scanned.totalBytes, memoryBudgetBytes: MemoryBudget.current())
                DispatchQueue.main.async {
                    self.scanGaugeTask?.cancel(); self.scanGaugeTask = nil
                    self.showsScanGauge = false
                    self.snapshot = scanned; self.preset = selected; self.busy = false; self.scanning = false
                    self.selectedInput = scanned.input; self.selectedIsDirectory = scanned.isDirectory
                    self.status = L10n.text("Ready to compress")
                    self.detail = ""
                    if compressWhenReady { self.start() }
                }
            } catch {
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }
    func start() {
        guard !busy, let snapshot else { return }
        // Rescan immediately before execution instead of relying on stale selection metadata.
        let job = ArchiveJob(engine: engine)
        self.job = job
        cancellationRequested = false
        busy = true; error = nil; result = nil; progress = nil
        status = L10n.text("Preparing compression"); detail = ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let current = try InputScanner.scan(snapshot.input) { try job.runner.checkCancellation() }
                let preset = CompressionPreset.select(inputBytes: current.totalBytes, memoryBudgetBytes: MemoryBudget.current())
                DispatchQueue.main.async { self.snapshot = current; self.preset = preset }
                let result = try job.executeBesideInput(snapshot: current, preset: preset) { stage, value in
                    DispatchQueue.main.async {
                        guard self.job === job, !self.cancellationRequested else { return }
                        self.progress = value
                        switch stage {
                        case .compressing: self.status = L10n.text("Kkuk is compressing"); self.detail = ""
                        case .verifying: self.status = L10n.text("Verifying archive"); self.detail = ""
                        case .checkingContents: self.status = L10n.text("Checking archive contents"); self.detail = ""
                        case .finished: break
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.cancellationRequested = false
                    self.result = result; self.busy = false; self.job = nil; self.progress = nil
                    self.status = L10n.text("Compression and verification complete")
                    self.detail = Self.resultDetail(result)
                    if let sound = NSSound(named: NSSound.Name("Glass")), sound.play() {
                        self.completionSound = sound
                        self.completionSoundEndsAt = Date().addingTimeInterval(sound.duration)
                    }
                    self.onTaskFinished?()
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
        status = L10n.text("Canceling"); detail = ""
        job.cancel()
    }
    func fail(_ failure: Error) {
        scanGaugeTask?.cancel(); scanGaugeTask = nil
        showsScanGauge = false
        busy = false; scanning = false; progress = nil; job = nil
        cancellationRequested = false
        if let kkukError = failure as? KkukError, case .cancelled = kkukError {
            error = nil; status = L10n.text("Canceled"); detail = ""
        } else {
            error = Self.userFacingError(failure); status = L10n.text("Could not compress."); detail = ""
        }
        onTaskFinished?()
    }
    static func userFacingError(_ failure: Error) -> String {
        // Keep engine transcripts, file paths and error codes out of the interface.
        if let error = failure as? KkukError {
            let key: String
            switch error {
            case .inputMissing: key = "Choose a file or folder to compress."
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

enum KkukTheme {
    static let background = Color(red: 18 / 255, green: 25 / 255, blue: 33 / 255)
    static let text = Color(red: 243 / 255, green: 247 / 255, blue: 252 / 255)
    static let secondary = Color(red: 166 / 255, green: 181 / 255, blue: 199 / 255)
    static let line = Color(red: 48 / 255, green: 65 / 255, blue: 85 / 255)
    static let accent = Color(red: 117 / 255, green: 185 / 255, blue: 251 / 255)
    static let githubURL = URL(string: "https://github.com/kameronkim/kkuk")!
}

struct InputRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct QuietActionStyle: ButtonStyle {
    var secondary = false
    var focused = false
    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, secondary: secondary, focused: focused)
    }
    private struct ActionBody: View {
        let configuration: ButtonStyle.Configuration
        let secondary: Bool
        let focused: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled && (hovering || focused || configuration.isPressed) ? KkukTheme.accent : (secondary ? KkukTheme.secondary : KkukTheme.text))
                .padding(.horizontal, 12).frame(minWidth: 96, minHeight: 32)
                .background(configuration.isPressed ? KkukTheme.accent.opacity(0.1) : (hovering && enabled ? KkukTheme.accent.opacity(0.05) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(enabled && (hovering || focused) ? KkukTheme.accent : KkukTheme.line, lineWidth: focused ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 2))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.14), value: hovering)
        }
    }
}

struct OperationDivider: View {
    let busy: Bool
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !busy || progress != nil || reduceMotion)) { context in
                ZStack(alignment: .leading) {
                    Rectangle().fill(KkukTheme.line).frame(height: 1)
                    if busy {
                        Group {
                            if let progress {
                                Rectangle().fill(KkukTheme.accent)
                                    .frame(width: geometry.size.width * min(max(progress, 0), 1), height: 2)
                            } else {
                                let segment = min(60.0, geometry.size.width)
                                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                                Rectangle().fill(KkukTheme.accent).frame(width: segment, height: 2)
                                    .offset(x: reduceMotion ? (geometry.size.width - segment) / 2 : phase * (geometry.size.width + segment) - segment)
                            }
                        }.transition(.opacity)
                    }
                }.frame(width: geometry.size.width, height: 2).clipped()
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: busy)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Progress"))
        .accessibilityValue(progress.map { "\(Int(min(max($0, 0), 1) * 100))%" } ?? L10n.text("In progress"))
        .accessibilityHidden(!busy)
    }
}

struct CompressionView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false
    @State private var targetHovered = false
    @State private var githubHovered = false
    private enum Control: Hashable { case target, operation, github }
    @FocusState private var focusedControl: Control?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Kkuk")).font(.system(size: 40, weight: .bold)).tracking(-1.2)
                    Text(L10n.text("Press down. Pack smaller.")).font(.system(size: 12)).foregroundStyle(KkukTheme.secondary)
                }
                Spacer()
                Text(L10n.text("Compression priority")).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(KkukTheme.secondary)
                    .padding(.top, 7)
            }.padding(.bottom, 26)
            Button(action: model.chooseInput) {
                HStack(spacing: 12) {
                    Image(systemName: model.selectedInput == nil ? "plus.square.dashed" : (model.selectedIsDirectory ? "folder.fill" : "doc.fill"))
                        .font(.system(size: 20)).foregroundStyle(KkukTheme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selectedInput?.lastPathComponent ?? L10n.text("Drop a file or folder here"))
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(KkukTheme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Text(inputMetadata)
                            .font(.system(size: 11)).foregroundStyle(KkukTheme.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: inputMetadata)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(KkukTheme.secondary)
                }.padding(.horizontal, 2).frame(height: 66).frame(maxWidth: .infinity, alignment: .leading)
                    .background(!model.busy && (dragging || targetHovered) ? KkukTheme.text.opacity(0.025) : Color.clear)
                    .overlay(alignment: .top) { Rectangle().fill(dragging && !model.busy ? KkukTheme.accent : KkukTheme.line).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(dragging && !model.busy ? KkukTheme.accent : KkukTheme.line).frame(height: 1) }
                    .overlay { if focusedControl == .target { Rectangle().stroke(KkukTheme.accent, lineWidth: 2) } }
                    .contentShape(Rectangle())
                    .opacity(model.busy && !model.scanning ? 0.7 : 1)
            }.buttonStyle(InputRowStyle()).disabled(model.busy || !model.acceptsNewInput)
                .focusable()
                .focused($focusedControl, equals: .target)
                .onHover { targetHovered = $0 }
                .animation(.easeOut(duration: 0.14), value: targetHovered)
                .accessibilityLabel(model.selectedInput == nil ? L10n.text("Choose a file or folder to compress") : L10n.text("Choose another file or folder"))
            HStack(alignment: .top, spacing: 16) {
                Text(L10n.text("Preset")).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(KkukTheme.secondary).frame(width: 78, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(presetValue).font(.system(size: 14, weight: .semibold))
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: presetValue)
                    Text(L10n.text("Based on input size and available memory.")).font(.system(size: 10)).foregroundStyle(KkukTheme.secondary)
                }
                Spacer()
            }.padding(.top, 18)
            Spacer(minLength: 16)
            operationArea
            footer
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
            .frame(width: 560, height: 400)
            .foregroundStyle(KkukTheme.text).background(KkukTheme.background)
            .preferredColorScheme(.dark)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dragging) { providers in
                guard !model.busy, model.acceptsNewInput, providers.count == 1, let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let value = item as? URL { url = value }
                    else { url = nil }
                    if let url, url.isFileURL { DispatchQueue.main.async { model.analyze(url) } }
                }
                return true
            }
    }
    private var inputMetadata: String {
        if let snapshot = model.snapshot {
            return snapshot.isDirectory ? L10n.format(snapshot.fileCount == 1 ? "%@ · %@ file" : "%@ · %@ files", AppModel.bytes(snapshot.totalBytes), snapshot.fileCount.formatted()) : AppModel.bytes(snapshot.totalBytes)
        }
        guard model.selectedInput != nil else { return L10n.text("Or click to choose.") }
        guard model.scanning else { return L10n.text("Could not read file information.") }
        return model.selectedIsDirectory ? L10n.text("Checking size and file count…") : L10n.text("Checking size…")
    }
    private var presetValue: String {
        model.preset.map { L10n.presetName($0.dictionaryMiB) } ?? (model.scanning ? L10n.text("Checking…") : L10n.text("Applied automatically"))
    }
    private var operationArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            OperationDivider(busy: model.busy && (!model.scanning || model.showsScanGauge), progress: model.progress)
                .frame(height: 2).padding(.top, 20).padding(.bottom, 14)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    if !model.status.isEmpty { Text(model.status).font(.system(size: 13, weight: .semibold)) }
                    if let error = model.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(KkukTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                            .accessibilityLabel(L10n.format("Compression error: %@", error))
                    } else if !model.detail.isEmpty {
                        Text(model.detail).font(.system(size: 11)).foregroundStyle(KkukTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if model.busy && !model.scanning {
                        if model.canCancel { Button(L10n.text("Cancel"), action: model.cancel).buttonStyle(QuietActionStyle(secondary: true, focused: focusedControl == .operation)) }
                    } else if model.result != nil {
                        Button(L10n.text("Show in Finder"), action: model.reveal).buttonStyle(QuietActionStyle(focused: focusedControl == .operation))
                    } else {
                        Button(L10n.text("Compress"), action: model.start).buttonStyle(QuietActionStyle(focused: focusedControl == .operation))
                            .disabled(model.snapshot == nil || model.busy || !model.acceptsNewInput).keyboardShortcut(.defaultAction)
                    }
                }.focusable().focused($focusedControl, equals: .operation).frame(width: 112, alignment: .trailing)
            }.frame(height: 54, alignment: .top)
        }
    }
    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle().fill(KkukTheme.line).frame(height: 1)
            HStack {
                Button { NSWorkspace.shared.open(KkukTheme.githubURL) } label: {
                    Text("GitHub ↗")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(githubHovered || focusedControl == .github ? KkukTheme.accent : KkukTheme.secondary)
                        .frame(minHeight: 24).contentShape(Rectangle())
                        .overlay { if focusedControl == .github { Rectangle().stroke(KkukTheme.accent, lineWidth: 1).padding(-3) } }
                }.buttonStyle(InputRowStyle())
                    .focusable()
                    .focused($focusedControl, equals: .github)
                    .onHover { githubHovered = $0 }
                    .animation(.easeOut(duration: 0.14), value: githubHovered)
                    .accessibilityLabel(L10n.text("Open Kkuk on GitHub"))
                    .help(KkukTheme.githubURL.absoluteString)
                Spacer()
                Text("Kkuk · macOS").font(.system(size: 10, design: .monospaced)).foregroundStyle(KkukTheme.secondary)
            }
        }.padding(.top, 10)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var window: NSWindow?
    private var progressWindow: NSWindow?
    private var closingProgress = false
    private var confirmingQuit = false
    private var waitingForTermination = false
    private var completionQuitScheduled = false
    private var appIcon: NSImage?
    private var finderService: FinderCompressionService?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            appIcon = icon
            NSApplication.shared.applicationIconImage = icon
        }
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.text("About Kkuk"), action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("Quit Kkuk"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: L10n.text("File"))
        fileMenu.addItem(withTitle: L10n.text("Choose File or Folder…"), action: #selector(openInput), keyEquivalent: "o")
        fileItem.submenu = fileMenu
        NSApplication.shared.mainMenu = menu
        let service = FinderCompressionService(model: model, rejectInput: { [weak self] in self?.finishRejectedService() }) { [weak self] isNewRequest in self?.showServiceWindow(isNewRequest: isNewRequest) }
        finderService = service
        NSApplication.shared.servicesProvider = service
        // Services launch in the background; show their progress window only after receiving input.
        if (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true {
            showMainWindow()
        }
    }
    private func present(_ window: NSWindow) {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Leave controls unfocused until the user navigates with the keyboard.
        window.makeFirstResponder(nil)
    }
    func showMainWindow() {
        model.onArchiveSucceeded = nil
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = L10n.text("Kkuk")
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(KkukTheme.background)
            window.contentView = NSHostingView(rootView: CompressionView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        progressWindow?.orderOut(nil)
        if let window { present(window) }
    }
    func showServiceWindow(isNewRequest: Bool) {
        if !isNewRequest {
            if let progressWindow, progressWindow.isVisible || progressWindow.isMiniaturized { present(progressWindow) }
            else if let window { present(window) }
            return
        }
        model.onArchiveSucceeded = { [weak self] in self?.finishSuccessfulService() }
        if progressWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: FinderProgressView.height(hasError: false)),
                                 styleMask: [.titled, .closable, .miniaturizable],
                                 backing: .buffered, defer: false)
            panel.title = L10n.text("Kkuk")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.backgroundColor = NSColor(KkukTheme.background)
            let hostingView = NSHostingView(rootView: FinderProgressView(model: model, close: { [weak self] in self?.closeProgressWindow() }, resize: { [weak self] hasError in self?.resizeProgressWindow(hasError: hasError) }))
            hostingView.sizingOptions = []
            panel.contentView = hostingView
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            var frame = panel.frame
            frame.size.height = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 440, height: FinderProgressView.height(hasError: false))).height
            panel.setFrame(frame, display: false)
            panel.center()
            progressWindow = panel
        }
        window?.orderOut(nil)
        if let progressWindow { present(progressWindow) }
    }
    private func resizeProgressWindow(hasError: Bool) {
        guard let progressWindow else { return }
        var frame = progressWindow.frame
        let height = progressWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 440, height: FinderProgressView.height(hasError: hasError))).height
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        progressWindow.setFrame(frame, display: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.busy || !model.acceptsNewInput { showServiceWindow(isNewRequest: false) }
        else { showMainWindow() }
        return false
    }
    @objc func openInput() {
        guard !model.busy, model.acceptsNewInput else { showServiceWindow(isNewRequest: false); return }
        showMainWindow()
        model.chooseInput()
    }
    @objc func about() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: L10n.text("Kkuk"), .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .applicationIcon: NSApplication.shared.applicationIconImage as Any,
            .credits: NSAttributedString(string: L10n.text("Press down. Pack smaller.") + "\n7-Zip 26.03 © Igor Pavlov\nhttps://7-zip.org\n" + L10n.text("Licenses are included in the app’s Resources/Licenses folder."))
        ])
    }
    func finishRejectedService() {
        // Return the Services error before ending a windowless background launch.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window == nil, self.progressWindow == nil,
                  !self.model.busy, self.model.acceptsNewInput else { return }
            NSApplication.shared.terminate(nil)
        }
    }
    private func finishSuccessfulService() {
        guard model.result != nil, !confirmingQuit, !waitingForTermination, !completionQuitScheduled else { return }
        completionQuitScheduled = true
        model.acceptsNewInput = false
        let delay = max(0, model.completionSoundEndsAt.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.closeProgressWindow()
        }
    }
    func closeProgressWindow() {
        closingProgress = true
        model.acceptsNewInput = false
        NSApplication.shared.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingForTermination { return .terminateLater }
        if confirmingQuit { return .terminateCancel }
        guard model.busy else { return .terminateNow }
        model.acceptsNewInput = false
        if !closingProgress {
            confirmingQuit = true
            let alert = NSAlert()
            if let appIcon { alert.icon = appIcon.copy() as? NSImage }
            alert.messageText = L10n.text("Cancel the current task and quit?")
            alert.informativeText = L10n.text("The original will be kept. Temporary archives will be removed before quitting.")
            alert.addButton(withTitle: L10n.text("Keep Working")); alert.addButton(withTitle: L10n.text("Cancel and Quit"))
            let response = alert.runModal()
            confirmingQuit = false
            guard response == .alertSecondButtonReturn else {
                model.acceptsNewInput = true
                if model.result != nil {
                    DispatchQueue.main.async { self.model.onArchiveSucceeded?() }
                }
                return .terminateCancel
            }
        }
        if model.canCancel {
            waitingForTermination = true
            model.onTaskFinished = { [weak model] in
                model?.onTaskFinished = nil
                sender.reply(toApplicationShouldTerminate: true)
            }
            model.cancel()
            return .terminateLater
        }
        // Analysis is read-only; no temporary archive exists yet.
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === progressWindow { closeProgressWindow() }
        else { NSApplication.shared.terminate(nil) }
        return false
    }
}

@main
struct KkukApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
