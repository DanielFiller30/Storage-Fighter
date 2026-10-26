import Synchronization

/// Shared depth-first queue of directories still to be read. ``take(controller:)`` suspends while other
/// workers may still produce work and returns `nil` once everything is done or the task is cancelled.
final class WorkQueue: Sendable {
    typealias Item = TreeBuilder.Subdirectory

    private struct State {
        var items: [Item]
        /// Items handed out whose ``WorkQueue/complete(adding:)`` has not been called yet.
        var inFlight = 0
        var isFinished = false
        var waiters: [CheckedContinuation<Item?, Never>] = []
    }

    private let state: Mutex<State>

    init(initial: [Item]) {
        state = Mutex(State(items: initial, isFinished: initial.isEmpty))
    }

    func take(controller: ScanController) async -> Item? {
        if controller.isPaused { await controller.waitWhilePaused() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Item?? = state.withLock { state in
                    if state.isFinished || Task.isCancelled { return .some(nil) }
                    if let item = state.items.popLast() {
                        state.inFlight += 1
                        return .some(item)
                    }
                    state.waiters.append(continuation)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            finish()
        }
    }

    func complete(adding newItems: [Item]) {
        var handOuts: [(CheckedContinuation<Item?, Never>, Item?)] = []
        state.withLock { state in
            state.inFlight -= 1
            guard !state.isFinished else { return }
            state.items.append(contentsOf: newItems)
            while !state.waiters.isEmpty, let item = state.items.popLast() {
                state.inFlight += 1
                handOuts.append((state.waiters.removeLast(), item))
            }
            if state.items.isEmpty && state.inFlight == 0 {
                state.isFinished = true
                handOuts += state.waiters.map { ($0, nil) }
                state.waiters = []
            }
        }
        for (continuation, item) in handOuts { continuation.resume(returning: item) }
    }

    private func finish() {
        let waiters = state.withLock { state in
            state.isFinished = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }
}
