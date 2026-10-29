import AppKit
import UniformTypeIdentifiers

/// Native selection only. AppModel decides whether the input may start a task.
@MainActor
final class InputSelectionController {
    private var pendingDrop: UUID?

    func invalidatePendingDrop() { pendingDrop = nil }

    func load(_ provider: NSItemProvider, receive: @escaping @MainActor (URL) -> Void) {
        let request = UUID()
        pendingDrop = request
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            let url = Self.fileURL(from: item)
            DispatchQueue.main.async {
                guard let self, self.pendingDrop == request else { return }
                self.pendingDrop = nil
                if let url { receive(url) }
            }
        }
    }
    nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
        else if let value = item as? URL { url = value }
        else { url = nil }
        return url?.isFileURL == true ? url : nil
    }
    func choose() -> URL? {
        invalidatePendingDrop()
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose a file or folder to compress")
        panel.prompt = L10n.text("Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
