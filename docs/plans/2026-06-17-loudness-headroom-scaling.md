# Loudness Compensator: 3-Band Linear Mapping Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Modify the system volume-to-phon steepness exponent from 0.5 to 1.0 (linear), remove the 80 Hz low-shelf filter (which creates the sub-bass shelf below 80 Hz), keep the formula-based headroom subtraction, and restrict Boost to the original 250% (2.5) limit.

**Architecture:** 
1. Modify `estimatedPhon` in `ISO226Contours.swift` to use a linear mapping by changing `pow(v, 0.5)` to `v`.
2. Remove `.init(kind: .lowShelf, frequency: 80, q: 0.707)` from `filterDefinitions` in `LoudnessCompensator.swift`, reducing the filter cascade to 3 sections (180 Hz, 3.2 kHz, 10 kHz). This removes the sub-bass boost below 80 Hz.
3. Keep the original formula-based headroom subtraction (`peakDB = max(realized.max() ?? 0.0, 0.0)`) and make sure Boost remains clamped to `2.5` (250%).
4. Update the test suites to reflect `bandCount == 3` and the new midpoint for linear estimated phon.

---

### Task 116: Set Linear Volume-to-Phon Mapping (Steepness 1.0)

**Files:**
- Modify: `FineTune/Audio/Loudness/ISO226Contours.swift:63-67`
- Modify: `FineTuneTests/ISO226ContoursTests.swift:318-323`

**Step 1: Write a failing test in ISO226ContoursTests.swift**
Update `quarterVolumeMidpoint` to expect 35 phon (linear midpoint) instead of 50 phon (square-root).

```swift
    @Test("Quarter volume maps to 35 phon via linear curve")
    func quarterVolumeMidpoint() {
        // volume=0.25 → 20 + 60*0.25 = 35 phon
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: 0.25)
        expectClose(phon, 35.0, tolerance: 0.01)
    }
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/EstimatedPhonBoundaryTests CODE_SIGN_IDENTITY="-"`
Expected: FAIL (assertion mismatch, getting 50.0 instead of 35.0)

**Step 3: Modify ISO226Contours.swift**

Change `estimatedPhon` to use linear mapping:
```swift
    static func estimatedPhon(fromSystemVolume volume: Float) -> Double {
        let v = Double(max(0.0, min(1.0, volume)))
        return estimatedPhonRange.lowerBound
            + (defaultReferencePhon - estimatedPhonRange.lowerBound) * v
    }
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/EstimatedPhonBoundaryTests CODE_SIGN_IDENTITY="-"`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTune/Audio/Loudness/ISO226Contours.swift FineTuneTests/ISO226ContoursTests.swift
git commit -m "dsp: change volume-to-phon mapping to linear steepness (1.0)"
```

---

### Task 117: Remove 80 Hz Low-Shelf Filter from LoudnessCompensator

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift:34-40`
- Modify: `FineTuneTests/ISO226ContoursTests.swift:158`

**Step 1: Write a failing test in ISO226ContoursTests.swift**
Update `fittedCascadeTracksTargetAtThreePercentVolume` to assert that `LoudnessCompensator.bandCount == 3` instead of `4`.

```swift
        #expect(LoudnessCompensator.bandCount == 3)
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGN_IDENTITY="-"`
Expected: FAIL (either compilation error or assertion mismatch `4 == 3`)

**Step 3: Modify LoudnessCompensator.swift**

Remove the `lowShelf` filter at 80 Hz:
```swift
    private static let filterDefinitions: [LoudnessFilterDefinition] = [
        .init(kind: .peaking, frequency: 180, q: 0.7),
        .init(kind: .peaking, frequency: 3200, q: 0.7),
        .init(kind: .highShelf, frequency: 10000, q: 0.85),
    ]
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGN_IDENTITY="-"`
Expected: PASS (if RMSE/max error checks need adjustments, tune them in the test suite)

**Step 5: Commit**

```bash
git add FineTune/Audio/Loudness/LoudnessCompensator.swift FineTuneTests/ISO226ContoursTests.swift
git commit -m "dsp: remove 80 Hz low-shelf filter from loudness compensator definitions"
```

---

### Task 118: Build and Package Release App

**Files:**
- Output: `build/FineTune.zip`

**Step 1: Run build script**

Run: `./scripts/build-release-app.sh`
Expected: Compiles in Release mode and produces `build/FineTune.zip`

**Step 2: Commit**

```bash
git add build/FineTune.zip
git commit -m "build: package release with 3-band loudness compensator and linear steepness"
```
