# Port Upstream Fixes Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Port upstream fixes (DDC success evaluation, fixed-size menu bar icon canvas, and robust menu-bar fallback overrides) from July 9, 2026 release cycle.

**Architecture:**
- Update `DDCService.swift` to count any write cycle succeeding as a success.
- Update `MenuBarIconImage+NSImage.swift` to render images on a fixed 22x18 canvas, preventing status item sizing jitter.
- Update `MenuBarDeviceIconResolver.swift` to check if custom overrides are resolvable using NSImage validation and fall back gracefully, setting up interface closures that default to nil to avoid compilation issues.
- Add an adapted `MenuBarIconImageSizeTests.swift` verifying icon size invariance.
- Update `appcast.xml` with upstream v1.9.0 details.

**Tech Stack:** Swift, AppKit, IOKit, Xcode Testing framework.

---

### Task 1: DDC Success Cycle Fix

**Files:**
- Modify: `FineTune/Audio/DDC/DDCService.swift`

**Step 1: Write minimal implementation**
Modify `i2cWrite` function in `FineTune/Audio/DDC/DDCService.swift` to check `anySucceeded`:
```swift
    private func i2cWrite(packet: [UInt8]) throws {
        var lastResult: IOReturn = kIOReturnError
        var anySucceeded = false
        for _ in 0..<numWriteCycles {
            usleep(writeSleepTime)
            lastResult = packet.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return kIOReturnError }
                return IOAVServiceLoader.writeI2C(service: service, chipAddress: chipAddress,
                                           dataAddress: writeAddress, buffer: base, size: UInt32(buf.count))
            }
            if lastResult == kIOReturnSuccess { anySucceeded = true }
        }
        guard anySucceeded else { throw DDCError.writeFailed(lastResult) }
    }
```

**Step 2: Commit**
```bash
git add FineTune/Audio/DDC/DDCService.swift
git commit -m "fix(ddc): count any successful DDC write cycle as success"
```

---

### Task 2: Shared Fixed-Size Menu Bar Canvas

**Files:**
- Modify: `FineTune/Views/MenuBar/MenuBarIconImage+NSImage.swift`
- Modify: `FineTune/FineTuneApp.swift`

**Step 1: Write minimal implementation**
Modify `FineTune/Views/MenuBar/MenuBarIconImage+NSImage.swift`:
```swift
// FineTune/Views/MenuBar/MenuBarIconImage+NSImage.swift
// AppKit bridge for MenuBarIconImage — kept separate so the value types
// file (MenuBarIconState.swift) stays AppKit-free and the Equatable
// conformances remain nonisolated under Swift 6 strict concurrency.

import AppKit

@MainActor
extension MenuBarIconImage {
    /// The status item is variable-length: icons of differing sizes resize it and shift every neighboring menu bar item.
    static let canvasSize = NSSize(width: 22, height: 18)

    func nsImage(accessibilityDescription: String = "FineTune") -> NSImage? {
        let source: NSImage?
        switch self {
        case .systemSymbol(let name):
            source = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        case .asset(let name):
            source = NSImage(named: name)
        }
        guard let source else { return nil }

        let canvas = Self.canvasSize
        let scale = min(1, canvas.width / source.size.width, canvas.height / source.size.height)
        let drawRect = NSRect(
            x: (canvas.width - source.size.width * scale) / 2,
            y: (canvas.height - source.size.height * scale) / 2,
            width: source.size.width * scale,
            height: source.size.height * scale
        )
        let image = NSImage(size: canvas, flipped: false) { _ in
            source.draw(in: drawRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
```

Modify fallback in `FineTune/FineTuneApp.swift`:
```swift
        launchIconImage = launchState.image.nsImage()
            ?? MenuBarIconImage.systemSymbol("speaker.wave.2").nsImage()!
```

**Step 2: Commit**
```bash
git add FineTune/Views/MenuBar/MenuBarIconImage+NSImage.swift FineTune/FineTuneApp.swift
git commit -m "fix(menu-bar): render all icons on a shared fixed-size canvas"
```

---

### Task 3: Robust Menu Bar Device Icon Resolver Overrides

**Files:**
- Modify: `FineTune/Views/MenuBar/MenuBarDeviceIconResolver.swift`
- Modify: `FineTuneTests/MenuBarDeviceIconResolverTests.swift`

