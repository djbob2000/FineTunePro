# Pull Request: fix(audio): add recreateTap fallback when dynamic device switch/update fails

## Summary

This PR introduces a robust error recovery mechanism for process tap routing switches and updates in `AudioEngine.swift`. 

Currently, if the underlying CoreAudio/HAL switch fails dynamically (e.g. during rapid device connections, sample rate changes, or Bluetooth state transitions), the error is caught and logged, but the process tap remains in an invalid state. This can lead to audio dropouts or silence for the affected application.

With this change, the engine falls back to calling `recreateTap(for:)` when any dynamic device switch or aggregate update fails. This tears down the invalid tap and recreates a fresh one, safely recovering the audio capture session and preventing permanent silence.

## Key Changes

### 1. Robust Fallback in Switch Actions
* Added `recreateTap` recovery to the `catch` blocks in:
  * `setDevice(for:deviceUID:)` — when explicit routing switch fails.
  * `applyPersistedSettings()` — when re-routing an existing tap on startup/settings updates fails.
  * `routeFollowsDefaultApps(to:)` — when switching follows-default apps to the new default output fails.
  * `handleDeviceDisconnected(_:name:)` — when moving a single-mode or multi-mode tap to its fallback/remaining devices fails.
  * `handleDeviceConnected(_:name:)` — when switching pinned apps back to their preferred device fails.

### 2. Multi-device Target Override Support
* Extended `recreateTap(for:overridingDeviceUIDs:)` signature to accept an optional array of device UIDs.
* If provided, the tap is recreated targetting this subset of devices instead of the old tap's full device list. This is utilized during multi-mode device disconnections when a subset of devices remains active.

---

## Verification

### Automated Tests
* Verified that the project builds clean and the entire unit test suite (`FineTuneTests`) passes successfully on the branch:
  ```bash
  xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
  ```
* Output: `** TEST SUCCEEDED **`
