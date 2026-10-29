import Foundation

struct FinderCompressionRequest: Identifiable {
    let id = UUID()
    let inputs: [URL]
    private let inputCount: Int

    init(inputs: [URL]) {
        self.inputs = inputs
        inputCount = Set(inputs).count
    }

    var title: String {
        guard let first = inputs.first else { return L10n.text("Kkuk") }
        return inputCount == 1 ? first.lastPathComponent : L10n.format("%@ and %d more", first.lastPathComponent, inputCount - 1)
    }
}

struct FailedFinderRequest: Identifiable {
    let request: FinderCompressionRequest
    let reason: String
    var id: UUID { request.id }
}

// Session records own identity and transitions; execution and UI remain outside.
struct FinderTaskSession {
    private(set) var pending: [FinderCompressionRequest] = []
    private(set) var failures: [FailedFinderRequest] = []
    private(set) var active: FinderCompressionRequest?

    var hasTasks: Bool { !pending.isEmpty || !failures.isEmpty }
    func canFinish(busy: Bool, acceptsInput: Bool, hasResult: Bool) -> Bool {
        !busy && acceptsInput && hasResult && active == nil && !hasTasks
    }
    mutating func enqueue(_ inputs: [URL]) { pending.append(FinderCompressionRequest(inputs: inputs)) }
    mutating func takeNext() -> FinderCompressionRequest? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
    func retryRequest(id: UUID) -> FinderCompressionRequest? {
        guard !pending.contains(where: { $0.id == id }) else { return nil }
        return failures.first { $0.id == id }?.request
    }
    mutating func begin(_ request: FinderCompressionRequest) { active = request }
    mutating func succeed() {
        if let active { failures.removeAll { $0.id == active.id } }
        active = nil
    }
    mutating func fail(reason: String?) {
        defer { active = nil }
        guard let active, let reason else { return }
        let record = FailedFinderRequest(request: active, reason: reason)
        if let index = failures.firstIndex(where: { $0.id == active.id }) { failures[index] = record }
        else { failures.append(record) }
    }
    func canDismiss(id: UUID) -> Bool {
        active?.id != id && failures.contains { $0.id == id }
    }
    mutating func dismiss(id: UUID) -> Bool {
        guard active?.id != id, let index = failures.firstIndex(where: { $0.id == id }) else { return false }
        failures.remove(at: index)
        return true
    }
    mutating func removePending(id: UUID) { pending.removeAll { $0.id == id } }
    mutating func discardPending() { pending.removeAll() }
}
