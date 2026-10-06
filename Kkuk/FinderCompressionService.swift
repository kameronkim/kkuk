import AppKit

@MainActor
final class FinderCompressionService: NSObject {
    private let model: AppModel
    private let showWindow: (Bool) -> Void
    private let rejectInput: () -> Void

    init(model: AppModel, rejectInput: @escaping () -> Void, showWindow: @escaping (Bool) -> Void) {
        self.model = model
        self.rejectInput = rejectInput
        self.showWindow = showWindow
    }

    @objc func compressWithKkuk(_ pasteboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // Never replace a selection or queue another task while work is in progress.
        guard !model.busy, model.acceptsNewInput else { showWindow(false); return }
        guard let input = Self.singleInput(from: pasteboard) else {
            error.pointee = L10n.text("Choose one file or folder to compress.") as NSString
            rejectInput()
            return
        }
        // Return to the Services caller immediately; analysis and compression run asynchronously.
        model.analyze(input, compressWhenReady: true)
        showWindow(true)
    }

    static func singleInput(from pasteboard: NSPasteboard) -> URL? {
        let urls: [URL]
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            guard paths.count == 1, let path = paths.first, path.hasPrefix("/") else { return nil }
            urls = [URL(fileURLWithPath: path)]
        } else {
            urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        guard urls.count == 1, let url = urls.first, url.isFileURL else { return nil }
        return url
    }
}
