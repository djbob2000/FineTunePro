# Design: Media Key Volume Control Crash Fix

## Problem
The application crashes when the user controls the volume using the F/media keys. This is caused by a runtime assertion failure in Swift Concurrency:
1. `CGEventTap` callbacks run on the main runloop, which is on the main thread but not executing in the `DispatchQueue.main` queue context.
2. `MainActor.assumeIsolated` executes a runtime check (`dispatchPrecondition(condition: .onQueue(DispatchQueue.main))`) which fails outside of `DispatchQueue.main`.
3. This triggers an immediate crash.

## Proposed Solution (Option 1)
We will decouple event swallowing (which must be synchronous) from state changes (which are `@MainActor` isolated):
1. **Cache Settings**: Add a thread-safe cache (`cachedMediaKeyControlEnabled` guarded by `NSLock`) inside `MediaKeyMonitor` to retrieve `mediaKeyControlEnabled` synchronously from a `nonisolated` context.
2. **Nonisolated Event Processing**: Mark `processSystemDefined` as `nonisolated` so it can be called directly and synchronously by `mediaKeyTapCallback` without `MainActor.assumeIsolated`.
3. **Asynchronous Actor Offloading**: In `processSystemDefined`, if the event matches a media key and control is enabled, return `true` (swallow) synchronously, and offload the actual handling (volume changes, HUD update, sound pop feedback) to the `MainActor` asynchronously using `Task { @MainActor in ... }`.

## Detailed Changes

### `MediaKeyMonitor.swift`
* Add `settingsLock = NSLock()` and `cachedMediaKeyControlEnabled: Bool`.
* Implement `updateCachedSettings()` to read settings from `settingsManager.appSettings.mediaKeyControlEnabled` and cache them under lock.
* Call `updateCachedSettings()` during `init`, `start()`, and `reconcile()`.
* Change `processSystemDefined(_:)` signature to `nonisolated fileprivate func processSystemDefined(_ cgEvent: CGEvent) -> Bool`.
* Inside `processSystemDefined(_:)`, check `cachedMediaKeyControlEnabled` under lock.
* Wrap the side-effects in `Task { @MainActor in ... }` to safely invoke `hudController.swallowObserved()` and `handle(_:shiftHeld:optionHeld:)`.
* In `mediaKeyTapCallback`, remove `MainActor.assumeIsolated` for both `handleTapDisabled()` and `processSystemDefined(...)`. Run them using `Task { @MainActor in monitor.handleTapDisabled() }` and `monitor.processSystemDefined(event)` respectively.

## Verification Plan

### Automated Tests
Run the unit test suite to verify that `MediaKeyMonitorHandlerTests` and `MediaKeyTapDisabledTests` still pass cleanly.

### Manual Verification
* Press F10/F11/F12 to trigger volume control and verify no crash occurs.
* Verify the HUD displays correctly and the volume changes.
