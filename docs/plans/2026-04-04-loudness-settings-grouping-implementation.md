# Loudness Settings Grouping Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reorganize the settings UI so loudness-related controls appear as one visual block, showing `Loudness Compensation` and its `Amount` prominently while keeping `Loudness Equalization` as a secondary explanatory option for quiet listening.

**Architecture:** Keep the existing DSP settings and engine wiring unchanged. Limit the change to `SettingsView` presentation and copy, plus a lightweight source-level regression test that verifies the intended strings and grouping remain present.

**Tech Stack:** Swift, SwiftUI, Swift Testing

---

### Task 1: Lock in a minimal source-level regression test

**Files:**
- Modify: `FineTuneTests/ProcessingPipelineTests.swift`
- Test: `FineTuneTests/ProcessingPipelineTests.swift`

**Step 1: Write the failing test**
- Add a source-inspection test that reads `FineTune/Views/Settings/SettingsView.swift`.
- Assert the file contains a `SectionHeader(title: "Loudness")`.
- Assert the file still contains `Loudness Compensation`, `Loudness Amount`, and a quieter-listening description for `Loudness Equalization`.

**Step 2: Run test to verify it fails**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/ProcessingPipelineTests`
- Expected: FAIL because the current UI still uses the `Audio` header and old Equalization copy.

**Step 3: Write minimal implementation**
- Update `SettingsView.swift` to use the new `Loudness` section title and revised copy.

**Step 4: Run test to verify it passes**
- Re-run the same test target and confirm the new strings are present.

**Step 5: Commit**
- Commit later with the finished UI change once verification is green.
