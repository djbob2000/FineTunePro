# Loudness Reference Level UI Redesign Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Redesign the Device Reference Level UI within the Device Settings sheet to use a direct collapsible row with dynamic labels ("Default"/"Custom" vs phon value), updated helper text, and a "Reset to Default" button.

**Architecture:** Modify `DeviceDetailSheet.swift` to replace the advanced settings disclosure button with a "Device Reference Level" button. Use the existing `@State private var showAdvanced: Bool` to toggle expansion, dynamically compute the label text based on expansion state and reference level value, and add a Reset button.

**Tech Stack:** Swift, SwiftUI, Xcode Test

---

### Task 1: Update UI Layout and Behavior in DeviceDetailSheet

**Files:**
- Modify: `FineTune/Views/Sheets/DeviceDetailSheet.swift:253-308`

**Step 1: Replace Advanced Settings section in DeviceDetailSheet.swift**

Replace the current disclosure button and its expanded contents in `loudnessCompensationToggle` with the redesigned clickable row, slider, sub-text, and "Reset to Default" button.

```swift
            if isLoudnessCompensationEnabled {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAdvanced.toggle()
                        }
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Text("Device Reference Level")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            
                            Spacer()
                            
                            Text(showAdvanced ? "\(Int(loudnessReferencePhon)) phon" : (loudnessReferencePhon == 83.0 ? "Default" : "Custom"))
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    if showAdvanced {
                        VStack(alignment: .leading, spacing: 6) {
                            Slider(
                                value: Binding(
                                    get: { loudnessReferencePhon },
                                    set: { onLoudnessReferencePhonChange($0) }
                                ),
                                in: 20...120,
                                step: 1
                            )
                            .controlSize(.mini)
                            
                            Text("Fine-tunes loudness compensation for unusual speakers or headphones. Most users should leave this at Default.")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            HStack {
                                Spacer()
                                Button {
                                    onLoudnessReferencePhonChange(83.0)
                                } label: {
                                    Text("Reset to Default")
                                        .font(DesignTokens.Typography.caption)
                                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(loudnessReferencePhon == 83.0)
                            }
                        }
                        .padding(.leading, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
```

**Step 2: Build the project to verify compilation**

Run: `xcodebuild build -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: Build succeeds without errors.

**Step 3: Run existing unit tests**

Run: `xcodebuild test -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO`
Expected: All unit tests pass.

**Step 4: Commit**

```bash
git add FineTune/Views/Sheets/DeviceDetailSheet.swift
git commit -m "ui: redesign Device Reference Level layout and behavior"
```

---

### Task 2: Verify UI and Add Logic Test Cases

**Files:**
- Modify: `FineTuneTests/DeviceDetailSheetToggleTests.swift:115-127`

**Step 1: Write verification test cases for the dynamic label helper logic**

Add a static or helper test assertion checking if the default state returns `Default` and modified returns `Custom`. (We can add custom static helper logic to `DeviceDetailSheet` or verify the initialization values).
Wait! In `DeviceDetailSheetToggleTests.swift`, we can add a test verifying the dynamic reference label text representation logic if we expose a static helper in `DeviceDetailSheet`. Let's add a static helper in `DeviceDetailSheet` that returns the display text for reference level to keep it cleanly unit-testable:

```swift
    static func referenceLevelDisplayName(phon: Double, isExpanded: Bool) -> String {
        if isExpanded {
            return "\(Int(phon)) phon"
        } else {
            return phon == 83.0 ? "Default" : "Custom"
        }
    }
```
And use it in the UI:
```swift
Text(Self.referenceLevelDisplayName(phon: loudnessReferencePhon, isExpanded: showAdvanced))
```

Let's write a unit test in `FineTuneTests/DeviceDetailSheetToggleTests.swift`:

```swift
    @Test("Reference level display name behaves correctly based on value and expansion state")
    func referenceLevelDisplayNameLogic() {
        #expect(DeviceDetailSheet.referenceLevelDisplayName(phon: 83.0, isExpanded: false) == "Default")
        #expect(DeviceDetailSheet.referenceLevelDisplayName(phon: 84.0, isExpanded: false) == "Custom")
        #expect(DeviceDetailSheet.referenceLevelDisplayName(phon: 83.0, isExpanded: true) == "83 phon")
        #expect(DeviceDetailSheet.referenceLevelDisplayName(phon: 95.0, isExpanded: true) == "95 phon")
    }
```

**Step 2: Run unit tests**

Run: `xcodebuild test -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 3: Commit**

```bash
git add FineTuneTests/DeviceDetailSheetToggleTests.swift FineTune/Views/Sheets/DeviceDetailSheet.swift
git commit -m "test: add unit test for reference level display name logic"
```
