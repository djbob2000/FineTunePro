# Design Document: Decibel Formatting and Volume Meter Scale Labels Theme-Awareness

## Overview
This document specifies the changes required to address two user requests:
1. Append "dB" to slider values when they are displayed in decibels.
2. Render volume meter scale labels in white for dark theme and black for light theme.

## Proposed Design

### 1. Color and Dimension Tokens (`DesignTokens.swift`)
* Define a dynamic color token `vuScaleLabel` in `DesignTokens.Colors` using `dynamicColor`:
  - Aqua (Light): `NSColor.black`
  - DarkAqua (Dark): `NSColor.white`
* Update `DesignTokens.Dimensions.decibelsWidth` from `44` to `56` to accommodate the extra characters ("dB") without clipping or causing layout shifts.

### 2. Editable Volume/Decibel Component (`EditablePercentage.swift`)
* Format log-scale slider values with "dB" appended (e.g. `-12.0dB`).
* For the edit states (`isEditing` and `keyboardBuffer != nil`), append the "dB" suffix text label dynamically outside the text input field, maintaining parity with the percentage unit behavior.
* In `parseValue`, strip out occurrences of "dB" case-insensitively using `replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)`.

### 3. Equalizer Slider Component (`EQSliderView.swift`)
* Update `formatGainValue` in AutoEQ mode to append "dB" (e.g., `+1.5dB`).

### 4. Output Level Meter Component (`VUMeter.swift`)
* In `OutputLevelMeter.body`, change the text styling of decibel scale labels from `DesignTokens.Colors.vuYellow` to `DesignTokens.Colors.vuScaleLabel`.

### 5. Dynamic Color Resolution Tests (`DesignTokensDynamicResolutionTests.swift`)
* Add a test `vuScaleLabel()` in `DesignTokensDynamicResolutionTests` to assert correct resolution in both `.aqua` and `.darkAqua` appearances.
