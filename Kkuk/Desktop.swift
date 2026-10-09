import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
            Button(action: { model.chooseInput() }) {
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
            }.buttonStyle(InputRowStyle()).disabled(!model.canChooseInput)
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
                guard providers.count == 1, let provider = providers.first else { return false }
                return model.loadDroppedInput(provider)
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
                    if !model.status.isEmpty { Text(model.status + (model.pendingFinderRequests.isEmpty ? "" : " · " + L10n.format("%d waiting", model.pendingFinderRequests.count))).font(.system(size: 13, weight: .semibold)) }
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
                    } else if !model.pendingFinderRequests.isEmpty {
                        Button(L10n.text("Continue queue")) { model.resumeFinderQueue() }.buttonStyle(QuietActionStyle(focused: focusedControl == .operation))
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
