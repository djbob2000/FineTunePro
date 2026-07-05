# Code Review Fixes Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Fix three code review findings: (1) Smart Volume stickiness on device switch in `AudioEngine.swift`, (2) ignored `kneeDb` settings in `PostAgcCompressor.swift`, and (3) RT-safety contract violations for non-stereo channel counts in `PostAgcCompressor.swift`.

**Architecture:** 
- Add a helper `applyLoudnessEqualizationToTap(_:)` to query the settings manager and apply settings, then hook it into every device switch and update path in `AudioEngine`.
- Update `CompressorBand` to accept, store, and utilize the `kneeDb` setting instead of hardcoding `0.1`.
- Narrow the `PostAgcCompressor.process` method to only process stereo inputs (channelCount == 2), bypass other channel counts using `memcpy` (passthrough), and remove dynamic array resize logic to achieve zero heap allocation.

**Tech Stack:** Swift, Swift Testing, CoreAudio/AudioToolbox.

---

### Task 1: Fix Smart Volume Switch Stickiness

**Files:**
- Modify: [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift:940-1490)
- Test: [AudioEngineTapInitialStateTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/AudioEngineTapInitialStateTests.swift:410-417)

**Step 1: Write the failing test**

Add the following tests at the end of the `AudioEngineTapInitialStateTests` struct in [AudioEngineTapInitialStateTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/AudioEngineTapInitialStateTests.swift):
```swift
    @Test("Smart Volume settings are re-applied to tap after device switches")
    func smartVolumeReappliedOnSwitch() async throws {
        let fix = makeFixture()
        let secondDevice = AudioDevice(
            id: AudioDeviceID(100),
            uid: "uid-second",
            name: "Second Output",
            icon: nil,
            supportsAutoEQ: true
        )
        fix.deviceMonitor.addOutputDevice(secondDevice)
        
        // 1. Initial routing (device is "uid-test", loudness equalization default is false)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.clearEvents()
        
        // 2. Enable loudness equalization for the second device
        fix.settings.setLoudnessEqualizationEnabled(for: secondDevice.uid, to: true)
        
        // 3. Switch device to the second device
        fix.engine.setDevice(for: fix.app, deviceUID: secondDevice.uid)
        
        // Allow tasks to run
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // 4. Verify that .updateLoudnessEqualization(enabled: true) was called on the tap
        let loudnessEvents = tap.events.compactMap { event -> LoudnessEqualizerSettings? in
            if case let .updateLoudnessEqualization(settings) = event { return settings }
            return nil
        }
        #expect(loudnessEvents.contains(where: { $0.enabled == true }))
    }
```

**Step 2: Run test to verify it fails**

Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests/AudioEngineTapInitialStateTests/smartVolumeReappliedOnSwitch CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: FAIL (no `.updateLoudnessEqualization` event received because it is not re-applied).

**Step 3: Write minimal implementation**

Modify [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift):
1. Add `applyLoudnessEqualizationToTap` private helper method:
```swift
    private func applyLoudnessEqualizationToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }
        var settings = LoudnessEqualizerSettings()
        settings.enabled = settingsManager.getLoudnessEqualizationEnabled(for: deviceUID)
        tap.updateLoudnessEqualization(settings)
    }
```
2. Insert calls to `self.applyLoudnessEqualizationToTap(tap)` (or `self.applyLoudnessEqualizationToTap(existingTap)`) right after `self.applyAutoEQToTap(...)` in:
- `setDevice(for:deviceUID:)`
- `updateTapForCurrentMode(for:)` (also add `applyAutoEQToTap(tap)` here)
- `applyPersistedSettings()`
- `routeFollowsDefaultApps(to:)`
- `handleDeviceDisconnected(_:name:)` (for single-mode switch, and also for multi-mode updates add both `applyAutoEQToTap` and `applyLoudnessEqualizationToTap`)
- `handleDeviceConnected(_:name:)`

**Step 4: Run test to verify it passes**

Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests/AudioEngineTapInitialStateTests/smartVolumeReappliedOnSwitch CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 5: Commit**

```bash
rtk git commit -am "fix: re-apply Smart Volume settings when device switches or updates"
```

---

### Task 2: Fix Ignored kneeDb Setting in Compressor

**Files:**
- Modify: [PostAgcCompressor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/PostAgcCompressor.swift:29-140)
- Test: [PostAgcCompressorTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/PostAgcCompressorTests.swift:137-176)

**Step 1: Write the failing test**

