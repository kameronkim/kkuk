import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KkukCore

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: InputSnapshot?
    @Published var preset: CompressionPreset?
    @Published var busy = false
    @Published var status = "파일이나 폴더를 넣어 주세요"
    @Published var detail = "압축률을 우선해 자동으로 설정합니다."
    @Published var progress: Double?
    @Published var error: String?
    @Published var result: ArchiveResult?
    private var job: ArchiveJob?
    var onTaskFinished: (() -> Void)?

    var engine: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
    }
    func chooseInput() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "압축할 파일이나 폴더 선택"
        panel.prompt = "선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { analyze(url) }
    }
    func analyze(_ folder: URL) {
        guard !busy else { return }
        busy = true; error = nil; result = nil; snapshot = nil; preset = nil
        status = "입력 확인 중"; detail = folder.lastPathComponent; progress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scanned = try InputScanner.scan(folder)
                let selected = CompressionPreset.select(inputBytes: scanned.totalBytes, memoryBudgetBytes: MemoryBudget.current())
                DispatchQueue.main.async {
                    self.snapshot = scanned; self.preset = selected; self.busy = false
                    self.status = "압축 준비 완료"
                    self.detail = selected.memoryAdjusted ? "메모리 여유에 맞춰 프리셋을 적용했습니다." : "자동 프리셋이 적용됐습니다."
                }
            } catch {
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }
    func start() {
        guard !busy, let snapshot else { return }
        let panel = NSSavePanel()
        panel.title = "압축 파일 저장"
        panel.prompt = "압축"
        panel.nameFieldStringValue = snapshot.input.lastPathComponent + ".7z"
        panel.directoryURL = snapshot.input.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "7z") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try ArchiveJob.validateDestination(destination, source: snapshot.input) }
        catch { fail(error); return }
        // Rescan immediately before execution instead of relying on stale selection metadata.
        let job = ArchiveJob(engine: engine)
        self.job = job
        busy = true; error = nil; result = nil; progress = nil
        status = "압축 준비 중"; detail = "원본과 메모리 여유를 다시 확인합니다."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let current = try InputScanner.scan(snapshot.input) { try job.runner.checkCancellation() }
                let preset = CompressionPreset.select(inputBytes: current.totalBytes, memoryBudgetBytes: MemoryBudget.current())
                DispatchQueue.main.async { self.snapshot = current; self.preset = preset }
                let result = try job.execute(snapshot: current, preset: preset, destination: destination) { stage, value in
                    DispatchQueue.main.async {
                        self.progress = value
                        switch stage {
                        case .compressing: self.status = "꾹 압축 중"; self.detail = "\(preset.name) 프리셋으로 압축합니다."
                        case .verifying: self.status = "압축 파일 검사 중"; self.detail = "압축된 데이터를 읽어 무결성을 검사합니다."
                        case .checkingContents: self.status = "포함 파일 확인 중"; self.detail = "파일 목록과 원본의 변경 여부를 확인합니다."
                        case .finished: break
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.result = result; self.busy = false; self.job = nil; self.progress = nil
                    self.status = "압축과 검사 완료"
                    self.detail = Self.resultDetail(result)
                    self.onTaskFinished?()
                }
            } catch {
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }
    func cancel() {
        guard let job else { return }
        status = "취소 중"; detail = "진행 중인 작업을 멈추고 임시 파일을 정리합니다."
        job.cancel()
    }
    func fail(_ failure: Error) {
        busy = false; progress = nil; job = nil
        if let kkukError = failure as? KkukError, case .cancelled = kkukError {
            error = nil; status = "취소됨"; detail = "원본을 유지하고 임시 파일을 정리했습니다."
        } else {
            error = failure.localizedDescription; status = "작업을 완료하지 못했습니다"; detail = "아래 내용을 확인해 주세요."
        }
        onTaskFinished?()
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
            change = "빈 항목을 보관했습니다"
        } else if result.archiveBytes > result.originalBytes {
            change = "크기가 조금 늘었습니다"
        } else {
            let percent = (1 - Double(result.archiveBytes) / Double(result.originalBytes)) * 100
            change = String(format: "%.1f%% 작아짐", percent)
        }
        return "\(bytes(result.originalBytes)) → \(bytes(result.archiveBytes)) · \(change)"
    }
    var canCancel: Bool { job != nil }
}

struct CompressionView: View {
    @ObservedObject var model: AppModel
    @State private var dragging = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("꾹").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("꾹 눌러, 더 작게.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("압축률 최우선").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 22)
            Button(action: model.chooseInput) {
                HStack(spacing: 12) {
                    Image(systemName: model.snapshot == nil ? "plus.square.dashed" : (model.snapshot?.isDirectory == true ? "folder.fill" : "doc.fill"))
                        .font(.system(size: 24)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.snapshot?.input.lastPathComponent ?? "파일이나 폴더를 여기에 놓으세요")
                            .font(.headline).lineLimit(1).truncationMode(.middle)
                        if let snapshot = model.snapshot {
                            Text(snapshot.isDirectory ? "\(AppModel.bytes(snapshot.totalBytes)) · 파일 \(snapshot.fileCount.formatted())개" : AppModel.bytes(snapshot.totalBytes))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("클릭해서 선택할 수도 있습니다.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background(dragging ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(dragging ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
            }.buttonStyle(.plain).disabled(model.busy)
                .accessibilityLabel(model.snapshot == nil ? "압축할 파일이나 폴더 선택" : "다른 파일이나 폴더 선택")
            HStack(alignment: .top, spacing: 16) {
                Text("적용 프리셋").foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.preset?.name ?? "선택하면 자동 적용").fontWeight(.medium)
                    Text("입력 크기와 메모리 여유에 맞춰 설정합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.top, 22)
            HStack(spacing: 20) {
                Label("원본 유지", systemImage: "checkmark")
                Label("완료 후 자동 검사", systemImage: "checkmark.shield")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 18)
            Spacer(minLength: 18)
            if let error = model.error {
                ScrollView { Text(error).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 100).padding(10).background(Color.red.opacity(0.06)).cornerRadius(7)
                    .accessibilityLabel("작업 오류: \(error)")
                    .padding(.bottom, 12)
            }
            if model.busy {
                if let value = model.progress { ProgressView(value: value).padding(.bottom, 12) }
                else { ProgressView().controlSize(.small).padding(.bottom, 12) }
            }
            Divider().padding(.bottom, 14)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status).fontWeight(.medium)
                    Text(model.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.busy {
                    if model.canCancel { Button("취소", action: model.cancel) }
                } else if model.result != nil {
                    Button("Finder에서 보기", action: model.reveal).buttonStyle(.borderedProminent)
                } else {
                    Button("압축하기", action: model.start).buttonStyle(.borderedProminent)
                        .disabled(model.snapshot == nil).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(26).frame(minWidth: 500, idealWidth: 560, minHeight: 400, idealHeight: 440)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dragging) { providers in
                guard !model.busy, providers.count == 1, let provider = providers.first else { return false }
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "꾹 · Kkuk"
        window.contentView = NSHostingView(rootView: CompressionView(model: model))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "꾹에 관하여", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "꾹 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "파일")
        fileMenu.addItem(withTitle: "파일 또는 폴더 선택…", action: #selector(openInput), keyEquivalent: "o")
        fileItem.submenu = fileMenu
        NSApplication.shared.mainMenu = menu
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func openInput() { model.chooseInput() }
    @objc func about() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "꾹 · Kkuk", .applicationVersion: "0.1.0",
            .applicationIcon: NSApplication.shared.applicationIconImage as Any,
            .credits: NSAttributedString(string: "꾹 눌러, 더 작게.\n7-Zip 26.03 © Igor Pavlov\nhttps://7-zip.org\n라이선스는 앱의 Resources/Licenses에 포함되어 있습니다.")
        ])
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "진행 중인 작업을 취소하고 종료할까요?"
        alert.informativeText = "원본은 유지됩니다. 압축 중이었다면 임시 파일을 정리한 뒤 종료합니다."
        alert.addButton(withTitle: "계속 작업"); alert.addButton(withTitle: "취소하고 종료")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if model.canCancel {
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
        NSApplication.shared.terminate(nil)
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
