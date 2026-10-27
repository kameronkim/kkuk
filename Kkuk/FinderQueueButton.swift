import SwiftUI

struct FinderQueueButton: View {
    @ObservedObject var model: AppModel
    @State private var showingQueue = false

    private var label: String {
        var parts: [String] = []
        if !model.pendingFinderRequests.isEmpty { parts.append(L10n.format("%d waiting", model.pendingFinderRequests.count)) }
        if !model.failedFinderRequests.isEmpty { parts.append(L10n.format("%d failed", model.failedFinderRequests.count)) }
        return parts.joined(separator: " · ")
    }
    private var listHeight: CGFloat {
        if model.failedFinderRequests.isEmpty { return CGFloat(min(model.pendingFinderRequests.count, 4)) * 54 }
        return CGFloat(min(model.pendingFinderRequests.count + model.failedFinderRequests.count, 4)) * 80
    }
    var body: some View {
        Button { showingQueue.toggle() } label: {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(KkukTheme.secondary)
        }
        .buttonStyle(.plain)
        .help(L10n.text("View compression tasks"))
        .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(model.failedFinderRequests.isEmpty ? "Queued tasks" : "Compression tasks")).font(.system(size: 12, weight: .semibold))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !model.failedFinderRequests.isEmpty {
                            Text(L10n.text("Failed tasks")).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(KkukTheme.secondary).padding(.bottom, 4)
                            ForEach(model.failedFinderRequests) { failure in
                                let sourcePath = failure.request.inputs.first?.deletingLastPathComponent().path ?? ""
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(failure.request.title).font(.system(size: 12, weight: .medium))
                                            .lineLimit(1).truncationMode(.middle)
                                        Text(sourcePath).font(.system(size: 10)).foregroundStyle(KkukTheme.secondary)
                                            .lineLimit(1).truncationMode(.middle).help(sourcePath)
                                        Text(failure.reason).font(.system(size: 10)).foregroundStyle(KkukTheme.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Button(L10n.text("Retry")) { model.retryFailedFinderRequest(id: failure.id) }
                                        .buttonStyle(.plain).font(.system(size: 11))
                                        .disabled(!model.canRetryFailedRequest)
                                        .accessibilityLabel(L10n.format("Retry %@", failure.request.title))
                                        .accessibilityHint(sourcePath)
                                }.padding(.vertical, 9)
                                Rectangle().fill(KkukTheme.line).frame(height: 1)
                            }
                            if !model.pendingFinderRequests.isEmpty {
                                Text(L10n.text("Queued tasks")).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(KkukTheme.secondary).padding(.top, 12).padding(.bottom, 4)
                            }
                        }
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
                }.frame(height: listHeight)
            }
            .padding(16).frame(width: 340)
            .foregroundStyle(KkukTheme.text).background(KkukTheme.background)
            .preferredColorScheme(.dark)
        }
        .onChange(of: model.hasFinderTasks) { _, hasTasks in
            if !hasTasks { showingQueue = false }
        }
    }
}