Modify the test `"Soft-knee transition math is correct"` or add a new test verifying that configuring `kneeDb` actually changes the compression output (specifically, a large `kneeDb` of 6.0 should result in lower gain reduction inside the knee area compared to `kneeDb` of 0.0, which we can test by asserting the difference or asserting specific gain reduction values).
Let's add a test:
```swift
    @Test("Knee width is respected and changes gain reduction curve")
    func kneeWidthRespected() {
        // High knee (kneeDb = 6.0) vs hard knee (kneeDb = 0.0)
        let softSettings = PostAgcCompressorSettings(
            thresholdDb: -10.0,
            ratio: 4.0,
            attackMs: 0.01,
            kneeDb: 6.0,
            exponentialRelease: 0.0,
            maxReleaseSpeed: 1.0,
            enabled: true
        )
        let hardSettings = PostAgcCompressorSettings(
            thresholdDb: -10.0,
            ratio: 4.0,
            attackMs: 0.01,
            kneeDb: 0.0,
            exponentialRelease: 0.0,
            maxReleaseSpeed: 1.0,
            enabled: true
        )
        
        let softCompressor = PostAgcCompressor(settings: softSettings, sampleRate: 48000)
        let hardCompressor = PostAgcCompressor(settings: hardSettings, sampleRate: 48000)
        
        // Input signal inside knee region: e.g. -11 dBFS (overshoot <= 0 but within soft knee of 6 dB: [-13, -7])
        // With hard knee, this is below threshold so gain reduction is exactly 0 dB (passthrough, 1.0 gain).
        // With soft knee, this is inside the knee region so it should experience some gain reduction (< 1.0).
        let ampInsideKnee = LoudnessEqualizerMath.dbToLinear(-11.0)
        var input = [Float](repeating: 0, count: 20)
        for i in 0..<10 {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(i) / Double(48000.0))
            let val = ampInsideKnee * sin(phase)
            input[i * 2] = val
            input[i * 2 + 1] = val
        }
        var softOutput = [Float](repeating: 0, count: 20)
        var hardOutput = [Float](repeating: 0, count: 20)
        
        for _ in 0..<50 {
            softCompressor.process(input: &input, output: &softOutput, frameCount: 10, channelCount: 2)
            hardCompressor.process(input: &input, output: &hardOutput, frameCount: 10, channelCount: 2)
        }
        
        var softMaxPeak: Float = 0
        var hardMaxPeak: Float = 0
        for i in 0..<20 {
            let sVal = abs(softOutput[i])
            let hVal = abs(hardOutput[i])
            if sVal > softMaxPeak { softMaxPeak = sVal }
            if hVal > hardMaxPeak { hardMaxPeak = hVal }
        }
        
        // Assert that the soft-knee compressor compressed (reduced gain), while hard-knee did not.
        #expect(softMaxPeak < hardMaxPeak - 0.001)
    }
```

**Step 2: Run test to verify it fails**

Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests/PostAgcCompressorTests/kneeWidthRespected CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: FAIL (both peaks are equal because soft knee's 6.0 is ignored and defaults to hard knee's 0.1).

**Step 3: Write minimal implementation**

Modify [PostAgcCompressor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/PostAgcCompressor.swift):
1. Update `CompressorBand`:
   - Add `let kneeDb: Float` property.
   - Update `init` parameter list to take `kneeDb: Float` and store it: `self.kneeDb = kneeDb`.
   - Update `updateSampleRate(_:)` to set `self.kneeHalfDb = kneeDb * 0.5`.
   - Update `calculateGainReduction(levelDb:globalThresholdDb:)` to remove `let kneeDb: Float = 0.1` and use `self.kneeDb`.
2. Update `PostAgcCompressor.init(settings:sampleRate:)` to pass `settings.kneeDb` when constructing `band1`, `band2`, and `band3`.

**Step 4: Run test to verify it passes**

Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests/PostAgcCompressorTests/kneeWidthRespected CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 5: Commit**

```bash
rtk git commit -am "fix: store and apply kneeDb setting in PostAgcCompressor bands"
```

---

### Task 3: RT-Safety Contract and Channel Count

**Files:**
- Modify: [PostAgcCompressor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/PostAgcCompressor.swift:184-194)
- Test: [PostAgcCompressorTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/PostAgcCompressorTests.swift:253-267)

**Step 1: Write the failing test**

Add a test for channelCount != 2:
```swift
    @Test("Non-stereo channel count is safely bypassed without allocating arrays")
    func nonStereoPassthrough() {
        let settings = PostAgcCompressorSettings(thresholdDb: -10.0, enabled: true)
        let compressor = PostAgcCompressor(settings: settings, sampleRate: 48000)
        
        let input: [Float] = [0.5, 0.5, 0.5, 0.5]
        var output = [Float](repeating: 0, count: 4)
        
        // Call process with channelCount = 4 (which is not stereo)
        compressor.process(input: input, output: &output, frameCount: 1, channelCount: 4)
        
        // Non-stereo should be bypassed (exact copy of input)
        #expect(output == input)
    }
```

**Step 2: Run test to verify it fails/passes**

Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests/PostAgcCompressorTests/nonStereoPassthrough CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: Passes but allocates memory under the hood (due to count mismatch).

**Step 3: Write minimal implementation**

Modify [PostAgcCompressor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/PostAgcCompressor.swift):
1. In `process(input:output:frameCount:channelCount:)`, add the channel check at the beginning:
```swift
        // Narrow API contract to strictly 2 channels (stereo). If channelCount is not 2,
        // bypass and copy input directly to output without allocating any resources.
        guard channelCount == 2 else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * channelCount * MemoryLayout<Float>.size)
            }
            return
        }
```
2. Remove the array resize block:
```swift
        if crossover200Hz.count != channelCount {
            crossover200Hz = (0..<channelCount).map { _ in LinkwitzRileyCrossover2(frequency: 200.0, sampleRate: Double(sampleRate)) }
            crossover77Hz = (0..<channelCount).map { _ in LinkwitzRileyCrossover2(frequency: 77.0, sampleRate: Double(sampleRate)) }
            band1Samples = [Float](repeating: 0, count: channelCount)
            band2Samples = [Float](repeating: 0, count: channelCount)
            band3Samples = [Float](repeating: 0, count: channelCount)
        }
```
3. Update the method comment to specify the stereo restriction.

**Step 4: Run test to verify it passes**

Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests/PostAgcCompressorTests/nonStereoPassthrough CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS (and zero heap allocation occurs)

**Step 5: Commit**

```bash
rtk git commit -am "perf: enforce stereo-only processing in PostAgcCompressor to ensure allocation-free RT-safety"
```
