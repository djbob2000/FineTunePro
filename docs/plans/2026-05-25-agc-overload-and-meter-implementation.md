# AGC Overload and Level Meter Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Correct the audio signal chain order by applying app volume after AGC/compression to prevent clipping, and add real-time output peak levels and post-AGC compression ("clip") indicators to the settings UI.

**Architecture:** 
1. Perform channel-mapping copy at unity gain in `ProcessTapController.swift`.
2. Apply ramping application volume gain *after* the compressor stage.
3. Track and smooth output peak levels after the `SoftLimiter` in the audio thread.
4. Expose gain reduction from `PostAgcCompressor` and use it to flag active compression.
5. Aggregate maximum output level and active compression state in `AudioEngine`.
6. Add a polling loop, a compact VU meter, and a clip LED indicator dot in SwiftUI `AudioTab`.

**Tech Stack:** Swift, CoreAudio, SwiftUI

---

### Task 1: Expose Gain Reduction from PostAgcCompressor

**Files:**
* Modify: [PostAgcCompressor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/PostAgcCompressor.swift)
* Test: [PostAgcCompressorTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/PostAgcCompressorTests.swift)

**Step 1: Write the test**
Open `FineTuneTests/PostAgcCompressorTests.swift` and check if we can verify the exposed gain reduction. Since it's a new property, add a simple check in an existing test or a new test.
```swift
    @Test("Exposed gain reduction property matches internal state")
    func testExposedGainReduction() {
        let compressor = PostAgcCompressor(settings: PostAgcCompressorSettings(thresholdDb: -10.0, ratio: 4.0, attackMs: 1.0, releaseMs: 100.0, kneeDb: 0.0), sampleRate: 44100)
        #expect(compressor.currentGainReductionDb == 0.0)
    }
```

**Step 2: Run test to verify it fails**
Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/PostAgcCompressorTests test`
Expected: Compile failure ("currentGainReductionDb not found")

**Step 3: Write minimal implementation**
In `FineTune/Audio/Loudness/PostAgcCompressor.swift`, add:
```swift
    /// Current gain reduction in dB (≤ 0). Main-thread read, RT-thread write.
    var currentGainReductionDb: Float { gainReductionDb }
```

**Step 4: Run test to verify it passes**
Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/PostAgcCompressorTests test`
Expected: PASS

**Step 5: Commit**
```bash
git add FineTune/Audio/Loudness/PostAgcCompressor.swift FineTuneTests/PostAgcCompressorTests.swift
git commit -m "feat: expose currentGainReductionDb from PostAgcCompressor"
```

---

### Task 2: Shift Volume Gain Application in ProcessTapController

**Files:**
* Modify: [ProcessTapController.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/ProcessTapController.swift)
* Test: [ProcessingPipelineTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/ProcessingPipelineTests.swift)

**Step 1: Modify ProcessTapController processing loop**
In `ProcessTapController.swift`, rewrite lines 1175–1244 in `processMappedBuffers`:
* Change `outputSamples[...] = inputSamples[...] * gain` to copy the inputs directly (`outputSamples[...] = inputSamples[...]` or `initialize(from:)`).
* After the compressor block (approx line 1263), add a loop to apply the volume/crossfade ramp:
```swift
            // Apply volume slider gain & crossfade multiplier (ramped per frame)
            for frame in 0..<frameCount {
                currentVol += (targetVol - currentVol) * rampCoefficient
                let gain = currentVol * crossfadeMultiplier
                let base = frame * outputChannels
                for ch in 0..<outputChannels {
                    outputSamples[base + ch] *= gain
                }
            }
```

**Step 2: Run existing tests to verify correctness**
Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/ProcessingPipelineTests test`
Expected: PASS

**Step 3: Commit**
```bash
git add FineTune/Audio/Engine/ProcessTapController.swift
git commit -m "refactor: apply volume gain after AGC and compressor in processing pipeline"
```

---

### Task 3: Track Output Peak Level and Compression Status in ProcessTapController

**Files:**
* Modify: [ProcessTapController.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/ProcessTapController.swift)
* Modify: [ProcessTapControlling.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/ProcessTapControlling.swift)
* Test: [ProcessingPipelineTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/ProcessingPipelineTests.swift)

**Step 1: Expose properties in ProcessTapControlling protocol**
In `FineTune/Audio/Engine/ProcessTapControlling.swift`, add:
```swift
    var outputAudioLevel: Float { get }
    var isPostAgcCompressing: Bool { get }
