import SwiftUI

struct FinderProgressView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    let resize: (Bool) -> Void

    static func height(hasError: Bool) -> CGFloat { hasError ? 92 : 64 }

    private var status: String {
        model.scanning ? L10n.text("Checking input…") : model.status
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.selectedIsDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 24)).foregroundStyle(KkukTheme.secondary)
                .frame(width: 28).padding(.top, 13)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(model.selectedInput?.lastPathComponent ?? L10n.text("Kkuk"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if !model.pendingFinderInputs.isEmpty {
                        Text(L10n.format("%d waiting", model.pendingFinderInputs.count))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(KkukTheme.secondary)
                    }
                    Button(action: close) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(KkukTheme.secondary)
                        .help(L10n.text(model.busy ? "Cancel and Quit" : "Close"))
                        .accessibilityLabel(L10n.text(model.busy ? "Cancel and Quit" : "Close"))
                }
                OperationDivider(busy: model.busy && (!model.scanning || model.showsScanGauge), progress: model.progress)
                    .frame(height: 2)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status).font(.system(size: 11))
                        if let error = model.error {
                            Text(error).font(.system(size: 10)).lineLimit(2)
                        }
                    }.foregroundStyle(KkukTheme.secondary)
                    Spacer(minLength: 0)
                    if model.busy, let progress = model.progress {
                        Text("\(Int(min(max(progress, 0), 1) * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(KkukTheme.secondary)
                    } else if !model.busy, !model.pendingFinderInputs.isEmpty {
                        Button(L10n.text("Continue queue")) { model.resumeFinderQueue() }
                            .buttonStyle(.plain).font(.system(size: 10))
                    } else if !model.busy, model.result != nil {
                        Button(L10n.text("Show in Finder"), action: model.reveal)
                            .buttonStyle(.plain).font(.system(size: 10))
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(width: 440, height: Self.height(hasError: model.error != nil), alignment: .center)
        .foregroundStyle(KkukTheme.text).background(KkukTheme.background)
        .preferredColorScheme(.dark)
        .onChange(of: model.error) { _, error in resize(error != nil) }
    }
}
