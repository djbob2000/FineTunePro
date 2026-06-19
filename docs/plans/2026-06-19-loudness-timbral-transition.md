# Loudness Timbral Transition Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement smooth timbral transition (300 ms) alongside hardware volume compensation when toggling the Loudness Compensator.

**Architecture:** Add a `gainScale: Float` parameter to `LoudnessCompensator` to scale the target EQ gains from 0.0 to 1.0. Create a unified `rampLoudnessCompensation` method in `AudioEngine` that steps system volume and `gainScale` concurrently over 300 ms.

**Tech Stack:** Swift, Core Audio, Accelerate framework.

---

### Task 1: Update LoudnessCompensator.swift

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Write the implementation changes in `LoudnessCompensator.swift`**
Add `_currentGainScale` property. Update `updateForVolume`, `computeBandGains`, and `recomputeCoefficients` to support `gainScale`.

```swift
// Add property in state section:
private var _currentGainScale: Float = 1.0

// Update updateForVolume signature and body:
func updateForVolume(_ systemVolume: Float, digitalVolume: Float = 1.0, referencePhon: Double = 85.0, gainScale: Float = 1.0) {
    let phon = ISO226Contours.estimatedPhon(fromSystemVolume: systemVolume, referencePhon: referencePhon)
    guard !isEnabled || abs(phon - _currentPhon) >= 1.0 || abs(referencePhon - _currentReferencePhon) >= 0.1 || abs(digitalVolume - _currentDigitalVolume) >= 0.05 || abs(gainScale - _currentGainScale) >= 0.01 else { return }
    _currentPhon = phon
    _currentReferencePhon = referencePhon
    _currentSystemVolume = systemVolume
    _currentDigitalVolume = digitalVolume
    _currentGainScale = gainScale

    let gains = computeBandGains(phon: phon, referencePhon: referencePhon, digitalVolume: digitalVolume, gainScale: gainScale)
    let allNegligible = gains.allSatisfy { abs($0) < 0.1 }
    if allNegligible {
        setEnabled(false)
        swapSetup(nil)
        return
    }

    let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
    let newSetup = coefficients.withUnsafeBufferPointer { ptr in
        vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(Self.bandCount))
    }
    swapSetup(newSetup)
    setEnabled(true)
}

// Update computeBandGains signature and body:
private func computeBandGains(phon: Double, referencePhon: Double, digitalVolume: Float, gainScale: Float = 1.0) -> [Float] {
    let gains = Self.fittedSectionGains(forPhon: phon, referencePhon: referencePhon, sampleRate: sampleRate)
    let scaledGains = gains.map { $0 * gainScale }
    let realized = Self.realizedResponseDB(sectionGains: scaledGains.map(Double.init), sampleRate: sampleRate)
    
    let frequencies = Self.fitGridFrequencies()
    var peakDB = 0.0
    for (index, freq) in frequencies.enumerated() {
        if freq >= 30.0 {
            peakDB = max(peakDB, realized[index])
        }
    }
    
    let linearVolume = max(Double(digitalVolume), 1e-4)
    let volumeAttenuationDB = -20.0 * log10(linearVolume)
    let headroomToSubtract = max(0.0, peakDB - volumeAttenuationDB)
    
    return scaledGains.map { $0 - Float(headroomToSubtract) }
}

// Update recomputeCoefficients override:
override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
    let gains = computeBandGains(phon: _currentPhon, referencePhon: _currentReferencePhon, digitalVolume: _currentDigitalVolume, gainScale: _currentGainScale)
    let allNegligible = gains.allSatisfy { abs($0) < 0.1 }
    guard !allNegligible else { return nil }
    let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
    return (coefficients, Self.bandCount)
}
```

**Step 2: Commit Task 1**
```bash
git add FineTune/Audio/Loudness/LoudnessCompensator.swift
git commit -m "feat: add gainScale to LoudnessCompensator"
```

---

### Task 2: Update ProcessTapControlling.swift & ProcessTapController.swift

**Files:**
- Modify: `FineTune/Audio/Engine/ProcessTapControlling.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift`

**Step 1: Update protocol definition in `ProcessTapControlling.swift`**
Change `updateLoudnessCompensation` signature:
```swift
func updateLoudnessCompensation(volume: Float, enabled: Bool, referencePhon: Double, gainScale: Float)
```

**Step 2: Update implementation in `ProcessTapController.swift`**
Add `_lastLoudnessGainScale: Float = 1.0` in state section.
Update `updateLoudnessCompensation` method:
```swift
func updateLoudnessCompensation(volume: Float, enabled: Bool, referencePhon: Double, gainScale: Float = 1.0) {
    _lastLoudnessVolume = volume
    _lastLoudnessReferencePhon = referencePhon
    _lastLoudnessGainScale = gainScale
    if enabled {
        loudnessCompensator?.updateForVolume(volume, digitalVolume: _volume, referencePhon: referencePhon, gainScale: gainScale)
        secondaryLoudnessCompensator?.updateForVolume(volume, digitalVolume: _volume, referencePhon: referencePhon, gainScale: gainScale)
    } else {
        loudnessCompensator?.setEnabled(false)
        secondaryLoudnessCompensator?.setEnabled(false)
    }
}
```

Update `secLoudness.updateForVolume` in `createSecondaryTap` (around line 1068):
```swift
let secLoudness = LoudnessCompensator(sampleRate: sampleRate)
secLoudness.updateForVolume(_lastLoudnessVolume, digitalVolume: _volume, referencePhon: _lastLoudnessReferencePhon, gainScale: _lastLoudnessGainScale)
if !(loudnessCompensator?.isEnabled ?? false) { secLoudness.setEnabled(false) }
```

