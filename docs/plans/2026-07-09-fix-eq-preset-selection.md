# Fix EQ Preset Selection Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Allow selecting equalizer presets when the EQ is disabled, and automatically enable the EQ upon selection.

**Architecture:** Remove the disabled state from the preset picker UI element and update the user preset selection handlers in the parent popup view to set the EQ settings enabled state to true.

**Tech Stack:** SwiftUI, Swift

---

### Task 1: Make Preset Picker Interactive in UI

**Files:**
- Modify: `FineTune/Views/EQPanelView.swift`

**Step 1: Write a test or verify existing tests**
Run unit tests to ensure everything builds.

**Step 2: Make Preset Picker always interactive**
Remove `.disabled(!isEQSectionEnabled.wrappedValue)` from `EQPresetPicker` in `FineTune/Views/EQPanelView.swift`.

**Step 3: Verify build**
Build the app.

---

### Task 2: Automatically Enable EQ on User Preset Selection

**Files:**
- Modify: `FineTune/Views/MenuBarPopupView.swift`

**Step 1: Update ObservedAppRow preset selection handler**
In `ObservedAppRow` user preset selection handler, set `current.isEnabled = true`.

**Step 2: Update ObservedInactiveAppRow preset selection handler**
In `ObservedInactiveAppRow` user preset selection handler, set `current.isEnabled = true`.

**Step 3: Run Unit Tests**
Verify that all unit tests pass.
