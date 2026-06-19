# Loudness Reference Level UI Redesign

This document details the redesigned Device Reference Level UI within the Device Settings sheet, optimizing the layout and behavior of the advanced calibration controls for Loudness Compensation.

## Requirements

1. **Replace Advanced Settings Header**:
   - Replace the generic "Advanced Settings" row with a direct "Device Reference Level" row.
   - When collapsed, the row displays: `Device Reference Level` on the left, and `Default` (if value is 83.0) or `Custom` (if value is modified) on the right, accompanied by a right-pointing chevron (`>`).
   - Clicking this row toggles the expanded/collapsed state with a smooth animation.
2. **Display Value on Expansion**:
   - When expanded, the right side displays the active phon value (e.g., `83 phon`), and the chevron rotates 90 degrees downward (`v`).
3. **Advanced Calibration Slider**:
   - The interactive slider range remains `20...120`, step `1`.
4. **Description Sub-text**:
   - Below the slider, display the helper text: `Fine-tunes loudness compensation for unusual speakers or headphones. Most users should leave this at Default.`
5. **Reset Button**:
   - Introduce a prominent button labeled `Reset to Default`.
   - Clicking it sets the phon value back to `83.0`.
   - The button is disabled when the value is already `83.0`.

## Architecture & Data Flow

- The state of expansion is controlled by a private `@State` property `showAdvanced: Bool` in `DeviceDetailSheet`.
- Setting changes propagate instantly to the parent component via `onLoudnessReferencePhonChange`.
- A simple local helper determines whether the current value matches the system default (`83.0`).

## Verification Plan

- Build the macOS application to ensure compile-time correctness of the modified SwiftUI view.
- Add and run unit tests validating that bindings, visibility helper, and simulation properties work correctly.
