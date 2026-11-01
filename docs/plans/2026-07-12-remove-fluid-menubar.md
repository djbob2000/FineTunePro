# Remove FluidMenuBarExtra & Transition to Native NSPanel Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Remove the custom `FluidMenuBarExtra` scene package and replace it with a native `MenuBarPanel` (subclass of `NSPanel`) instantiated once in `FineTuneApp`'s lifecycle to guarantee 100% reliable clicks on all macOS versions and monitor setups.

**Architecture:** Use a single, persistent `NSStatusItem` registered at launch. Display our SwiftUI `MenuBarPopupView` inside a custom `NSPanel` utilizing standard AppKit API, showing/hiding it under the status item button coordinates. Eliminate reflection/window-scanning inside `MenuBarIconCoordinator` and `MenuBarPopupController` by referencing the status item directly from the `AppDelegate`.

---

### Task 1: Create the Native `MenuBarPanel` Component

**Files:**
- Create: `FineTune/Views/MenuBar/MenuBarPanel.swift`

**Step 1: Write minimal class definition**
Create the file `FineTune/Views/MenuBar/MenuBarPanel.swift` with:
```swift
import AppKit
import SwiftUI

@MainActor
final class MenuBarPanel: NSPanel, NSWindowDelegate {
    private var globalEventMonitor: Any?

    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 510, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        self.hasShadow = true
        self.delegate = self

        let visualEffect = NSVisualEffectView()
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.material = .popover
        visualEffect.translatesAutoresizingMaskIntoConstraints = true
        self.contentView = visualEffect

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])
    }

    func toggle(under statusItem: NSStatusItem) {
        if self.isVisible {
            dismiss()
        } else {
            present(under: statusItem)
        }
    }

    private func present(under statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        
        let buttonFrame = button.window?.frame ?? .zero
        let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        
        var newFrame = NSRect(origin: buttonFrame.origin, size: self.frame.size)
        newFrame.origin.y = buttonFrame.minY - newFrame.height - 2
        
        let visible = screen.visibleFrame
        let margin: CGFloat = 4
        
        if newFrame.maxX > visible.maxX {
            newFrame.origin.x = visible.maxX - newFrame.width - margin
        }
        if newFrame.minX < visible.minX {
            newFrame.origin.x = visible.minX + margin
        }
        
        self.setFrame(newFrame, display: true)
        
        self.alphaValue = 0
        self.orderFrontRegardless()
        self.makeKeyAndOrderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1
        }
        
        button.highlight(true)
        startGlobalClickMonitor()
    }

    func dismiss() {
        guard self.isVisible else { return }
        stopGlobalClickMonitor()
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                delegate.statusItem?.button?.highlight(false)
            }
        }
    }

    private func startGlobalClickMonitor() {
        guard globalEventMonitor == nil else { return }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    private func stopGlobalClickMonitor() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}
```

**Step 2: Commit new component**
```bash
git add FineTune/Views/MenuBar/MenuBarPanel.swift
git commit -m "feat: implement custom MenuBarPanel with acrylic background blur"
```

---

### Task 2: Setup AppDelegate status item and click actions

**Files:**
- Modify: `FineTune/FineTuneApp.swift`

**Step 1: Declare statusItem and action inside AppDelegate**
Modify `AppDelegate` declaration in `FineTune/FineTuneApp.swift` to add:
```swift
    var statusItem: NSStatusItem?
    var menuBarPanel: MenuBarPanel?

    @objc func statusItemClicked() {
        guard let statusItem = statusItem else { return }
        menuBarPanel?.toggle(under: statusItem)
    }
```

