# Fix Headphone Audio Routing and Tap Switching Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Resolve the race condition and device-switch failure that causes process taps to capture silence and lose effects processing when headphones are connected.

**Architecture:** 
1. Handle deferred routing for follows-default apps in `handleDeviceConnected` if macOS has already set the newly connected device as the system default.
2. Extend `recreateTap` to optionally override device UIDs, and use it as a robust fallback in all `switchDevice` / `updateDevices` failure paths.

**Tech Stack:** Swift, CoreAudio, CoreAudioTap

---

### Task 1: Extend `recreateTap` signature in `AudioEngine.swift`

**Files:**
- Modify: [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift#L1980-L2012)

**Step 1: Write the implementation changes**

Modify `recreateTap` signature to accept an optional `overridingDeviceUIDs` array:
```swift
    private func recreateTap(for pid: pid_t, overridingDeviceUIDs: [String]? = nil) async {
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        let deviceUIDs = overridingDeviceUIDs ?? oldTap.currentDeviceUIDs
        await oldTap.invalidateAsync()

        // Set cooldown to prevent thrashing
        tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(20)

        // Find the current AudioApp entry for this PID
        guard let app = apps.first(where: { $0.id == pid }) else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            appliedPIDs.remove(pid)
            return
        }

        // Allow re-initialization
        appliedPIDs.remove(pid)

        // Re-route to the same device(s), preserving multi-device routing
        if deviceUIDs.count > 1 {
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
            if taps[app.id] != nil {
                appDeviceRouting[app.id] = deviceUIDs[0]
            }
        } else if let deviceUID = deviceUIDs.first {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }

        // Mark as applied to avoid redundant re-processing in applyPersistedSettings
        if taps[pid] != nil {
            appliedPIDs.insert(pid)
        }
    }
```

**Step 2: Commit**

```bash
# Verify it builds and then commit
```

---

### Task 2: Add routing recovery to `handleDeviceConnected`

**Files:**
- Modify: [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift#L1575-L1583)

**Step 1: Update conditional branches to handle deferred routing**

Insert a fallback condition when `currentDefault == deviceUID` to route follows-default apps in case their original default device change notification was deferred because the device wasn't in `deviceMonitor` yet:
```swift
        if isNewDeviceHigherPriority, deviceUID != currentDefault {
            // A higher-priority device reconnected — switch to it
            reEvaluateOutputDefault()
        } else if !isNewDeviceHigherPriority, currentDefault == deviceUID {
            // macOS already auto-switched to the lower-priority device — restore
            // what the user was on (not highest priority — they may have chosen a mid-priority device)
            restoreConfirmedDefault()
        } else if currentDefault == deviceUID {
            // The reconnected device is the current default (e.g. macOS auto-switched to a higher-priority device)
            // Route follows-default apps to it in case we deferred it earlier.
            routeFollowsDefaultApps(to: deviceUID)
        }
```

---

### Task 3: Integrate `recreateTap` fallbacks into switch failure paths

**Files:**
- Modify: [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift)

**Step 1: Add fallbacks to `setDevice(for:app:)`**
Modify `setDevice(for:app:)` catch block to call `recreateTap(for: app.id)`.

**Step 2: Add fallbacks to `applyPersistedSettings()`**
Modify `applyPersistedSettings()` catch block to call `recreateTap(for: app.id)`.

**Step 3: Add fallbacks to `routeFollowsDefaultApps(to:)`**
Modify `routeFollowsDefaultApps(to:)` catch block to call `recreateTap(for: app.id)`.

**Step 4: Add fallbacks to `handleDeviceDisconnected(_:name:)`**
Modify `handleDeviceDisconnected(_:name:)` catch blocks for both single-mode and multi-mode switches:
- For single-mode: `await self.recreateTap(for: tap.app.id)`
- For multi-mode: `await self.recreateTap(for: tap.app.id, overridingDeviceUIDs: remainingUIDs)`

**Step 5: Add fallbacks to `handleDeviceConnected(_:name:)`**
Modify `handleDeviceConnected(_:name:)` catch block to call `recreateTap(for: tap.app.id)`.

---

### Task 4: Verification

**Step 1: Compile the target**
Run compilation and verify there are no compilation errors.

**Step 2: Run test suite**
Run: `swift test` or build/test commands to confirm regression safety.
