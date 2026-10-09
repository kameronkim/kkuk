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
        // Do not accept requests while the application is shutting down.
        guard model.acceptsNewInput else { showWindow(false); return }
        guard let inputs = Self.inputs(from: pasteboard) else {
            error.pointee = L10n.text("Choose files or folders to compress.") as NSString
            rejectInput()
            return
        }
        // Return to the Services caller immediately; analysis and compression run asynchronously.
        model.enqueueFinderInputs(inputs)
        showWindow(false)
    }

    static func inputs(from pasteboard: NSPasteboard) -> [URL]? {
        let urls: [URL]
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
            urls = paths.map { URL(fileURLWithPath: $0) }
        } else {
            urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return nil }
        return urls
    }
}
