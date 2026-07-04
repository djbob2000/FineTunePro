# Unified Loudness Toggle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove the separate Loudness Equalization UI row and make the Loudness Compensation toggle control both loudness flags together.

**Architecture:** Keep both persisted settings fields intact, but introduce a single helper on `AppSettings` that synchronizes `loudnessCompensationEnabled` and `loudnessEqualizationEnabled`. `SettingsView` will expose a composed `Binding` that uses that helper and remove the standalone equalization row.

**Tech Stack:** SwiftUI, Swift Testing

---

### Task 1: Add a failing synchronization test

**Files:**
- Modify: `FineTuneTests/SettingsManagerTests.swift`
- Test: `FineTuneTests/SettingsManagerTests.swift`

**Step 1: Write the failing test**

```swift
@Test("Unified loudness toggle updates compensation and equalization together")
func unifiedLoudnessToggleSetsBothFlags() {
    var settings = AppSettings()
    settings.setUnifiedLoudnessEnabled(true)
    #expect(settings.loudnessCompensationEnabled == true)
    #expect(settings.loudnessEqualizationEnabled == true)

    settings.setUnifiedLoudnessEnabled(false)
    #expect(settings.loudnessCompensationEnabled == false)
    #expect(settings.loudnessEqualizationEnabled == false)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme FineTune -only-testing:FineTuneTests/SettingsManagerTests`
Expected: FAIL because `setUnifiedLoudnessEnabled` does not exist yet.

### Task 2: Implement the shared toggle behavior

**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift`
- Modify: `FineTune/Views/Settings/SettingsView.swift`

**Step 1: Write minimal implementation**

```swift
mutating func setUnifiedLoudnessEnabled(_ enabled: Bool) {
    loudnessCompensationEnabled = enabled
    loudnessEqualizationEnabled = enabled
}
```

**Step 2: Update the settings view**

Use a composed `Binding` in `SettingsView` for `SettingsLoudnessCompensationRow` and remove the separate `Loudness Equalization` row.

**Step 3: Run targeted tests**

Run: `xcodebuild test -scheme FineTune -only-testing:FineTuneTests/SettingsManagerTests`
Expected: PASS
