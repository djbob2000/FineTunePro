# Media Key Volume Control Crash Fix Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Fix the application crash when using F keys (media keys) for volume control by decoupling event swallowing from actor-isolated processing.

**Architecture:** We will change `processSystemDefined(_:)` in `MediaKeyMonitor` to be `nonisolated` and run the actual volume adjustments, sound pop, and HUD presentation asynchronously on the `MainActor` using `Task { @MainActor in ... }`. To avoid data races, we will cache the `mediaKeyControlEnabled` setting using a thread-safe `NSLock`.

**Tech Stack:** Swift Concurrency, CoreGraphics, AppKit

---

### Task 1: Add thread-safe caching for settings in `MediaKeyMonitor`

**Files:**
- Modify: [MediaKeyMonitor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Keys/MediaKeyMonitor.swift)

**Step 1: Write the cached fields and cache updates**
Add the lock and cache variables, and update them during initialization, start, and reconcile.

```swift
    // Add inside MediaKeyMonitor class:
    private let settingsLock = NSLock()
    private var cachedMediaKeyControlEnabled: Bool = false

    nonisolated var isMediaKeyControlEnabled: Bool {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return cachedMediaKeyControlEnabled
    }

    private func updateCachedSettings() {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        cachedMediaKeyControlEnabled = settingsManager.appSettings.mediaKeyControlEnabled
    }
```

Call `updateCachedSettings()` in `init`, `start()`, and `reconcile()`.

**Step 2: Compile to verify code correctness**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

---

### Task 2: Refactor `processSystemDefined` to be `nonisolated` and offload actor work

**Files:**
- Modify: [MediaKeyMonitor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Keys/MediaKeyMonitor.swift)

**Step 1: Modify `processSystemDefined` signature and implementation**
Change the signature to `nonisolated fileprivate func processSystemDefined(_ cgEvent: CGEvent) -> Bool`.
Update the check to use `isMediaKeyControlEnabled`.
Wrap `hudController.swallowObserved()` and `handle(...)` in a `Task { @MainActor in ... }`.

**Step 2: Update `mediaKeyTapCallback`**
Remove `MainActor.assumeIsolated` from the callback.
Call `monitor.processSystemDefined(event)` directly.
Call `monitor.handleTapDisabled()` inside a `Task { @MainActor in ... }`.

**Step 3: Compile to verify code correctness**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

---

### Task 3: Add unit tests for `processSystemDefined` asynchronous swallowing

**Files:**
- Modify: [MediaKeyMonitorHandlerTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/MediaKeyMonitorHandlerTests.swift)

**Step 1: Write test case simulating event tap callback**
Add a test case in `MediaKeyMonitorHandlerTests` that constructs a system-defined event using `NSEvent.otherEvent(...)`, retrieves its `cgEvent`, calls `processSystemDefined`, and verifies that the HUD show is triggered asynchronously.

```swift
    @Test("processSystemDefined swallows media key event and triggers HUD asynchronously")
    func processSystemDefinedSwallowsAndTriggersHUD() async throws {
        let (monitor, hud, _, _) = makeMonitor(popupVisible: false)
        
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: NSPoint.zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((10 << 16) | (0xa << 8)), // keyType=10 (SOUND_UP equivalent in this mock context)
            // Wait, IOKitMediaKeyDecoder expects keyType=0 for SOUND_UP, keyType=1 for SOUND_DOWN, keyType=7 for MUTE
            // Let's use keyType=0 (SOUND_UP):
            data1: Int((0 << 16) | (0xa << 8)),
            data2: -1
        )
        
        guard let cgEvent = event?.cgEvent else {
            Issue.record("Failed to create CGEvent")
            return
        }
        
        let decoder = monitor.decoder as! StubMediaKeyDecoder
        decoder.nextEvent = .volumeUp(isRepeat: false)
        
        let shouldSwallow = monitor.processSystemDefined(cgEvent)
        #expect(shouldSwallow == true)
        
        // Wait up to 1 second for the asynchronous MainActor Task to complete
        for _ in 0..<100 {
            if hud.showCallCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        
        #expect(hud.showCallCount == 1)
    }
```

**Step 2: Run tests to verify all tests pass**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS
