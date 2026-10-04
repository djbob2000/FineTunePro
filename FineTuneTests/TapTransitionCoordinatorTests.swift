import Testing
@testable import FineTune

@Suite("Tap transition serialization")
@MainActor
struct TapTransitionCoordinatorTests {
    @Test("A replacement waits for cancellation cleanup before touching HAL resources")
    func latestRequestWaitsForCleanup() async throws {
        let coordinator = TapTransitionCoordinator()
        var events: [String] = []
        let first = Task { @MainActor in
            try await coordinator.perform {
                events.append("first-start")
                defer { events.append("first-cleanup") }
                try await Task.sleep(for: .seconds(10))
                events.append("first-finish")
            }
        }
        while events.isEmpty { await Task.yield() }
        let replaced = try await coordinator.perform { events.append("second-start") }
        #expect(replaced)
        #expect(try await first.value == false)
        #expect(events == ["first-start", "first-cleanup", "second-start"])
    }

    @Test("Invalidation cancels a suspended switch and allows no post-teardown writes")
    func cancellation() async throws {
        let coordinator = TapTransitionCoordinator()
        var started = false
        var resumed = false
        let operation = Task { @MainActor in
            try await coordinator.perform {
                started = true
                try await Task.sleep(for: .seconds(10))
                resumed = true
            }
        }
        while !started { await Task.yield() }
        coordinator.cancel()
        #expect(try await operation.value == false)
        #expect(!resumed)
    }

    @Test("A format refresh waits for the route without cancelling it")
    func formatRefreshWaits() async throws {
        let coordinator = TapTransitionCoordinator()
        var release: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let route = Task { @MainActor in
            try await coordinator.perform {
                await withCheckedContinuation { release = $0 }
                try Task.checkCancellation()
                events.append("route-ready")
            }
        }
        while release == nil { await Task.yield() }
        let refresh = Task { @MainActor in
            await coordinator.waitForPending()
            events.append("refresh")
        }
        release?.resume()
        #expect(try await route.value)
        await refresh.value
        #expect(events == ["route-ready", "refresh"])
    }

}