**Step 2: Instantiate statusItem and MenuBarPanel inside init()**
Update `FineTuneApp.init()` to instantiate the native `NSStatusItem` and our `MenuBarPanel`. Pass dependencies explicitly:
```swift
        // Initialize Status Item once in init()
        let launchVolumeMonitor = engine.deviceVolumeMonitor
        let launchID = launchVolumeMonitor.defaultDeviceID
        let launchStyle = MenuBarIconState.resolveStyle(
            defaultDeviceID: launchID,
            configuredStyle: settings.appSettings.menuBarIconStyle
        )
        let launchState = MenuBarIconState.baseline(
            style: launchStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false,
            deviceSymbol: MenuBarDeviceIconResolver.resolveSymbol(
                priorityOrder: settings.devicePriorityOrder,
                outputDevices: engine.deviceMonitor.outputDevices,
                defaultDeviceID: launchID,
                overrideForUID: { settings.getDeviceIconOverride(for: $0) }
            )
        )
        launchIconImage = launchState.image.nsImage()
            ?? MenuBarIconImage.systemSymbol("speaker.wave.2").nsImage()!

        let delegate = _appDelegate.wrappedValue
        DispatchQueue.main.async { [delegate, engine, scanner, accessibilityService, statusService, popupService, hud, monitor] in
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.behavior = .removalAllowed
            statusItem.isVisible = true
            statusItem.button?.setAccessibilityTitle("FineTune")
            statusItem.button?.image = launchIconImage
            statusItem.button?.target = delegate
            statusItem.button?.action = #selector(AppDelegate.statusItemClicked)
            delegate.statusItem = statusItem

            let menuBarContent = MenuBarPopupView(
                audioEngine: engine,
                deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                updateManager: updateManager,
                permission: engine.permission,
                auPluginScanner: scanner,
                accessibility: accessibilityService,
                mediaKeyStatus: statusService,
                popupVisibility: popupService,
                hudController: hud,
                mediaKeyMonitor: monitor
            )
            let panel = MenuBarPanel(content: menuBarContent)
            delegate.menuBarPanel = panel
        }
```

**Step 3: Remove FluidMenuBarExtra from scene body**
Replace the app `body` scene list to only declare `Settings`:
```swift
    var body: some Scene {
        Settings {
            SettingsRootView(
                settings: audioEngine.settingsManager,
                audioEngine: audioEngine,
                deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                bottomEdgeScrollStatus: bottomEdgeScrollStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                bottomEdgeScrollMonitor: bottomEdgeScrollMonitor,
                shortcutsRegistry: shortcutsRegistry,
                updateManager: updateManager
            )
        }
    }
```

**Step 4: Commit**
```bash
git add FineTune/FineTuneApp.swift
git commit -m "feat: migrate status item lifecycle to init and AppDelegate"
```

---

### Task 3: Simplify MenuBarIconCoordinator

**Files:**
- Modify: `FineTune/Views/MenuBar/MenuBarIconCoordinator.swift`

**Step 1: Simplify resolveButton() and clean up Mirror KeepAlive**
Update `MenuBarIconCoordinator` to pull the button directly from the `AppDelegate`. Remove `keepStatusItemAlive()` and static `KeepAlive` dictionary.
```swift
    private func resolveButton() -> NSStatusBarButton? {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return delegate.statusItem?.button
    }
```

**Step 2: Commit**
```bash
git add FineTune/Views/MenuBar/MenuBarIconCoordinator.swift
git commit -m "refactor: simplify MenuBarIconCoordinator resolving status item button directly"
```

---

### Task 4: Simplify MenuBarPopupController

**Files:**
- Modify: `FineTune/Shortcuts/MenuBarPopupController.swift`

**Step 1: Refactor toggle() to communicate directly with MenuBarPanel**
Update `MenuBarPopupController` to call `toggle(under:)` directly:
```swift
    func toggle() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate,
              let statusItem = delegate.statusItem
        else {
            Self.logger.debug("toggle: status item not ready")
            return
        }
        
        delegate.menuBarPanel?.toggle(under: statusItem)
    }
```
Remove all helper functions regarding screen finding, synthetic click posting, and class inspection.

**Step 2: Commit**
```bash
git add FineTune/Shortcuts/MenuBarPopupController.swift
git commit -m "refactor: coordinate hotkey toggle directly via MenuBarPanel"
```

---

### Task 5: Clean up local FluidMenuBarExtra source files

**Files:**
- Delete: `FineTune/FluidMenuBarExtra/`

**Step 1: Remove local copy**
```bash
rm -rf FineTune/FluidMenuBarExtra
```

**Step 2: Commit cleanup**
```bash
git add FineTune/FluidMenuBarExtra
git commit -m "cleanup: remove local FluidMenuBarExtra source files"
```
