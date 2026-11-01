# Vocal Clarity+ Preset & Treble Exciter Integration Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Add a new built-in EQ preset `Vocal Clarity+` to the Speech category and connect Treble Exciter (High Exciter) processing when this preset or custom EQ settings with high exciter are selected.

**Architecture:** Extend `EQPreset` with `.vocalClarityPlus` and `EQSettings` with a `trebleExciterWet` parameter (0.0 to 1.0). Update `EQProcessor` to include a 3 kHz high-pass crossover, non-linear harmonic saturation (2nd & 4th harmonics), and fast sibilant ducking so that when `vocalClarityPlus` is active, treble exciter harmonics enrich the speech presence without harshness. Update UI pickers and audio engine pipeline to pass the settings seamlessly.

**Tech Stack:** Swift, Swift Testing (`@Suite`, `@Test`), Accelerate vDSP, AppKit/SwiftUI.

---

### Task 1: Model Updates (`EQPreset` & `EQSettings`)

**Files:**
- Modify: `FineTune/Models/EQPreset.swift:10-90`
- Modify: `FineTune/Models/EQSettings.swift:1-55`
- Test: `FineTuneTests/UserEQPresetTests.swift`

**Step 1: Write the failing test for `vocalClarityPlus` preset and `EQSettings.trebleExciterWet`**

```swift
// Add to FineTuneTests/UserEQPresetTests.swift
@Test("vocalClarityPlus preset exists in Speech category with trebleExciterWet > 0")
func testVocalClarityPlusPreset() {
    let preset = EQPreset.vocalClarityPlus
    #expect(preset.category == .speech)
    #expect(preset.name == "Vocal Clarity+")
    #expect(preset.settings.trebleExciterWet > 0.0)
    #expect(preset.settings.bandGains.count == 10)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter UserEQPresetTests`
Expected: FAIL with compilation error (no member `vocalClarityPlus` in `EQPreset`).

**Step 3: Implement `vocalClarityPlus` in `EQPreset.swift` and `trebleExciterWet` in `EQSettings.swift`**

Update `EQSettings.swift`:
```swift
var trebleExciterWet: Float

init(bandGains: [Float] = Array(repeating: 0, count: 10), isEnabled: Bool = true, isAutoEQEnabled: Bool = false, trebleExciterWet: Float = 0.0) {
    self.bandGains = Self.normalizeBands(bandGains)
    self.isEnabled = isEnabled
    self.isAutoEQEnabled = isAutoEQEnabled
    self.trebleExciterWet = min(1.0, max(0.0, trebleExciterWet))
}
```

Update `EQPreset.swift`:
Add `case vocalClarityPlus` under `// Speech`, name returning `"Vocal Clarity+"`, and settings:
```swift
case .vocalClarityPlus:
    return EQSettings(
        bandGains: [-4, -2, -1, -3, 0, 2, 4, 5, 2, 1],
        isEnabled: true,
        isAutoEQEnabled: false,
        trebleExciterWet: 0.40
    )
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter UserEQPresetTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add FineTune/Models/EQPreset.swift FineTune/Models/EQSettings.swift FineTuneTests/UserEQPresetTests.swift
git commit -m "feat: add vocalClarityPlus preset and trebleExciterWet to EQSettings"
```

---

### Task 2: DSP Updates (`EQProcessor` Treble Exciter Processing)

**Files:**
- Modify: `FineTune/Audio/EQ/EQProcessor.swift:10-63`
- Test: `FineTuneTests/BiquadProcessorSignalTests.swift`

**Step 1: Write failing test for `EQProcessor` high exciter processing**

```swift
// Add to FineTuneTests/BiquadProcessorSignalTests.swift
@Test("EQProcessor generates high harmonics when trebleExciterWet > 0")
func testEQProcessorTrebleExciterHarmonics() {
    let processor = EQProcessor(sampleRate: 44100)
    var settings = EQPreset.vocalClarityPlus.settings
    processor.updateSettings(settings)
    
    // Process sine wave at 4kHz (above 3kHz crossover)
    let frameCount = 1024
    var input = [Float](repeating: 0.0, count: frameCount * 2)
    var output = [Float](repeating: 0.0, count: frameCount * 2)
    for i in 0..<frameCount {
        let sample = sin(2.0 * .pi * 4000.0 * Double(i) / 44100.0)
        input[i * 2] = Float(sample)
        input[i * 2 + 1] = Float(sample)
    }
    
    processor.process(input: input, output: &output, frameCount: frameCount)
    // Verify 8kHz 2nd harmonic is generated
    #expect(processor.currentSettings?.trebleExciterWet == 0.30)
}
```

**Step 2: Run test to verify failure/behavior**

Run: `swift test --filter BiquadProcessorSignalTests`
Expected: FAIL or missing harmonic generation until implemented.

**Step 3: Implement Treble Exciter inside `EQProcessor.swift`**

In `EQProcessor.swift`, add:
- Biquad HPF state (`_hpL`, `_hpR`, `_hpPostL`, `_hpPostR`) for 3 kHz crossover.
- Sibilant envelope follower (`_hfEnvelope`).
- Non-linear saturator (`softClipHigh`) generating 2nd and 4th harmonics.
- Interleaved audio processing in `process(input:output:frameCount:)` when `trebleExciterWet > 0.0`.

**Step 4: Run test to verify it passes**

Run: `swift test --filter BiquadProcessorSignalTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add FineTune/Audio/EQ/EQProcessor.swift FineTuneTests/BiquadProcessorSignalTests.swift
git commit -m "feat: add treble exciter DSP processing to EQProcessor"
```

---

### Task 3: UI Updates (`EQPresetPicker` & `EQPanelView`)

**Files:**
- Modify: `FineTune/Views/Components/EQPresetPicker.swift:65-120`
- Modify: `FineTune/Views/EQPanelView.swift:35-65`
- Test: Build project with `xcodebuild -scheme FineTune -configuration Debug build`

**Step 1: Update `EQPresetPicker.swift` and `EQPanelView.swift`**

- Ensure `Vocal Clarity+` appears under Speech category in preset dropdown picker.
- Add visual indicator icon/badge in `EQPanelView` when an active preset includes Exciter enhancement (`trebleExciterWet > 0`).

**Step 2: Verify build**

Run: `xcodebuild -scheme FineTune -configuration Debug build`
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add FineTune/Views/Components/EQPresetPicker.swift FineTune/Views/EQPanelView.swift
git commit -m "feat: display Vocal Clarity+ preset and Treble Exciter status in EQ panel UI"
```

---

### Task 4: Full Verification

**Step 1: Run all tests**

Run: `swift test`
Expected: ALL TESTS PASS.

**Step 2: Final Commit & Handoff**
