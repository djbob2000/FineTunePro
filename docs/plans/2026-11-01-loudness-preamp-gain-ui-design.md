# Design Document: Loudness Compensation Preamp Gain UI & Control

## 1. Overview
The Loudness Compensation DSP pipeline uses `_preampGain` to attenuate input signals before applying the low-shelf boost, preventing digital clipping on hot signals. Users need direct control over this attenuation in the UI so they can switch between automatic headroom calculation and manual gain attenuation (from 0.0 dB down to -12.0 dB).

## 2. Architecture & Data Flow

### 2.1 Settings Persistence (`SettingsManager.swift`)
- Add enum `LoudnessPreampMode: String, Codable, CaseIterable` with cases `.auto` (default) and `.manual`.
- Add dictionary fields in `Settings`:
  - `deviceLoudnessPreampMode: [String: String]` (default: `"auto"`)
  - `deviceLoudnessPreampManualDB: [String: Double]` (range: `-12.0 ... 0.0`, default: `0.0`)
- Add accessors and reset logic in `SettingsManager`.

### 2.2 DSP Pipeline (`LoudnessCompensator.swift`)
- State variables:
  - `_preampMode: LoudnessPreampMode = .auto`
  - `_manualPreampDB: Double = 0.0`
- `updateForVolume(...)` updated to accept `preampMode: LoudnessPreampMode = .auto, manualPreampDB: Double = 0.0`.
- `updatePreamp()`:
  - If `_preampMode == .manual`:
    `_preampGain = Float(pow(10.0, _manualPreampDB / 20.0))`
  - Else (`.auto`):
    `cutDB = max(0, _peakGainDB - availableDB)`
    `_preampGain = Float(pow(10.0, -cutDB / 20.0))`

### 2.3 Audio Engine & Tap Propagation
- `ProcessTapControlling.swift` & `ProcessTapController.swift`:
  Extend `updateLoudnessCompensation(...)` with `preampMode: LoudnessPreampMode, manualPreampDB: Double`.
- `AudioEngine.swift`:
  Propagate `deviceLoudnessPreampMode` and `deviceLoudnessPreampManualDB` to all active taps for the target device.

### 2.4 User Interface (`DeviceEnhancementPanel.swift`)
- Inside `loudnessSection`, when Loudness is enabled:
  - A collapsible / expandable row "Preamp Gain" with a chevron.
  - Subtitle displaying current state: `Auto (-X.X dB)` or `Manual (Y.Y dB)`.
  - Picker: `[ Auto | Manual ]`.
  - When in `Manual`:
    - Slider: `-12.0 ... 0.0 dB`, step `0.5 dB`.
    - Real-time label with Unicode hair-space: e.g. `-3.5 dB`.
    - Caption text explaining that at 0 dB, track volume is unattenuated and downstream BrickwallLimiter handles peaks.

## 3. Real-Time & Verification Requirements
- Zero allocations, locks, or blocking calls in the CoreAudio RT render thread.
- Full unit test coverage in `FineTuneTests` verifying:
  - `.auto` calculation retains original headroom behavior.
  - `.manual` mode strictly enforces `pow(10.0, manualPreampDB / 20.0)` across all volumes.
  - Settings persistence round-trip.
