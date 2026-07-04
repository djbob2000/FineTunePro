

## Overview
This PR upgrades the Equal-Loudness Contour (ISO 226:2023) compensator engine to support per-device routing, dynamic headroom management, and a custom reference level configuration. It addresses user feedback regarding digital clipping and bass over-boosts at low volumes while eliminating the dependency on global controls in favor of granular per-device settings.

---

## Key Improvements

### 1. Piecewise Model for Volume-to-Phon Mapping
* Replaced the simple square-root curve with a piecewise mapping heuristic in [ISO226Contours.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/ISO226Contours.swift):
  - For system volume $v \le 0.2$, volume maps to a steep linear slope ($v \times 100$) targeting a threshold of $20.0$ phon. This prevents the equalizer from bottoming out too abruptly at low volume steps.
  - For $v > 0.2$, volume is scaled linearly between $20.0$ phon and the device's configured target reference phon level ($83.0$ phon by default).
* Standardized the default reference phon to $83.0$ phon (up from $80.0$ phon).

### 2. Live Cascade Realized Response and Headroom Management
* Updated [LoudnessCompensator.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/LoudnessCompensator.swift) to prevent ISO 226 digital clipping:
  - Computes the realized frequency response of the 4-section biquad cascade at runtime using `realizedResponseDB`.
  - Determines the peak gain (`peakDB`) of the cascade, excluding infrasound frequencies below 30 Hz.
  - Computes the available headroom based on current digital volume attenuation in the audio pipeline.
  - Dynamically subtracts the excess boost from the filter gains, guaranteeing the cascade will never cause digital clipping even with maximum loudness boosts.

### 3. Flat Shelf Below 30 Hz
* Added an effective frequency limit of $30.0$ Hz to the interpolation grid in [ISO226Contours.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/ISO226Contours.swift).
* This saves dynamic headroom.

### 4. Per-Device Loudness Toggle and Reference Level Customization
* Replaced the global loudness compensation toggle in [AudioTab.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/Settings/Tabs/AudioTab.swift) with per-device configuration in [DeviceDetailSheet.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/Sheets/DeviceDetailSheet.swift).
* Introduced a **Device Reference Level** slider ($20.0$ to $120.0$ phon) in the advanced sheet section, allowing users to fine-tune compensation thresholds for sensitive or high-impedance headphones/speakers.
* Per-device configurations are persisted in [SettingsManager.swift](file:///Users/air/develop/FineTuneFork/FineTune/Settings/SettingsManager.swift).
---

## Verification

### Automated Tests
* Comprehensive unit test suites cover the new dynamic features, filters, and safety bounds:
  * `ISO226ContoursTests` (piecewise model mapping, phon estimation).
  * `LoudnessVolumeCompensationTests` (device toggling volume behavior on hardware and software backends, instant filter gain updates).
