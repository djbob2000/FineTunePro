# Loudness Compensation Amount Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a global `0..100%` Loudness Compensation amount slider that scales the ISO-derived contour strength without changing the underlying system-volume-to-phon heuristic.

**Architecture:** Keep `systemVolume -> estimatedPhon` unchanged. Introduce a persisted global `loudnessCompensationAmount` setting, thread it through `AudioEngine` and `ProcessTapController`, and scale the compensation target before fitting the fixed 4-filter loudness topology so `0%` is flat and `100%` matches current behavior.

**Tech Stack:** Swift, SwiftUI, Accelerate/vDSP, Swift Testing

---

### Task 1: Lock in test coverage for amount scaling and persistence

**Files:**
- Modify: `FineTuneTests/ISO226ContoursTests.swift`
- Modify: `FineTuneTests/SettingsManagerTests.swift`

**Step 1: Write the failing test**
- Add a loudness-compensation scaling test that asserts `amount = 0` produces a flat curve and `amount = 0.5` halves representative compensation points.
- Add settings tests that assert `loudnessCompensationAmount` defaults to `1.0` and round-trips through JSON.

**Step 2: Run test to verify it fails**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/ISO226ContoursReferenceTests -only-testing:FineTuneTests/AppSettingsDefaultTests`
- Expected: FAIL because the amount setting and scaling API do not exist yet.

**Step 3: Write minimal implementation**
- Add the new setting and the amount-aware compensation API with just enough logic to satisfy the tests.

**Step 4: Run test to verify it passes**
- Re-run the same targeted tests and confirm they pass.

**Step 5: Commit**
- Commit later with the rest of the feature once integration and UI are green.

### Task 2: Thread the amount through the loudness-compensation pipeline

**Files:**
- Modify: `FineTune/Audio/Loudness/ISO226Contours.swift`
- Modify: `FineTune/Audio/Loudness/LoudnessProcessor.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapControlling.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift`
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`

**Step 1: Add amount-aware contour scaling**
- Extend the compensation helper so the app can request compensation strength with an `amount` multiplier in `0...1`.

**Step 2: Add amount-aware loudness updates**
- Extend the tap-control API and processor update path to accept the amount alongside volume and enabled state.

**Step 3: Preserve existing semantics**
- Ensure `amount == 1` matches current behavior and `amount == 0` yields a flat response without needing to disable the feature.

**Step 4: Re-run targeted tests**
- Re-run loudness and settings tests once the pipeline wiring is complete.

**Step 5: Commit**
- Commit later with UI and docs if everything stays green.

### Task 3: Add settings UI and final verification

**Files:**
- Modify: `FineTune/Views/Settings/SettingsView.swift`
- Modify: `FineTune/Views/MenuBarPopupView.swift`
- Modify: `guide/iso226-2023-migration.md`

**Step 1: Add the slider UI**
- Show a `0..100%` slider beneath Loudness Compensation when the feature is enabled.

**Step 2: Trigger live updates**
- Make changing the slider update active taps immediately, not only on app restart or device-volume changes.

**Step 3: Document the behavior**
- Note that the feature now exposes a user-controlled amount that scales the ISO-derived contour before fitting.

**Step 4: Run verification**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/ISO226ContoursReferenceTests -only-testing:FineTuneTests/LoudnessProcessorHeadroomTests -only-testing:FineTuneTests/AppSettingsDefaultTests`
- Expected: PASS.

**Step 5: Commit**
- `git add` the modified files and commit once the feature and tests are green.
