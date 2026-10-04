/// Serializes transitions that own the same tap and aggregate resources. New requests
/// cancel the old transition, await its cleanup, and then apply the latest destination.
@MainActor
final class TapTransitionCoordinator {
    private var generation: UInt = 0
    private var operation: Task<Void, Error>?
    private var pendingRequests = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func perform(_ body: @escaping @MainActor () async throws -> Void) async throws -> Bool {
        pendingRequests += 1
        defer {
            pendingRequests -= 1
            if pendingRequests == 0 {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        generation &+= 1
        let request = generation
        let previous = operation
        previous?.cancel()
        if let previous { _ = await previous.result }
        guard request == generation, !Task.isCancelled else { return false }

        let task = Task { @MainActor in
            try Task.checkCancellation()
            try await body()
        }
        operation = task
        do {
            try await task.value
        } catch is CancellationError {
            if request == generation { operation = nil }
            return false
        } catch {
            if request == generation { operation = nil }
            throw error
        }
        guard request == generation else { return false }
        operation = nil
        return true
    }

    /// Format refreshes should follow an in-flight destination change rather than
    /// cancelling it and rebuilding the old route.
    func waitForPending() async {
        guard pendingRequests > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func cancel() {
        generation &+= 1
        operation?.cancel()
    }
}
