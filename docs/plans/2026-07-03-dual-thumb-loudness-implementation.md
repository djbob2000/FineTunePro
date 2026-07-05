# Dual-Thumb Loudness Architecture Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement the dual-thumb range slider («Диапазон тонкомпенсации») in FineTune UI and DSP, supporting independent Start DB (0 to -12 dB) and Max/Plateau DB (-20 to -40 dB) parameters with automatic headroom correction.

**Architecture:** Update `LoudnessCompensator.swift` to accept `startDB` and `maxDB`, compute transition ratio $K$, and scale exciter wet gains. Create a custom SwiftUI `DualRangeSlider` component for `DeviceDetailSheet.swift` displaying dynamic human-readable volume percentages. Update `SettingsManager.swift` and `AudioEngine.swift` to persist and pass `startDB` and `maxDB`.

**Tech Stack:** Swift 6, SwiftUI, Accelerate vDSP, XCTest / Swift Testing.

---

### Task 1: Update SettingsManager and AudioEngine Plumbing for StartDB & MaxDB

**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift`
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`
- Modify: `FineTune/Audio/Engine/TapInitialState.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift`
- Test: `FineTuneTests/ISO226ContoursTests.swift`

**Step 1: Write unit test for StartDB & MaxDB persistence and tap controller plumbing**

```swift
@Test("SettingsManager stores and retrieves startDB and maxDB correctly")
func settingsManagerStartAndMaxDB() {
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory)
    #expect(settings.getLoudnessStartDB(for: "dev1") == 0.0)
    #expect(settings.getLoudnessMaxDB(for: "dev1") == -20.0)
    
    settings.setLoudnessStartDB(for: "dev1", to: -6.0)
    settings.setLoudnessMaxDB(for: "dev1", to: -30.0)
    
    #expect(settings.getLoudnessStartDB(for: "dev1") == -6.0)
    #expect(settings.getLoudnessMaxDB(for: "dev1") == -30.0)
}
```

**Step 2: Add startDB and maxDB accessors to SettingsManager.swift**

```swift
func getLoudnessStartDB(for deviceUID: String) -> Double {
    let val = settings.deviceLoudnessReferencePhon[deviceUID] ?? 0.0
    return min(0.0, max(-12.0, val > 0 ? 0.0 : val))
}

func setLoudnessStartDB(for deviceUID: String, to db: Double) {
    settings.deviceLoudnessReferencePhon[deviceUID] = min(0.0, max(-12.0, db))
}

func getLoudnessMaxDB(for deviceUID: String) -> Double {
    let val = settings.deviceLoudnessMaxDB[deviceUID] ?? -20.0
    return min(-20.0, max(-40.0, val))
}

func setLoudnessMaxDB(for deviceUID: String, to db: Double) {
    settings.deviceLoudnessMaxDB[deviceUID] = min(-20.0, max(-40.0, db))
}
```

**Step 3: Run unit tests to verify**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: PASS

---

### Task 2: Implement Piecewise Dual-Point Loudness Transition in LoudnessCompensator.swift

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Write unit test for dual-point piecewise transition**

```swift
@Test("Dual point transition starts at startDB and plateaus at maxDB")
func dualPointLoudnessTransition() {
    let processor = LoudnessCompensator(sampleRate: 48000.0)
    
    // With startDB = -6.0 dB (~75% vol) and maxDB = -20.0 dB (50% vol)
    // At system volume 0.9 (approx -4 dB > -6 dB), exciter wet should be 0.0
    processor.updateForVolume(0.9, gainScale: 0.65, trebleGainScale: 0.65, startDB: -6.0, maxDB: -20.0)
    #expect(processor.lowExciterWet == 0.0)
    
    // At system volume 0.5 (-20 dB), max boost is reached
    processor.updateForVolume(0.5, gainScale: 0.65, trebleGainScale: 0.65, startDB: -6.0, maxDB: -20.0)
    let lowAt05 = processor.lowExciterWet
    #expect(lowAt05 > 1.0)
    
    // At system volume 0.1 (-36 dB < -20 dB), gain plateaus at lowAt05
    processor.updateForVolume(0.1, gainScale: 0.65, trebleGainScale: 0.65, startDB: -6.0, maxDB: -20.0)
    #expect(processor.lowExciterWet == lowAt05)
}
```

**Step 2: Update updateForVolume in LoudnessCompensator.swift**

```swift
let linearVol = max(Double(systemVolume), 0.0001)
let volDB = 40.0 * (linearVol - 1.0)

let sDB = min(0.0, max(-12.0, startDB))
let mDB = min(-20.0, max(-40.0, maxDB))

let K: Double
if volDB >= sDB {
    K = 0.0
} else if volDB <= mDB {
    K = 1.0
} else {
    K = (sDB - volDB) / (sDB - mDB)
}
```

**Step 3: Run unit tests to verify**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: PASS

---

### Task 3: Implement Dual-Thumb SwiftUI Slider in DeviceDetailSheet.swift

**Files:**
- Create/Modify: `FineTune/Views/Sheets/DeviceDetailSheet.swift`

**Step 1: Build custom DualRangeSlider component in DeviceDetailSheet.swift**

Render a track with two interactive thumbs ("Максимум" for left, "Старт" for right) and dynamic text:
`"Чистый звук выше \(startVolPct)% громкости. Максимальный подъем тише \(maxVolPct)% громкости."`

**Step 2: Build and verify application**

Run: `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: BUILD SUCCEEDED

---
