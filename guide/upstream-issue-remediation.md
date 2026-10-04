# Upstream issue remediation

Review of the 14 reports requested from [upstream FineTune issues](https://github.com/ronitsingh10/FineTune/issues), against this fork's main at `e449190`.

“Covered” below means the code path has automated regression coverage. It does not establish that the original reporter's hardware or third-party application reproduces or resolves the issue.

| Report | Finding and change | Validation / remaining limit |
| --- | --- | --- |
| [#457: boot audio glitch](https://github.com/ronitsingh10/FineTune/issues/457) | Never-rendered taps can now fail health checks. Sleep/wake refreshes clients and rebuilds taps; all output devices have sample-rate listeners. | Recovery, cooldown, wake, and rate fallback are covered. The reported HDMI setup and actual boot/wake playback need runtime verification. |
| [#456: launch at login](https://github.com/ronitsingh10/FineTune/issues/456) | Login status follows `SMAppService`, registration errors restore the actual toggle state, and pending approval links to Login Items. | Success, failure, pending approval, external changes, and persistence are covered using an injected service. Signed installed-app login still needs an actual login session. |
| [#455: initial playback bypasses controls](https://github.com/ronitsingh10/FineTune/issues/455) | Registered paused clients are prepared before playback. Late helper process objects trigger serialized teardown and a fresh tap. Activation guards prevent duplicate controllers. | Saved initial gain, growth during activation/teardown, and cancellation are covered. A brand-new audio client can still play before its first HAL notification. |
| [#453: popup URL](https://github.com/ronitsingh10/FineTune/issues/453) | Added `open-popup`, `close-popup`, and `toggle-popup`; a cold-launch request waits up to three seconds for the menu-bar scene. | URL routing, repeated open/close, foreign schemes, and cold launch are covered at the AppKit event boundary. |
| [#452: Spotify detection](https://github.com/ronitsingh10/FineTune/issues/452) | No Spotify exclusion exists. The report names iOS, which this macOS application does not support. Paused-client discovery and helper growth handling also improve the macOS path. | Capture preparation and helper lifecycle are covered; the reported iOS scenario is outside this application. |
| [#448: linked media-key volume](https://github.com/ronitsingh10/FineTune/issues/448) | Added persisted selections under Audio settings. Keys control the default plus connected selected outputs; each keeps its own level. Mute applies to the whole group. | Backend-specific steps, mixed mute state, disconnected selections, and DDC repeat throttling are covered. |
| [#447: Wine/Scotch silence](https://github.com/ronitsingh10/FineTune/issues/447) | Clients without app metadata use executable names. Failed creation retries, callback recovery, and teardown serialization address identified lifecycle gaps. | Lifecycle paths are covered. The original Wine/Scotch workload has not been reproduced; ignoring the affected executable remains a diagnostic fallback. |
| [#443: BlackHole installation](https://github.com/ronitsingh10/FineTune/issues/443) | This fork installs no audio driver and does not depend on BlackHole; there is no BlackHole installation gate to remove. Added coexistence guidance. | Verified by source inspection; circular virtual-device routes are a separate runtime configuration concern. |
| [#442: microphone selection rolls back](https://github.com/ronitsingh10/FineTune/issues/442) | Input locking now defaults off. With an existing lock enabled, a settled System Settings selection becomes the new preference; the connection auto-switch grace window retains protection. | Default/migration persistence and settled external selection are covered. Explicit saved lock preferences remain enabled. |
| [#440: Airwave compatibility](https://github.com/ronitsingh10/FineTune/issues/440) | Airwave's global tap includes FineTune output. Bypassing capture of Airwave's final mix removes a possible feedback cycle. Source apps retain their controls. | Bypass at tap creation is covered. Simultaneous playback, global tap mute ownership, and device switching with Airwave remain unverified. This is not a claim of complete interoperability. |
| [#439: mirrored AutoEQ shared across outputs](https://github.com/ronitsingh10/FineTune/issues/439) | Mirrored aggregates expose separate output channels. Each destination has its own AutoEQ processor, preamp, software gain, mute, and final limiter. Missing/disabled profiles stay uncorrected. | Packed and planar channels, secondary-only profiles, local profile removal, independent gain/mute, oversized buffers, aggregate planning, and reset are covered. Physical multi-device synchronization needs hardware verification. Other device effects still use the primary output's settings. |
| [#437: media-key volume steps](https://github.com/ronitsingh10/FineTune/issues/437) | Usable outputs keep accepting tiny repeated steps; DDC throttles only DDC members. Events pass through when no valid default output or observed volume exists. | Extra-fine repeats from zero, backend mappings, repeat coalescing, and pass-through are covered. The original keyboard setup has not been reproduced. |
| [#435: pin popup corner](https://github.com/ronitsingh10/FineTune/issues/435) | Added follow-icon, top-left, and top-right anchors under General settings, reapplied after open, resize, and display changes. | Geometry, persistence, and AppKit window notifications are covered, including secondary-display coordinates. |
| [#434: URL volume differs from panel](https://github.com/ronitsingh10/FineTune/issues/434) | Already fixed in the starting main (`e449190`): URL percentages use the same slider mapping as the panel. No duplicate mapping change was needed. | Existing URL volume regression tests remain green. |

## Verification

On 2026-10-04, all 1,033 tests across 177 suites passed, and the Release build succeeded with code signing disabled.

Run the unit suite:

```sh
xcodebuild test -project FineTune.xcodeproj -scheme FineTune \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO
```

Build the optimized application:

```sh
xcodebuild build -project FineTune.xcodeproj -scheme FineTune \
  -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The Airwave capture policy was checked against its [processing pipeline](https://github.com/sallliisa/Airwave/blob/d2244dc811aaea4cb5bfe2e27e860b8a7e4bd8fb/Airwave/AudioPipeline.swift#L172) and [global tap implementation](https://github.com/sallliisa/Airwave/blob/d2244dc811aaea4cb5bfe2e27e860b8a7e4bd8fb/Airwave/CoreAudioPlatformClient.swift#L967).

Recovery tests use an injected clock, process/device snapshots, and tap controllers. Mirrored-renderer tests exercise actual sample buffers; popup tests use isolated AppKit panels and status items without clicking the user's mixer. These checks do not replace playback tests on the devices and applications described above.
