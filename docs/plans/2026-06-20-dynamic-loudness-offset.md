# Dynamic Loudness Offset Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement dynamic headroom offset calculation for Loudness Compensation so that the offset scales down to exactly 0.0 at 100% volume, ensuring the DSP is bypassed and does not affect the sound at maximum level.

**Architecture:** We will modify the volume change listener in `AudioEngine.swift` to solve the implicit offset equation $V_{hw} = V_{user} + \text{offset}(V_{user})$ using 3 iterations of a numerical solver. We will also update the offset dynamically when the Reference Phon is modified.

**Tech Stack:** Swift, CoreAudio, Swift Testing

---

### Task 1: Add a failing test for dynamic loudness offset convergence

**Files:**
- Modify: [LoudnessVolumeCompensationTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/LoudnessVolumeCompensationTests.swift:203)

**Step 1: Write the failing test**

Append the following test case inside the `LoudnessVolumeCompensationTests` struct:

```swift
    @Test("Dynamic loudness offset converges to zero at 100% volume")
    func dynamicOffsetConvergesToZero() async throws {
        let fix = makeFixture(backend: .hardware)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        
        // 1. Enable loudness at 50% volume (0.5)
        fix.deviceVolume.volumes[fix.device.id] = 0.5
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: true)
        try await Task.sleep(nanoseconds: 10_000_000)
        
        // Verify that offset was computed and system volume was boosted
        let volAfterEnable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(volAfterEnable > 0.5)
        
        // 2. Set hardware volume to 1.0 (representing dragging the slider to 100%)
        // Trigger the onVolumeChanged callback (mocking OS notification)
        fix.deviceVolume.volumes[fix.device.id] = 1.0
        fix.deviceVolume.onVolumeChanged?(fix.device.id, 1.0)
        try await Task.sleep(nanoseconds: 10_000_000)
        
        // Offset should have updated dynamically to 0.0, and DSP should be bypassed
        let tap = try #require(fix.lastTap())
        let loudnessEvents = tap.events.compactMap { event -> (enabled: Bool, volume: Float)? in
            if case let .updateLoudnessCompensation(vol, enabled, _, _) = event {
                return (enabled, vol)
            }
            return nil
        }
        
        #expect(!loudnessEvents.isEmpty)
        let lastEvent = try #require(loudnessEvents.last)
        #expect(lastEvent.enabled == false) // Bypassed
        #expect(abs(lastEvent.volume - 1.0) < 0.001) // Original volume is 1.0
    }
```

**Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination platform=macOS -only-testing FineTuneTests/LoudnessVolumeCompensationTests/dynamicOffsetConvergesToZero CODE_SIGN_IDENTITY="-"
```
Expected: **FAIL** (DSP remains enabled, volume is 0.92 instead of 1.0, because the offset did not update dynamically).

---

### Task 2: Implement dynamic offset calculation on volume changes and reference phon updates

**Files:**
- Modify: [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift)

**Step 1: Write minimal implementation**

1. Modify the `deviceVolumeMonitor.onVolumeChanged` block in `wireCallbacks()` (around lines 321-341) to recalculate the headroom offset dynamically:

```swift
        deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            let loudnessEnabled = self.settingsManager.getLoudnessCompensationEnabled(for: deviceUID)
            
            if loudnessEnabled {
                let referencePhon = self.settingsManager.getLoudnessReferencePhon(for: deviceUID)
                var originalVolume = newVolume
                var currentOffset: Float = 0.0
                for _ in 0..<3 {
                    originalVolume = max(0.0, min(1.0, newVolume - currentOffset))
                    let peakDB = self.computeHeadroomOffsetDB(for: deviceUID, systemVolume: originalVolume, referencePhon: referencePhon)
                    currentOffset = Float(peakDB / 100.0)
                }
                self.appliedLoudnessOffsets[deviceUID] = currentOffset
            }
            
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.currentDeviceVolume = newVolume
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                    let referencePhon = self.settingsManager.getLoudnessReferencePhon(for: deviceUID)
                    tap.updateLoudnessCompensation(
                        volume: self.effectiveLoudnessVolume(for: tap),
                        enabled: loudnessEnabled,
                        referencePhon: referencePhon,
                        gainScale: loudnessEnabled ? 1.0 : 0.0
                    )
                }
            }
        }
```

2. Modify `setLoudnessReferencePhon(for:to:)` (around lines 888-900) to also recalculate the offset when the reference level changes:

```swift
    func setLoudnessReferencePhon(for deviceUID: String, to referencePhon: Double) {
        settingsManager.setLoudnessReferencePhon(for: deviceUID, to: referencePhon)
        let enabled = settingsManager.getLoudnessCompensationEnabled(for: deviceUID)
        
        if enabled, let device = deviceMonitor.device(for: deviceUID) {
            let currentVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            var originalVolume = currentVolume
            var currentOffset: Float = 0.0
            for _ in 0..<3 {
                originalVolume = max(0.0, min(1.0, currentVolume - currentOffset))
                let peakDB = computeHeadroomOffsetDB(for: deviceUID, systemVolume: originalVolume, referencePhon: referencePhon)
                currentOffset = Float(peakDB / 100.0)
            }
            appliedLoudnessOffsets[deviceUID] = currentOffset
        }
        
        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            tap.updateLoudnessCompensation(
                volume: effectiveLoudnessVolume(for: tap),
                enabled: enabled,
                referencePhon: referencePhon,
                gainScale: enabled ? 1.0 : 0.0
            )
        }
    }
```

**Step 2: Run test to verify it passes**

Run:
```bash
xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination platform=macOS -only-testing FineTuneTests/LoudnessVolumeCompensationTests/dynamicOffsetConvergesToZero CODE_SIGN_IDENTITY="-"
```
Expected: **PASS**

**Step 3: Run the full test suite**

Run:
```bash
xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination platform=macOS CODE_SIGN_IDENTITY="-"
```
Expected: **PASS** (UITests runner might fail due to signing as usual, but all Unit Tests should pass).

**Step 4: Commit**

```bash
git add FineTune/Audio/Engine/AudioEngine.swift FineTuneTests/LoudnessVolumeCompensationTests.swift
git commit -m "feat: implement dynamic loudness headroom offset calculation"
```
