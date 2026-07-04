# Instant Loudness Transition Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Remove the smooth loudness timbral transition ramping mechanism, making changes in volume and filter gains completely instant when toggling Loudness Compensation on/off.

**Architecture:** We will remove the asynchronous `rampLoudnessCompensation` method and the `volumeRampTasks` map. In `setLoudnessCompensationEnabled(for:enabled:)`, we will immediately apply the calculated target volume using `deviceVolumeMonitor.setVolume(for:to:)` and instantly scale the filters' gain scale to 1.0 (enabling) or 0.0 (disabling).

**Tech Stack:** Swift, Core Audio, XCTest

---

### Task 1: Update core implementation in AudioEngine.swift

**Files:**
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`

**Step 1: Write minimal implementation**
We will remove the `volumeRampTasks` property and its cleanups in `deinit` and `stop()`, delete `rampLoudnessCompensation`, and update `setLoudnessCompensationEnabled` to be instant.

Modify `FineTune/Audio/Engine/AudioEngine.swift`:
- Remove `private var volumeRampTasks: [String: Task<Void, Never>] = [:]` (around line 55)
- In `deinit` (around line 596), remove:
  ```swift
  for task in volumeRampTasks.values {
      task.cancel()
  }
  volumeRampTasks.removeAll()
  ```
- In `stop()` (around line 628), remove:
  ```swift
  for task in volumeRampTasks.values {
      task.cancel()
  }
  volumeRampTasks.removeAll()
  ```
- Remove `rampLoudnessCompensation(...)` method completely (lines 749-808).
- Rewrite `setLoudnessCompensationEnabled(for:enabled:)` to instantly apply volume and DSP updates:
  ```swift
  func setLoudnessCompensationEnabled(for deviceUID: String, enabled: Bool) {
      settingsManager.setLoudnessCompensationEnabled(for: deviceUID, to: enabled)
      let referencePhon = settingsManager.getLoudnessReferencePhon(for: deviceUID)
      
      if let device = deviceMonitor.device(for: deviceUID) {
          let b = outputVolumeBackend(for: device.id)
          if b == .hardware || b == .ddc {
              let currentVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
              let targetVolume: Float
              if enabled {
                  let offsetScalar: Float
                  if let existing = appliedLoudnessOffsets[deviceUID] {
                      offsetScalar = existing
                  } else {
                      let peakDB = computeHeadroomOffsetDB(for: deviceUID, systemVolume: currentVolume, referencePhon: referencePhon)
                      offsetScalar = Float(peakDB / 100.0)
                      appliedLoudnessOffsets[deviceUID] = offsetScalar
                  }
                  targetVolume = min(1.0, currentVolume + offsetScalar)
              } else {
                  let offsetScalar = appliedLoudnessOffsets[deviceUID] ?? 0.0
                  appliedLoudnessOffsets[deviceUID] = nil
                  targetVolume = max(0.0, currentVolume - offsetScalar)
              }
              deviceVolumeMonitor.setVolume(for: device.id, to: targetVolume)
          }
      }
      
      let gainScale: Float = enabled ? 1.0 : 0.0
      updateTapsLoudness(deviceUID: deviceUID, enabled: enabled, referencePhon: referencePhon, gainScale: gainScale)
  }
  ```

**Step 2: Commit intermediate changes**

```bash
git add FineTune/Audio/Engine/AudioEngine.swift
git commit -m "refactor: remove loudness transition ramping in AudioEngine"
```

---

### Task 2: Update and Verify Unit Tests

**Files:**
- Modify: `FineTuneTests/LoudnessVolumeCompensationTests.swift`

**Step 1: Rewrite unit tests for instant transition**
Update the test cases in `FineTuneTests/LoudnessVolumeCompensationTests.swift` to verify that there are no intermediate states (ramping) and that changes are applied immediately.

Modify `FineTuneTests/LoudnessVolumeCompensationTests.swift`:
Replace `togglingLoudnessAdjustsHardwareVolume()` and `togglingLoudnessDoesNotAdjustSoftwareVolume()` with versions that assert instant status without polling loops:

```swift
    @Test("Toggling loudness on hardware device adjusts system volume and scales filter gains instantly")
    func togglingLoudnessAdjustsHardwareVolume() async throws {
        let fix = makeFixture(backend: .hardware)
        
        // Setup tap for the app
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.clearEvents()
        
        // 1. Initial state
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        // 2. Enable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: true)
        
        // Volume should have increased instantly to compensate for digital headroom drop
        let volAfterEnable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(volAfterEnable > 0.5)
        
        let enableLoudnessEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
            if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                return (enabled, gainScale)
            }
            return nil
        }
        
        // Should have exactly one event or immediate final event
        #expect(!enableLoudnessEvents.isEmpty)
        // No intermediate updates with gainScale between 0.0 and 1.0 should exist
        let intermediateEnables = enableLoudnessEvents.filter { $0.gainScale > 0.0 && $0.gainScale < 1.0 }
        #expect(intermediateEnables.isEmpty)
        
        #expect(enableLoudnessEvents.last?.enabled == true)
        #expect(enableLoudnessEvents.last?.gainScale == 1.0)
        
        tap.clearEvents()
        
        // 3. Disable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: false)
        
        // Volume should return back to original 0.5 instantly
        let volAfterDisable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(abs(volAfterDisable - 0.5) < 0.001)
        
        let disableLoudnessEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
            if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                return (enabled, gainScale)
            }
            return nil
        }
        
        #expect(!disableLoudnessEvents.isEmpty)
        let intermediateDisables = disableLoudnessEvents.filter { $0.gainScale > 0.0 && $0.gainScale < 1.0 }
        #expect(intermediateDisables.isEmpty)
        
        #expect(disableLoudnessEvents.last?.enabled == false)
        #expect(disableLoudnessEvents.last?.gainScale == 0.0)
    }
    
    @Test("Toggling loudness on software device does NOT adjust system volume but still scales filter gains instantly")
    func togglingLoudnessDoesNotAdjustSoftwareVolume() async throws {
        let fix = makeFixture(backend: .software)
        
        // Setup tap for the app
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.clearEvents()
        
        // 1. Initial state
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        // 2. Enable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: true)
        
        // Volume must remain unchanged
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        let enableEvents = tap.events.compactMap { event -> Float? in
            if case let .updateLoudnessCompensation(_, true, _, gainScale) = event {
                return gainScale
            }
            return nil
        }
        
        #expect(!enableEvents.isEmpty)
        #expect(!enableEvents.contains { $0 > 0.0 && $0 < 1.0 })
        #expect(enableEvents.last == 1.0)
        
        tap.clearEvents()
        
        // 3. Disable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: false)
        
        let disableEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
            if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                return (enabled, gainScale)
            }
            return nil
        }
        
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        #expect(!disableEvents.isEmpty)
        #expect(!disableEvents.contains { $0.enabled && $0.gainScale > 0.0 && $0.gainScale < 1.0 })
        #expect(disableEvents.last?.enabled == false)
        #expect(disableEvents.last?.gainScale == 0.0)
    }
```

**Step 2: Run tests to verify they pass**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/LoudnessVolumeCompensationTests CODE_SIGN_IDENTITY="-"`
Expected: PASS

**Step 3: Commit and complete**

```bash
git add FineTuneTests/LoudnessVolumeCompensationTests.swift
git commit -m "test: update LoudnessVolumeCompensationTests for instant transition"
```
