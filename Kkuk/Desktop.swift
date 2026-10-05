import AppKit
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
    @Published var status = ""
    @Published var detail = ""
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
                    self.status = "압축 준비 완료"
                    self.detail = ""
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
        busy = true; error = nil; result = nil; progress = nil
        status = "압축 준비 중"; detail = ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let current = try InputScanner.scan(snapshot.input) { try job.runner.checkCancellation() }
                let preset = CompressionPreset.select(inputBytes: current.totalBytes, memoryBudgetBytes: MemoryBudget.current())
                DispatchQueue.main.async { self.snapshot = current; self.preset = preset }
                let result = try job.executeBesideInput(snapshot: current, preset: preset) { stage, value in
                    DispatchQueue.main.async {
                        self.progress = value
                        switch stage {
                        case .compressing: self.status = "꾹 압축 중"; self.detail = ""
                        case .verifying: self.status = "압축 파일 검사 중"; self.detail = ""
                        case .checkingContents: self.status = "포함 파일 확인 중"; self.detail = ""
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
        status = "취소 중"; detail = ""
        job.cancel()
    }
    func fail(_ failure: Error) {
        scanGaugeTask?.cancel(); scanGaugeTask = nil
        showsScanGauge = false
        busy = false; scanning = false; progress = nil; job = nil
        if let kkukError = failure as? KkukError, case .cancelled = kkukError {
            error = nil; status = "취소됨"; detail = ""
        } else {
            error = Self.userFacingError(failure); status = "압축하지 못했습니다."; detail = ""
        }
        onTaskFinished?()
    }
    static func userFacingError(_ failure: Error) -> String {
        // Keep engine transcripts, file paths and error codes out of the interface.
        if let error = failure as? KkukError, case .message(let message) = error {
            let safeMessages = [
                "압축할 파일이나 폴더를 선택해 주세요.",
                "시스템 루트 대신 압축할 파일이나 폴더를 선택해 주세요.",
                "압축 결과는 원본 폴더 바깥에 저장해 주세요.",
                "저장 파일의 확장자는 .7z여야 합니다.",
                "같은 이름의 파일이 있습니다. 다른 이름으로 저장해 주세요."
            ]
            if safeMessages.contains(message) { return message }
            if message.hasPrefix("줄바꿈이 포함된 파일 이름") { return "줄바꿈이 포함된 파일 이름을 바꾼 뒤 다시 선택해 주세요." }
            if message.hasPrefix("일반 파일·폴더·심볼릭 링크만") { return "일반 파일이나 폴더를 선택해 주세요." }
            if message.hasPrefix("7-Zip 엔진을 찾을 수 없습니다") { return "앱을 다시 설치한 뒤 시도해 주세요." }
            if message.hasPrefix("지금은 압축에 사용할 메모리") { return "다른 앱을 닫은 뒤 다시 시도해 주세요." }
            if message.hasPrefix("압축하는 동안 원본") { return "원본 변경 작업을 마친 뒤 다시 압축해 주세요." }
            if message.hasPrefix("압축 파일에 포함된 항목") { return "원본을 다시 선택한 뒤 압축해 주세요." }
        }
        let error = failure as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteOutOfSpace: return "저장 공간을 확보한 뒤 다시 시도해 주세요."
            case .fileReadNoPermission, .fileWriteNoPermission: return "파일과 저장 위치의 접근 권한을 확인해 주세요."
            case .fileNoSuchFile, .fileReadNoSuchFile: return "원본 파일이나 폴더를 다시 선택해 주세요."
            case .fileWriteFileExists: return "다른 이름으로 저장해 주세요."
            default: break
            }
        }
        return "원본과 저장 위치를 확인한 뒤 다시 시도해 주세요."
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
        .accessibilityLabel("진행률")
        .accessibilityValue(progress.map { "\(Int(min(max($0, 0), 1) * 100))%" } ?? "진행 중")
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
                    Text("꾹").font(.system(size: 40, weight: .bold)).tracking(-1.2)
                    Text("꾹 눌러, 더 작게.").font(.system(size: 12)).foregroundStyle(KkukTheme.secondary)
                }
                Spacer()
                Text("압축률 최우선").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(KkukTheme.secondary)
                    .padding(.top, 7)
            }.padding(.bottom, 26)
            Button(action: model.chooseInput) {
                HStack(spacing: 12) {
                    Image(systemName: model.selectedInput == nil ? "plus.square.dashed" : (model.selectedIsDirectory ? "folder.fill" : "doc.fill"))
                        .font(.system(size: 20)).foregroundStyle(KkukTheme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selectedInput?.lastPathComponent ?? "파일이나 폴더를 여기에 놓으세요")
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
            }.buttonStyle(InputRowStyle()).disabled(model.busy)
                .focusable()
                .focused($focusedControl, equals: .target)
                .onHover { targetHovered = $0 }
                .animation(.easeOut(duration: 0.14), value: targetHovered)
                .accessibilityLabel(model.selectedInput == nil ? "압축할 파일이나 폴더 선택" : "다른 파일이나 폴더 선택")
            HStack(alignment: .top, spacing: 16) {
                Text("적용 프리셋").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(KkukTheme.secondary).frame(width: 78, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(presetValue).font(.system(size: 14, weight: .semibold))
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: presetValue)
                    Text("입력 크기와 메모리 여유에 맞춰 설정합니다.").font(.system(size: 10)).foregroundStyle(KkukTheme.secondary)
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
    private var inputMetadata: String {
        if let snapshot = model.snapshot {
            return snapshot.isDirectory ? "\(AppModel.bytes(snapshot.totalBytes)) · 파일 \(snapshot.fileCount.formatted())개" : AppModel.bytes(snapshot.totalBytes)
        }
        guard model.selectedInput != nil else { return "클릭해서 선택할 수도 있습니다." }
        guard model.scanning else { return "정보를 확인하지 못했습니다." }
        return model.selectedIsDirectory ? "크기 · 파일 개수 확인 중…" : "크기 확인 중…"
    }
    private var presetValue: String {
        model.preset?.name ?? (model.scanning ? "확인 중…" : "선택하면 자동 적용")
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
                            .accessibilityLabel("압축 오류: \(error)")
                    } else if !model.detail.isEmpty {
                        Text(model.detail).font(.system(size: 11)).foregroundStyle(KkukTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if model.busy && !model.scanning {
                        if model.canCancel { Button("취소", action: model.cancel).buttonStyle(QuietActionStyle(secondary: true, focused: focusedControl == .operation)) }
                    } else if model.result != nil {
                        Button("Finder에서 보기", action: model.reveal).buttonStyle(QuietActionStyle(focused: focusedControl == .operation))
                    } else {
                        Button("압축하기", action: model.start).buttonStyle(QuietActionStyle(focused: focusedControl == .operation))
                            .disabled(model.snapshot == nil || model.busy).keyboardShortcut(.defaultAction)
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
                    .accessibilityLabel("GitHub에서 꾹 저장소 열기")
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "꾹 · Kkuk"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(KkukTheme.background)
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
