import SwiftUI

struct FinderQueueButton: View {
    @ObservedObject var model: AppModel
    @State private var showingQueue = false

    var body: some View {
        Button { showingQueue.toggle() } label: {
            Text(L10n.format("%d waiting", model.pendingFinderRequests.count))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(KkukTheme.secondary)
        }
        .buttonStyle(.plain)
        .help(L10n.text("View queued tasks"))
        .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Queued tasks")).font(.system(size: 12, weight: .semibold))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.pendingFinderRequests) { request in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(request.title).font(.system(size: 12, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(request.inputs.first?.deletingLastPathComponent().path ?? "")
                                        .font(.system(size: 10)).foregroundStyle(KkukTheme.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.removeFinderRequest(id: request.id) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .disabled(!model.acceptsNewInput)
                                .help(L10n.text("Remove from queue"))
                                .accessibilityLabel(L10n.format("Remove %@ from queue", request.title))
                            }.padding(.vertical, 9)
                            Rectangle().fill(KkukTheme.line).frame(height: 1)
                        }
                    }
                }.frame(height: CGFloat(min(model.pendingFinderRequests.count, 4)) * 54)
            }
            .padding(16).frame(width: 340)
            .foregroundStyle(KkukTheme.text).background(KkukTheme.background)
            .preferredColorScheme(.dark)
        }
        .onChange(of: model.pendingFinderRequests.isEmpty) { _, empty in
            if empty { showingQueue = false }
        }
    }
}
