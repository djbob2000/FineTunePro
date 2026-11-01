# Fix Dropdown Menu Focus Resignation Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Fix a bug where dropdown menus instantly close by ensuring key resignation events to child windows are ignored in MenuBarPopupView.

**Architecture:** Modify the `NSWindow.didResignKeyNotification` listener inside `MenuBarPopupView.swift` to ignore focus changes where a child window of the main popup window has become key.

**Tech Stack:** Swift, SwiftUI, AppKit

---

### Task 1: Check Child Window Focus on Resign Key

**Files:**
- Modify: `FineTune/Views/MenuBarPopupView.swift`

**Step 1: Modify the didResignKeyNotification handler**
In `FineTune/Views/MenuBarPopupView.swift` around lines 229-237:
Add checks:
```swift
            // If the key window is a child of this window, do not treat it as resigning visibility
            if let keyWindow = NSApp.keyWindow, window.childWindows?.contains(keyWindow) == true {
                return
            }
            if window.childWindows?.contains(where: { $0.isKeyWindow }) == true {
                return
            }
```

**Step 2: Run Unit Tests**
Run the unit test suite:
`xcodebuild -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests test CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Verify all tests pass successfully.

**Step 3: Commit changes**
Commit the changes.