**Step 1: Write minimal implementation**
Modify `resolveSymbol` in `FineTune/Views/MenuBar/MenuBarDeviceIconResolver.swift` to incorporate override checking and validation:
```swift
// FineTune/Views/MenuBar/MenuBarDeviceIconResolver.swift

import AppKit
import AudioToolbox

struct MenuBarDeviceIconResolver {
    // Neutral "unknown output" glyph, sourced from the transport-type convention
    // so it stays in sync with the rest of the app rather than a private literal.
    static let fallbackSymbol = TransportType.unknown.defaultIconSymbol

    /// An override symbol that fails to resolve (hand-edited settings.json,
    /// symbol removed in a future macOS) falls back to the derived symbol —
    /// a nil NSImage downstream would freeze the status item on its last image.
    static func resolveSymbol(
        priorityOrder: [String],
        outputDevices: [AudioDevice],
        defaultDeviceID: AudioDeviceID,
        overrideForUID: (String) -> String? = { _ in nil },
        isSymbolResolvable: (String) -> Bool = {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        },
        isDeviceAvailable: (AudioDevice) -> Bool = { $0.id.isDeviceAlive() },
        uidForDefaultID: (AudioDeviceID) -> String? = { try? $0.readDeviceUID() },
        symbolForDevice: (AudioDevice) -> String = { $0.id.suggestedIconSymbol() },
        symbolForDefaultID: (AudioDeviceID) -> String = { id in
            guard id.isValid else { return Self.fallbackSymbol }
            return id.suggestedIconSymbol()
        }
    ) -> String {
        func overrideSymbol(forUID uid: String) -> String? {
            guard let symbol = overrideForUID(uid), isSymbolResolvable(symbol) else { return nil }
            return symbol
        }

        let devicesByUID = Dictionary(outputDevices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Match macOS's sound menu: the persistent icon represents the device
        // currently receiving system audio, even if FineTune's saved priority
        // order has another connected device above it.
        if let defaultDevice = outputDevices.first(where: { $0.id == defaultDeviceID }),
           isDeviceAvailable(defaultDevice) {
            return overrideSymbol(forUID: defaultDevice.uid) ?? symbolForDevice(defaultDevice)
        }

        for uid in priorityOrder {
            guard let device = devicesByUID[uid], isDeviceAvailable(device) else { continue }
            return overrideSymbol(forUID: uid) ?? symbolForDevice(device)
        }

        if defaultDeviceID.isValid {
            if let uid = uidForDefaultID(defaultDeviceID), let symbol = overrideSymbol(forUID: uid) {
                return symbol
            }
            return symbolForDefaultID(defaultDeviceID)
        }

        return fallbackSymbol
    }
}
```

