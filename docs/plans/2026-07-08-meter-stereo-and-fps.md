# VU & Output Meter Stereo, 30 FPS, and CPU Optimization Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Fix the output level meter so it displays stereo levels (two channels) when playing stereo sound (like YouTube) despite other silent/mono taps, increase the update rate of the meters to 30 FPS, and optimize background CPU consumption to 0% by pausing TimelineViews when the popup is closed.

---

### Task 1: Update timing tokens to 30 FPS [COMPLETED]

### Task 2: Implement stereo aggregation in getOutputMeterSnapshot [COMPLETED]

### Task 3: Optimize CPU usage by pausing TimelineViews when popup is hidden

**Files:**
- Modify: `FineTune/Views/MenuBarPopupView.swift`

**Step 1: Write the implementation**
Modify `MenuBarPopupView.swift` to only use `TimelineView` for the output meter and app list when `isPopupVisible` is `true`.

**Step 2: Run test to verify it compiles and tests pass**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 3: Commit**
(Skipped/Local only)
