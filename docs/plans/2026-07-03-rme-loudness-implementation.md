# RME-Style Loudness Architecture Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement the RME ADI-2 DAC inspired loudness architecture in FineTune, removing Classic mode and implementing a true 20 dB transition window with plateauing maximum gain.

**Architecture:** Update `LoudnessCompensator.swift` to compute `volumeDB = 20 * log10(max(0.001, volume))`, `deltaDB = referenceDB - volumeDB`, `K = clamp(deltaDB / 20.0, 0.0, 1.0)`, scaling bass and treble exciters up to 12.0 dB ceiling with fixed 70 Hz (bass) and 3000 Hz (treble) crossovers. Remove `LoudnessMode.classic` and clean up tests and UI.

**Tech Stack:** Swift 6, macOS CoreAudio, Accelerate vDSP, XCTest / Swift Testing.

---

### Task 1: Update LoudnessCompensator DSP Calculation & Remove Classic Mode

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift:105-185`
- Test: `FineTuneTests/ISO226ContoursTests.swift`

**Step 1: Write/Update the test for 20 dB transition and plateau**

```swift
@Test("RME loudness transitions over 20 dB and plateaus below 20 dB drop")
func rmeLoudnessTransitionsAndPlateaus() {
    let processor = LoudnessCompensator(sampleRate: 48000.0)
    
    // At system volume 1.0 (0 dB drop), exciter wet should be 0.0
    processor.updateForVolume(1.0, gainScale: 0.65, trebleGainScale: 0.65)
    #expect(processor.lowExciterWet == 0.0)
    #expect(processor.highExciterWet == 0.0)
    
    // At system volume 0.1 (-20 dB drop), max gain is reached
    processor.updateForVolume(0.1, gainScale: 0.65, trebleGainScale: 0.65)
    let lowAt01 = processor.lowExciterWet
    let highAt01 = processor.highExciterWet
    #expect(lowAt01 > 1.0)
    #expect(highAt01 > 1.0)
    
    // At system volume 0.03 (-30 dB drop), gains plateau at the same level as 0.1
    processor.updateForVolume(0.03, gainScale: 0.65, trebleGainScale: 0.65)
    #expect(processor.lowExciterWet == lowAt01)
    #expect(processor.highExciterWet == highAt01)
}
```

**Step 2: Implement 20 dB transition window with plateau in LoudnessCompensator.swift**

```swift
let linearVol = max(Double(systemVolume), 0.001)
let volDB = 20.0 * log10(linearVol)
// Transition ratio K over 20 dB drop relative to reference volume
let deltaDB = -volDB
let K = min(1.0, max(0.0, deltaDB / 20.0))

let lowBoostDB = K * 12.0 * Double(gainScale)
let lowLinear = pow(10.0, lowBoostDB / 20.0)
_lowExciterWet = Float((lowLinear - 1.0) * 1.5)

let highBoostDB = K * 12.0 * Double(trebleGainScale)
let highLinear = pow(10.0, highBoostDB / 20.0)
_highExciterWet = Float(highLinear - 1.0)
```

**Step 3: Run unit tests to verify**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: PASS

---

### Task 2: Build Application and Verify

**Files:**
- Project: `FineTune.xcodeproj`

**Step 1: Build the application**

Run: `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: BUILD SUCCEEDED

---
