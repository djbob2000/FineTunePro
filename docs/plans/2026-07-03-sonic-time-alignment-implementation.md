# Sonic Time Alignment Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement the BBE US4482866 3-band Sonic Time Alignment DSP processor in FineTune and expose a toggle in the UI with settings persistence.

**Architecture:** Create `SonicAlignmentProcessor.swift` to handle 3-band crossover filtering with 2.5 ms LF ring buffer delay and 0.5 ms MF ring buffer delay. Update `SettingsManager.swift`, `AudioEngine.swift`, `ProcessTapController.swift`, and `DeviceDetailSheet.swift` to support and persist `sonicAlignmentEnabled`.

**Tech Stack:** Swift 6, Accelerate vDSP, vDSP biquad filters, XCTest / Swift Testing.

---

### Task 1: Add Sonic Alignment Settings and AudioEngine Plumbing

**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift`
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapControlling.swift`
- Test: `FineTuneTests/SonicAlignmentTests.swift`

---

### Task 2: Implement SonicAlignmentProcessor.swift

**Files:**
- Create: `FineTune/Audio/DSP/SonicAlignmentProcessor.swift`
- Test: `FineTuneTests/SonicAlignmentTests.swift`

---

### Task 3: Add UI Toggle to DeviceDetailSheet.swift and MenuBarPopupView.swift

**Files:**
- Modify: `FineTune/Views/Sheets/DeviceDetailSheet.swift`
- Modify: `FineTune/Views/MenuBarPopupView.swift`

---
