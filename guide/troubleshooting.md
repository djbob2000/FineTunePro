# Troubleshooting

## No sound / audio stops working

FineTune requires the **Screen & System Audio Recording** permission to capture and route app audio.

1. Open **System Settings** → **Privacy & Security** → **Screen & System Audio Recording**
2. Find FineTune in the list and enable it
3. **Restart FineTune** — the permission doesn't take effect until relaunch

If you previously denied the permission prompt, you'll need to enable it manually from System Settings.

## App not appearing

FineTune only shows apps that are **actively playing audio**. If an app isn't visible:

- Make sure the app is actually producing sound (start playback)
- Check if the app is hidden. Open **edit mode** (pencil icon) and look for the eye icon next to the app name. A crossed-out eye means the app is being ignored.
- Some apps use helper processes for audio. Try restarting the app.

## App causing audio issues

Some apps don't work well with CoreAudio process taps — particularly audio processors, DAWs, VoIP tools, and apps that do their own low-level audio routing. Symptoms include distorted audio, echo, or audio cutting out.

**Fix:** Open **edit mode** (pencil icon) and click the eye icon to ignore the problematic app. This tears down the process tap entirely for that app, so it goes back to normal macOS audio routing.

Common apps that may need to be ignored:
- Audio Hijack, Loopback, and other Rogue Amoeba apps
- Some VoIP/conferencing tools with custom audio engines
- FaceTime, WhatsApp, and other calling apps (tapping can break echo cancellation, causing volume ducking)

## Silence after startup, wake, or a sample-rate change

FineTune prepares registered audio clients before playback, retains their taps while paused, and rebuilds taps after wake or output sample-rate changes. A streaming client that stops delivering callbacks is retried after repeated health-check failures; cooldowns prevent repeated teardown loops. A newly created CoreAudio client can still start before macOS reports it, so these changes do not promise zero delay for every app.

After wake, FineTune restores the system output selected before sleep, even if an HDMI monitor remains connected or has a higher priority. During the first five seconds of wake recovery, delayed default-output notifications and reconnects cannot replace that selection. If the previous output is unavailable, FineTune uses the highest-priority live output and restores the previous one if it returns within that window. Selecting an output in FineTune takes effect immediately; external selections in System Settings are respected after this short settling period.

For Wine/Scotch, check both the launcher and the actual game's executable in edit mode. If the problem persists, ignore the affected executable to return it to native routing and include its name, output device, and reproduction steps in a report.

## Using Airwave or BlackHole

FineTune uses native CoreAudio process taps and does not install or require BlackHole. An existing BlackHole installation does not block FineTune installation. Virtual-device routing can still create a loop if an output is routed back to its own source.

Airwave processes a global mix that includes FineTune's output. FineTune automatically bypasses capture of Airwave itself (`com.southneuhof.Airwave`) to keep its processed output out of a feedback loop. Other source apps retain their controls. This prevents that specific graph cycle; simultaneous mute ownership, device changes, and real playback with Airwave still require compatibility testing. If sound remains unstable, quit one audio processor while diagnosing the route.

## Changing the microphone in System Settings

**Lock Input Device** is off by default. When enabled, it protects against input changes during a newly connected device's short auto-switch window. A later selection in System Settings becomes the new preferred and locked input instead of being immediately rolled back.

## Popup position

Choose **Settings → General → Popup Position** to follow the menu-bar icon or keep the mixer in the top-left or top-right corner of the menu-bar display. The anchor is reapplied when the popup opens, resizes, or changes display. URL commands to open, close, and toggle the popup are documented in [URL schemes](url-schemes.md).

## Volume slider not working

There are two cases.

**Per-app slider.** Some apps use helper processes to play audio rather than the main app process, so the slider you see might be controlling the wrong process. Try restarting the app. If the issue persists, check edit mode to see if the app appears as a different process name.

**Per-device slider.** When you open a device, FineTune picks a volume backend automatically:

- **Hardware**: the device reports a native volume control (most USB DACs, AirPods, built-in speakers).
- **DDC**: an external display that responds to the monitor-control protocol.
- **Software**: FineTune attenuates inside its own audio graph.