Modify `FineTuneTests/MenuBarDeviceIconResolverTests.swift` to add validation tests:
```swift
// FineTuneTests/MenuBarDeviceIconResolverTests.swift

import Testing
import AudioToolbox
import AppKit
@testable import FineTune

@Suite("MenuBarDeviceIconResolver")
struct MenuBarDeviceIconResolverTests {
    private func device(id: AudioDeviceID, uid: String, name: String) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: name, icon: nil, supportsAutoEQ: true)
    }

    private func resolve(
        priorityOrder: [String],
        outputDevices: [AudioDevice],
        defaultDeviceID: AudioDeviceID = 999,
        unavailableUIDs: Set<String> = []
    ) -> String {
        MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: priorityOrder,
            outputDevices: outputDevices,
            defaultDeviceID: defaultDeviceID,
            isDeviceAvailable: { !unavailableUIDs.contains($0.uid) },
            symbolForDevice: { device in
                if device.name.contains("AirPods") { return "airpodspro" }
                if device.name.contains("HomePod") { return "homepod" }
                if device.name.contains("Display") { return "display" }
                if device.name.contains("HDMI") { return "tv" }
                return "headphones"
            },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
    }

    @Test("AirPods/Bluetooth priority returns headphone-style symbol")
    func airPodsPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(resolve(priorityOrder: ["airpods", "speakers"], outputDevices: devices) == "airpodspro")
    }

    @Test("Current default output takes precedence over saved priority")
    func defaultOutputTakesPrecedence() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(
            resolve(
                priorityOrder: ["speakers", "airpods"],
                outputDevices: devices,
                defaultDeviceID: 2
            ) == "airpodspro"
        )
    }

    @Test("HomePod/AirPlay priority returns HomePod-style symbol")
    func homePodPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "homepod", name: "HomePod")
        ]

        #expect(resolve(priorityOrder: ["homepod", "speakers"], outputDevices: devices) == "homepod")
    }

    @Test("HDMI or display priority returns display-style symbol")
    func displayPriority() {
        let devices = [
            device(id: 1, uid: "hdmi", name: "HDMI Output"),
            device(id: 2, uid: "studio-display", name: "Studio Display")
        ]

        #expect(resolve(priorityOrder: ["hdmi"], outputDevices: devices) == "tv")
        #expect(resolve(priorityOrder: ["studio-display"], outputDevices: devices) == "display")
    }

    @Test("Unavailable priority device falls back to next connected priority device")
    func unavailablePriorityFallsBack() {
        let devices = [
            device(id: 1, uid: "airpods", name: "AirPods Pro"),
            device(id: 2, uid: "homepod", name: "HomePod")
        ]

        #expect(
            resolve(
                priorityOrder: ["airpods", "homepod"],
                outputDevices: devices,
                unavailableUIDs: ["airpods"]
            ) == "homepod"
        )
    }

    @Test("Unavailable default output falls back to connected priority device")
    func unavailableDefaultFallsBackToPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(
            resolve(
                priorityOrder: ["speakers", "airpods"],
                outputDevices: devices,
                defaultDeviceID: 2,
                unavailableUIDs: ["airpods"]
            ) == "headphones"
        )
    }

    @Test("No output devices falls back to default device then hard fallback")
    func noOutputDevicesFallbacks() {
        #expect(resolve(priorityOrder: [], outputDevices: [], defaultDeviceID: 42) == "speaker.wave.2")

        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: .unknown,
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "unused" },
            symbolForDefaultID: { _ in "unused" }
        )
        #expect(symbol == MenuBarDeviceIconResolver.fallbackSymbol)
    }

    @Test("Resolvable override wins over the derived symbol")
    func resolvableOverrideWins() {
        let devices = [device(id: 2, uid: "airpods", name: "AirPods Pro")]
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: ["airpods"],
            outputDevices: devices,
            defaultDeviceID: 2,
            overrideForUID: { ["airpods": "gamecontroller.fill"][$0] },
            isSymbolResolvable: { _ in true },
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "headphones" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "gamecontroller.fill")
    }

    @Test("Unresolvable override falls back to the derived symbol")
    func unresolvableOverrideFallsBack() {
        let devices = [device(id: 2, uid: "airpods", name: "AirPods Pro")]
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: ["airpods"],
            outputDevices: devices,
            defaultDeviceID: 2,
            overrideForUID: { _ in "not.a.real.symbol" },
            isSymbolResolvable: { _ in false },
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "headphones" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "headphones")
    }

    @Test("The default validator accepts a real SF Symbol and rejects a bogus name")
    func defaultValidatorChecksRealSymbols() {
        let devices = [device(id: 2, uid: "airpods", name: "AirPods Pro")]
        func resolve(override: String) -> String {
            MenuBarDeviceIconResolver.resolveSymbol(
                priorityOrder: ["airpods"],
                outputDevices: devices,
                defaultDeviceID: 2,
                overrideForUID: { _ in override },
                isDeviceAvailable: { _ in true },
                symbolForDevice: { _ in "headphones" },
                symbolForDefaultID: { _ in "speaker.wave.2" }
            )
        }
        #expect(resolve(override: "gamecontroller.fill") == "gamecontroller.fill")
        #expect(resolve(override: "not.a.real.symbol") == "headphones")
    }

    @Test("Priority-path device consults the override too")
    func priorityPathConsultsOverride() {
        let devices = [device(id: 2, uid: "homepod", name: "HomePod")]
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: ["homepod"],
            outputDevices: devices,
            defaultDeviceID: 999,
            overrideForUID: { ["homepod": "tv.fill"][$0] },
            isSymbolResolvable: { _ in true },
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "homepod" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "tv.fill")
    }

    @Test("Default-ID path surfaces a resolvable override")
    func defaultIDOverrideWins() {
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: 42,
            overrideForUID: { ["monitor-uid": "tv.fill"][$0] },
            isSymbolResolvable: { _ in true },
            isDeviceAvailable: { _ in true },
            uidForDefaultID: { _ in "monitor-uid" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "tv.fill")
    }

    @Test("Default-ID path validates the override")
    func defaultIDOverrideValidated() {
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: 42,
            overrideForUID: { _ in "not.a.real.symbol" },
            isSymbolResolvable: { _ in false },
            isDeviceAvailable: { _ in true },
            uidForDefaultID: { _ in "monitor-uid" },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "speaker.wave.2")
    }

    @Test("Default ID with unreadable UID falls through to the derived symbol")
    func defaultIDUnreadableUIDFallsThrough() {
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: 42,
            overrideForUID: { _ in "tv.fill" },
            isSymbolResolvable: { _ in true },
            isDeviceAvailable: { _ in true },
            uidForDefaultID: { _ in nil },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "speaker.wave.2")
    }

    @Test("Invalid default ID returns the fallback without consulting the override")
    func defaultIDInvalidReturnsFallback() {
        var consulted = false
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: .unknown,
            overrideForUID: { _ in
                consulted = true
                return "nope"
            },
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "unused" },
            symbolForDefaultID: { _ in "unused" }
        )
        #expect(symbol == MenuBarDeviceIconResolver.fallbackSymbol)
        #expect(!consulted)
    }
}
```

