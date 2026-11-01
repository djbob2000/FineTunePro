# Input Level Meter Monitoring Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement displaying the input device's live level in the main level meter of the popover header when the user switches to the "Input" tab, with strict safety and lifecycle controls to avoid a persistent macOS microphone recording indicator (orange dot).

---

### Task 1: Create InputLevelMonitor class

**Files:**
- Create: `FineTune/Audio/Engine/InputLevelMonitor.swift`

**Step 1: Write the implementation**
Define `InputLevelMonitor` wrapping `AudioDeviceCreateIOProcIDWithBlock`, `AudioDeviceStart`, `AudioDeviceStop`, and `AudioDeviceDestroyIOProcID`. Calculate levels on incoming buffers using `vDSP_maxmgv`.

---

### Task 2: Integrate InputLevelMonitor into AudioEngine

**Files:**
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`

**Step 1: Add interface methods**
Expose `startInputMonitoring`, `stopInputMonitoring`, and `getInputMeterSnapshot` methods on `AudioEngine`.

---

### Task 3: Handle lifecycle and routing in MenuBarPopupView

**Files:**
- Modify: `FineTune/Views/MenuBarPopupView.swift`

**Step 1: Update UI and state hooks**
Switch `outputMeterContent(tick:)` to query `getInputMeterSnapshot()` when `showingInputDevices` is true. Hook up visibility & tab state changes to start/stop input monitoring.

---

### Task 4: Add unit tests for InputLevelMonitor

**Files:**
- Create: `FineTuneTests/InputLevelMonitorTests.swift`

**Step 1: Write tests**
Verify starting and stopping handles invalid/unknown device IDs without crash or blocks.

---

### Task 5: Verify build & tests pass

Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS
