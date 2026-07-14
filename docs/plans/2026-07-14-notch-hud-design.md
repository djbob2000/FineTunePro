# Design Document: Notch HUD Style

This document details the design and architecture for adding a **Notch HUD** style (a camera notch-integrated Heads-Up Display) to FineTune.

## Overview
For MacBooks equipped with a camera cutout (notch), standard centered HUD elements can feel disconnected or visually off-center. This feature adds a new `HUDStyle` option, `.notch`, which overlays the physical notch to make it look like a "Dynamic Island" expanding into a status bar during volume adjustments.

## Architecture & Component Design

### 1. Notch Detection and Screen Geometry
We will introduce helper extensions on `NSScreen` using macOS 12+ safe area APIs:
- `hasNotch: Bool`
  Checks if `safeAreaInsets.top > 0` and both `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are available.
- `notchRect: NSRect?`
  Calculates the exact bounds of the physical notch on the current screen:
  - `x = auxiliaryTopLeftArea.maxX`
  - `y = auxiliaryTopLeftArea.minY`
  - `width = topRightArea.minX - topLeftArea.maxX`
  - `height = screen.frame.maxY - topLeftArea.minY`

### 2. Panel Creation and Positioning
In `HUDWindowController`:
- If `.notch` is the active style AND the screen containing the cursor has a physical notch:
  - Create a full-screen-width panel at the very top of the screen.
  - `width = screen.frame.width`
  - `height = screen.safeAreaInsets.top + 14` (overhangs 14pt below the menu bar).
  - Set `backgroundColor = .clear` and `isOpaque = false` to enable a custom transparent shape overlay.
- If the current screen does not have a notch, dynamically fall back to `.tahoe` style.

### 3. SwiftUI HUD View Layout (`NotchStyleHUD.swift`)
The view will render a solid black pill shape wrapping around the notch:
- **Pill Shape Dimensions**: Centered horizontally on the screen, width is `notchWidth + 180`, height is `menuBarHeight + 14`.
- **Left Canvas**: A left-aligned `HStack` displaying the speaker icon and the device name (truncated dynamically).
- **Center Canvas**: A transparent empty spacer mapping exactly to the `notchWidth`.
- **Right Canvas**: A right-aligned volume percentage text.
- **Bottom Progress Bar**: A thin (3pt) capsule-shaped horizontal bar located in the overhang area.

### 4. Settings Integration
- Add `.notch` to the `HUDStyle` enum.
- Display name:
  - English: `"Notch"`
  - Russian: `"Вырез (Notch)"`
- Update `HUDStyleSegmentedControl` in Settings with a custom mini-notch icon thumbnail representation.

## Testing & Verification Plan

### Automated Tests
- Add a unit test to verify that `hasNotch` and `notchRect` calculate bounds correctly given mock screen metrics.
- Update `HUDStyleCodableTests` to expect 3 cases instead of 2.
- Add test case verifying `.notch` serialization in `HUDStyleCodableTests`.
- Add layout math tests inside `HUDWindowControllerTests` to verify correct window coordinates for the notch top-strip panel.

### Manual Verification
- Verify the settings segmented control has the new thumbnail.
- Verify the OSD HUD dynamically falls back to Tahoe on external/non-notched screens.
