import AppKit
import SwiftUI

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