Auto-detection gets it right for most devices, but some USB DACs and HDMI/DisplayPort outputs advertise a hardware slider that doesn't actually move the output level. If the device slider doesn't change the volume, open the device inspector (the info button on the device row) and turn on **Software volume**. FineTune remembers the choice per device. The toggle is hidden when auto-detect already picked Software, because there's no alternative backend to switch to.

## Audio device not switching automatically

FineTune uses a **device priority list** to decide which output device to use. When a device connects, FineTune only switches to it if it's ranked higher than the current device. When a device disconnects, FineTune falls back to the next highest-priority device that's still connected.

If you want newly connected outputs to take over immediately regardless of priority, enable **Settings → Audio → Auto-Switch New Output**.

By default, devices are added to the bottom of the list in the order they're first seen. Since your Mac's built-in speakers are always connected, they end up at the top (highest priority), so FineTune won't auto-switch to headphones, external speakers, or other devices when they connect.

**This is a one-time setup.** Once you set your preferred order, it's saved permanently and works across app restarts.

**How to reorder:**

1. Click the **pencil icon** in the menu bar popup to enter edit mode
2. **Drag** devices to reorder, or **click the priority number** and type a new position
3. Click the **checkmark** to exit edit mode — your order is saved

The device at position 1 has the highest priority. FineTune will always prefer the highest-priority device that's currently connected.

Input and output devices have **separate priority lists** — switch between them using the tabs in edit mode.

> **Note:** For AirPods, taking them out of your ears and putting them back in (without the case) is handled by macOS Automatic Ear Detection. FineTune doesn't interfere with that.

## Input devices not showing

FineTune's input device monitoring requires separate microphone permission.

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Find FineTune and enable it
3. Restart FineTune

## Media keys don't control FineTune

Media keys (F10 / F11 / F12) require the **Accessibility** permission so FineTune can observe the keystrokes.

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Enable FineTune in the list. If it's already on, toggle it off and back on to clear a rare permission-bootstrap race.
3. Open FineTune Settings → **Shortcuts** → **Media Keys**, turn on **Media Keys Control**, and pick a HUD style.

FineTune passes the key through to macOS when the default output is unavailable or its volume has not been read yet. If the media-key connection goes offline, use **Retry** in the Shortcuts tab.

To control several outputs together, open Settings → **Audio** → **Linked Output Volume**, enable **Link Volume Keys**, and select the additional outputs. The default output is always controlled. Each selected output moves by the configured slider step from its own current level; mute silences the whole group if any member is unmuted, and unmutes the group when all are muted. Disconnected selections remain saved for the next connection. The HUD and feedback reflect the default output.

## Launch at login does not match System Settings

FineTune reads the actual macOS login-item status when it launches and when you return to its settings. If macOS requires approval, use **Open Login Items** under Settings → **General**, then allow FineTune in System Settings. A failed registration or removal leaves the toggle at its actual system state and shows the error below it.

## Volume HUD not appearing

- Check Settings → **Shortcuts** → **Media Keys** and enable **Media Keys Control**. The HUD is suppressed while the popup is open.
- Switch HUD styles if one isn't rendering. Tahoe uses macOS 26's system HUD look; Classic matches the older translucent rounded-rect style.

## EQ not applying / sounds the same

- The EQ is enabled by default. Check that the **toggle switch** in the EQ panel header is on.
- The default preset is **Flat** (all bands at 0 dB), which makes no audible changes. Select a different preset or adjust the bands manually.
- EQ is **per-app**, not per-device. Make sure you're adjusting the EQ for the correct app.
- If using AutoEQ headphone correction, that's separate from the 10-band EQ. Verify a profile is assigned to the correct device via the wand icon

## Audio quality sounds degraded

- Check if volume boost is set above 1x — high boost levels can cause clipping on loud passages
- If using EQ, large boosts across multiple bands can push levels too high. Try pulling bands down instead of boosting others up.
- AutoEQ profiles include a preamp gain reduction to prevent clipping; manual EQ does not, so be mindful of total gain
- Try resetting the app to defaults: `open "finetune://reset"` in Terminal