```

**Step 2: Implement output tracking and properties in ProcessTapController**
In `ProcessTapController.swift`:
* Declare the nonisolated variables:
  ```swift
  private nonisolated(unsafe) var _outputPeakLevel: Float = 0.0
  private nonisolated(unsafe) var _secondaryOutputPeakLevel: Float = 0.0
  ```
* Implement the properties:
  ```swift
  var outputAudioLevel: Float {
      crossfadeState.isActive ? max(_outputPeakLevel, _secondaryOutputPeakLevel) : _outputPeakLevel
  }

  var isPostAgcCompressing: Bool {
      if let compressor = postAgcCompressorProcessor, compressor.isEnabled {
          return compressor.currentGainReductionDb < -0.1
      }
      if let secCompressor = secondaryPostAgcCompressorProcessor, secCompressor.isEnabled {
          return secCompressor.currentGainReductionDb < -0.1
      }
      return false
  }
  ```
* In `processMappedBuffers`, after `SoftLimiter.processBuffer(outputSamples, sampleCount: writtenSampleCount)` (approx line 1271), add:
  ```swift
            var outMaxPeak: Float = 0.0
            for i in 0..<writtenSampleCount {
                let absSample = abs(outputSamples[i])
                if absSample > outMaxPeak { outMaxPeak = absSample }
            }
            let rawOutPeak = min(outMaxPeak, 1.0)
            if isPrimary {
                _outputPeakLevel = _outputPeakLevel + levelSmoothingFactor * (rawOutPeak - _outputPeakLevel)
            } else {
                _secondaryOutputPeakLevel = _secondaryOutputPeakLevel + levelSmoothingFactor * (rawOutPeak - _secondaryOutputPeakLevel)
            }
  ```

**Step 3: Write tests verifying output level tracking**
In `FineTuneTests/ProcessingPipelineTests.swift`, add a test to verify output audio level is non-zero when playing audio and zero when muted.
```swift
    @Test("Output audio level is computed correctly")
    func testOutputAudioLevel() {
        // Feed signal, run processMappedBuffers, assert controller.outputAudioLevel > 0.0
    }
```

**Step 4: Run tests to verify they pass**
Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/ProcessingPipelineTests test`
Expected: PASS

**Step 5: Commit**
```bash
git add FineTune/Audio/Engine/ProcessTapController.swift FineTune/Audio/Engine/ProcessTapControlling.swift FineTuneTests/ProcessingPipelineTests.swift
git commit -m "feat: track output peak level and compression status in ProcessTapController"
```

---

### Task 4: Expose Output Peak and Compression in AudioEngine

**Files:**
* Modify: [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift)

**Step 1: Implement aggregate properties**
In `FineTune/Audio/Engine/AudioEngine.swift`, add:
```swift
    @objc var maxOutputLevel: Float {
        taps.values.map { $0.outputAudioLevel }.max() ?? 0.0
    }

    @objc var isPostAgcCompressing: Bool {
        taps.values.contains { $0.isPostAgcCompressing }
    }
```

**Step 2: Run build to verify compilation**
Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
Expected: Build Succeeded

**Step 3: Commit**
```bash
git add FineTune/Audio/Engine/AudioEngine.swift
git commit -m "feat: expose maxOutputLevel and isPostAgcCompressing in AudioEngine"
```

---

### Task 5: Implement UI level meter and clip dot in AudioTab

**Files:**
* Modify: [AudioTab.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/Settings/Tabs/AudioTab.swift)

**Step 1: Add SwiftUI components next to the AGC Toggle**
In `AudioTab.swift`, replace the Toggle settings row for Auto Gain Control:
* Place the Toggle, a custom compact VU meter, and a clip indicator dot inside an `HStack` aligned to the right.
* Declare local `@State` variables:
  ```swift
  @State private var outputLevel: Float = 0.0
  @State private var isClipping: Bool = false
  @State private var clipResetTask: Task<Void, Never>? = nil
  ```
* Implement the `.task` loop polling at ~30Hz (every 33ms):
  ```swift
  .task {
      while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(33))
          let level = audioEngine.maxOutputLevel
          outputLevel = level
          
          if audioEngine.isPostAgcCompressing {
              clipResetTask?.cancel()
              isClipping = true
              clipResetTask = Task {
                  try? await Task.sleep(for: .milliseconds(500))
                  if !Task.isCancelled {
                      withAnimation(.easeOut(duration: 0.3)) {
                          isClipping = false
                      }
                  }
              }
          }
      }
  }
  ```

**Step 2: Build and run compilation**
Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
Expected: Build Succeeded

**Step 3: Commit**
```bash
git add FineTune/Views/Settings/Tabs/AudioTab.swift
git commit -m "ui: add output VU meter and clip indicator dot to Auto Gain Control settings"
```

---

### Task 6: Final Verification

**Step 1: Run all unit tests**
Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests test`
Expected: PASS

**Step 2: Commit final task updates**
Update `task.md` to mark all tasks as completed, then commit.