**Step 2: Commit**
```bash
git add FineTune/Views/MenuBar/MenuBarDeviceIconResolver.swift FineTuneTests/MenuBarDeviceIconResolverTests.swift
git commit -m "fix(menu-bar): fall back when a device icon override no longer resolves"
```

---

### Task 4: Port Upstream Appcast Update

**Files:**
- Modify: `appcast.xml`

**Step 1: Write minimal implementation**
Append the new item for 1.9.0 to `appcast.xml`:
```xml
        <item>
            <title>1.9.0</title>
            <pubDate>Thu, 09 Jul 2026 07:54:54 +0000</pubDate>
            <sparkle:version>38</sparkle:version>
            <sparkle:shortVersionString>1.9.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.4</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/ronitsingh10/FineTune/releases/download/v1.9.0/FineTune.dmg" length="5436346" type="application/octet-stream" sparkle:edSignature="+JnrPmTP+SA05N9EhKX7cVXesDZdIOGzHP8L0IOwZN4RLnp9jNiHjKMg84Cvl2hCOFBHYtvSFvlOTBOMMnA5Cw=="/>
        </item>
```

**Step 2: Commit**
```bash
git add appcast.xml
git commit -m "chore: update appcast for v1.9.0"
```

---

### Task 5: Add Fixed-Size Canvas Size Tests

**Files:**
- Create: `FineTuneTests/MenuBarIconImageSizeTests.swift`

**Step 1: Write implementation**
Create the test suite in `FineTuneTests/MenuBarIconImageSizeTests.swift`:
```swift
// FineTuneTests/MenuBarIconImageSizeTests.swift
// Size invariance for menu bar icons — the status item is variable-length,
// so icons of differing sizes resize it and shift neighboring items.

import AppKit
import Testing
@testable import FineTune

@Suite("MenuBarIconImage — size invariance")
@MainActor
struct MenuBarIconImageSizeTests {

    /// Every image the coordinator can put on the status bar button.
    private var reachableImages: [MenuBarIconImage] {
        var images: [MenuBarIconImage] = [MenuBarIconState.speakerMuted.image]
        images += [VolumeBucket.zero, .low, .mid, .high].map { .systemSymbol($0.symbolName) }
        images += MenuBarIconStyle.allCases.map {
            MenuBarIconState.baseline(style: $0, volume: 0.5, muted: false).image
        }
        images += [
            "macstudio.fill", "macmini.fill", "macbook", "desktopcomputer", "display",
            "appletv", "homepod", "homepodmini", "airplayaudio", "bolt.horizontal",
            "tv", "speaker.wave.2", "hifispeaker",
        ].map { .systemSymbol($0) }
        return images
    }

    @Test("every reachable icon renders at one shared size")
    func allIconsShareOneSize() throws {
        let canonical = try #require(MenuBarIconState.speakerVolume(.high).image.nsImage()).size
        for image in reachableImages {
            let rendered = try #require(image.nsImage(), "\(image) produced no NSImage")
            #expect(rendered.size == canonical, "\(image) is \(rendered.size), canonical is \(canonical)")
        }
    }

    @Test("shared size never downscales the widest speaker symbol")
    func sharedSizeCoversNaturalSymbolSize() throws {
        let shared = try #require(MenuBarIconState.speakerVolume(.high).image.nsImage()).size
        let natural = try #require(NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)).size
        #expect(shared.width >= natural.width)
        #expect(shared.height >= natural.height)
    }

    @Test("template rendering and accessibility description survive")
    func templateAndAccessibilitySurvive() throws {
        for image in [MenuBarIconImage.systemSymbol("speaker.fill"), .asset("MenuBarIcon")] {
            let rendered = try #require(image.nsImage())
            #expect(rendered.isTemplate, "\(image) lost template rendering")
            #expect(rendered.accessibilityDescription == "FineTune", "\(image) lost accessibility description")
        }
    }
}
```

**Step 2: Commit**
```bash
git add FineTuneTests/MenuBarIconImageSizeTests.swift
git commit -m "test: add size invariance tests for menu bar icons"
```

---

### Task 6: Verification and PR

**Step 1: Run verification tests**
Verify build & test pass.

**Step 2: Push branch and print PR URL**
Push to remote and generate PR URL.
