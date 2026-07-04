# Design Document: Code Review Fixes

## 1. Smart Volume Swap Stickiness (`AudioEngine.swift`)

### Problem
When a device switch occurs, `AudioEngine` updates output state and AutoEQ for the new device, but never re-applies `LoudnessEqualizerSettings` (Smart Volume) for the new device. Since Smart Volume is configured per-device, a tap can retain the enabled/disabled state of the old device.

### Solution
Add a private helper method `applyLoudnessEqualizationToTap(_:)` to `AudioEngine.swift`:
```swift
private func applyLoudnessEqualizationToTap(_ tap: any ProcessTapControlling) {
    guard let deviceUID = tap.currentDeviceUID else { return }
    var settings = LoudnessEqualizerSettings()
    settings.enabled = settingsManager.getLoudnessEqualizationEnabled(for: deviceUID)
    tap.updateLoudnessEqualization(settings)
}
```

Invoke this helper in `AudioEngine.swift` after all successful device switches and device updates on existing taps:
- `setDevice(for:app:deviceUID:)` (after successful `switchDevice`)
- `updateTapForCurrentMode(for:)` (after successful `updateDevices`)
- `applyPersistedSettings()` (after successful `switchDevice`)
- `routeFollowsDefaultApps(to:)` (after successful `switchDevice`)
- `handleDeviceDisconnected(_:name:)` (after successful `switchDevice` / `updateDevices`)
- `handleDeviceConnected(_:name:)` (after successful `switchDevice`)

---

## 2. Ignored PostAgcCompressorSettings.kneeDb (`PostAgcCompressor.swift`)

### Problem
`PostAgcCompressor.CompressorBand` hardcodes the knee width (`kneeDb`) to `0.1` both in `updateSampleRate` (where it sets `kneeHalfDb = 0.1 * 0.5`) and in `calculateGainReduction` (where it sets `let kneeDb: Float = 0.1`). Any setting configured via `kneeDb` is ignored.

### Solution
Store `kneeDb` on `CompressorBand`:
```swift
private final class CompressorBand: @unchecked Sendable {
    let thresholdOffsetDb: Float
    let ratio: Float
    let attackMs: Float
    let releaseMs: Float
    let kneeDb: Float
    let maxReleaseSpeed: Float
    let exponentialRelease: Float
    
    // Mutable state (RT thread only)
    var gainReductionDb: Float = 0
    
    // Coefficients
    private var slope: Float = 0
    private var kneeHalfDb: Float = 0
    ...
```

Initialize it with `settings.kneeDb` in `PostAgcCompressor.init`.
In `updateSampleRate(_:)`:
```swift
self.kneeHalfDb = kneeDb * 0.5
```

In `calculateGainReduction(levelDb:globalThresholdDb:)`:
Remove the local variable shadow `let kneeDb: Float = 0.1` and use `self.kneeDb`.

---

## 3. PostAgcCompressor RT-Safety and Channel Count (`PostAgcCompressor.swift`)

### Problem
`PostAgcCompressor.process(input:output:frameCount:channelCount:)` checks if `crossover200Hz.count != channelCount` and reallocates arrays dynamically if so. This violates real-time thread safety because heap allocations are not allowed in the audio callback.

### Solution
Narrow the API contract to stereo only (channelCount == 2). Since the production callback gates processing to stereo anyway, other channel counts can be safely bypassed:
```swift
guard channelCount == 2 else {
    if input != UnsafePointer(output) {
        memcpy(output, input, frameCount * channelCount * MemoryLayout<Float>.size)
    }
    return
}
```

Remove the dynamic array reallocation logic from the `process` method entirely.
Add a unit test in `PostAgcCompressorTests.swift` to verify that passing non-stereo channel counts results in an exact passthrough.