Update initial loudness activation in `activate(initial:)` (around line 681):
```swift
loudnessCompensator?.setEnabled(initial.loudnessCompensationEnabled)
if initial.loudnessCompensationEnabled {
    loudnessCompensator?.updateForVolume(initial.loudnessVolume, digitalVolume: _volume, referencePhon: initial.loudnessReferencePhon, gainScale: 1.0)
}
_lastLoudnessVolume = initial.loudnessVolume
_lastLoudnessReferencePhon = initial.loudnessReferencePhon
_lastLoudnessGainScale = 1.0
```

**Step 3: Commit Task 2**
```bash
git add FineTune/Audio/Engine/ProcessTapControlling.swift FineTune/Audio/Engine/ProcessTapController.swift
git commit -m "feat: support gainScale in ProcessTapController"
```

---

### Task 3: Update AudioEngine.swift

**Files:**
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`

**Step 1: Implement changes in `AudioEngine.swift`**
Add helper method:
```swift
private func updateTapsLoudness(deviceUID: String, enabled: Bool, referencePhon: Double, gainScale: Float) {
    for tap in taps.values {
        guard tap.currentDeviceUID == deviceUID else { continue }
        tap.updateLoudnessCompensation(
            volume: effectiveLoudnessVolume(for: tap),
            enabled: enabled,
            referencePhon: referencePhon,
            gainScale: gainScale
        )
    }
}
```

Remove `rampDeviceVolume` method, and replace with `rampLoudnessCompensation`:
```swift
private func rampLoudnessCompensation(
    for deviceUID: String,
    deviceID: AudioDeviceID?,
    fromVolume: Float?,
    toVolume: Float?,
    enabling: Bool,
    referencePhon: Double
) {
    volumeRampTasks[deviceUID]?.cancel()
    
    let task = Task { @MainActor in
        let duration: TimeInterval = 0.300
        let stepInterval: TimeInterval = 0.030
        let steps = Int(duration / stepInterval)
        
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            
            let progress = Float(step) / Float(steps)
            
            if let deviceID, let fromVol = fromVolume, let toVol = toVolume {
                let currentStepVolume = fromVol + (toVol - fromVol) * progress
                deviceVolumeMonitor.setVolume(for: deviceID, to: currentStepVolume)
            }
            
            let gainScale = enabling ? progress : (1.0 - progress)
            updateTapsLoudness(deviceUID: deviceUID, enabled: true, referencePhon: referencePhon, gainScale: gainScale)
            
            try? await Task.sleep(for: .milliseconds(30))
        }
        
        if !Task.isCancelled {
            if let deviceID, let toVol = toVolume {
                deviceVolumeMonitor.setVolume(for: deviceID, to: toVol)
            }
            
            let finalGainScale: Float = enabling ? 1.0 : 0.0
            updateTapsLoudness(deviceUID: deviceUID, enabled: enabling, referencePhon: referencePhon, gainScale: finalGainScale)
            
            volumeRampTasks.removeValue(forKey: deviceUID)
        }
    }
    volumeRampTasks[deviceUID] = task
}
```

Update `setLoudnessCompensationEnabled` implementation:
```swift
func setLoudnessCompensationEnabled(for deviceUID: String, enabled: Bool) {
    settingsManager.setLoudnessCompensationEnabled(for: deviceUID, to: enabled)
    let referencePhon = settingsManager.getLoudnessReferencePhon(for: deviceUID)
    
    var startVol: Float? = nil
    var endVol: Float? = nil
    var deviceID: AudioDeviceID? = nil
    
    if let device = deviceMonitor.device(for: deviceUID) {
        let backend = outputVolumeBackend(for: device.id)
        if backend == .hardware || backend == .ddc {
            deviceID = device.id
            let currentVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            if enabled {
                let offsetScalar: Float
                if let existing = appliedLoudnessOffsets[deviceUID] {
                    offsetScalar = existing
                } else {
                    let peakDB = computeHeadroomOffsetDB(for: deviceUID, systemVolume: currentVolume, referencePhon: referencePhon)
                    offsetScalar = Float(peakDB / 100.0)
                    appliedLoudnessOffsets[deviceUID] = offsetScalar
                }
                startVol = currentVolume
                endVol = min(1.0, currentVolume + offsetScalar)
            } else {
                let offsetScalar = appliedLoudnessOffsets[deviceUID] ?? 0.0
                appliedLoudnessOffsets[deviceUID] = nil
                startVol = currentVolume
                endVol = max(0.0, currentVolume - offsetScalar)
            }
        }
    }
    
    rampLoudnessCompensation(
        for: deviceUID,
        deviceID: deviceID,
        fromVolume: startVol,
        toVolume: endVol,
        enabling: enabled,
        referencePhon: referencePhon
    )
}
```

**Step 2: Commit Task 3**
```bash
git add FineTune/Audio/Engine/AudioEngine.swift
git commit -m "feat: coordinate loudness volume and filter scaling ramp in AudioEngine"
```

---

### Task 4: Update Unit Tests and Verify

**Files:**
- Modify: `FineTuneTests/LoudnessVolumeCompensationTests.swift`

**Step 1: Write test case verifying smooth timbral ramping**
Since mock tap controller is used in tests, we must update the mock tap controller definition or stub to support the new protocol signature.
Let's check `FineTuneTests/LoudnessVolumeCompensationTests.swift` to see how the mock tap controller is implemented.

**Step 2: Run verification tests**
Run tests:
```bash
xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/LoudnessVolumeCompensationTests CODE_SIGN_IDENTITY="-"
```
Expected: PASS

**Step 3: Commit Task 4**
```bash
git add FineTuneTests/LoudnessVolumeCompensationTests.swift
git commit -m "test: verify loudness timbral and volume compensation transition"
```
