import AppKit
import Testing
@testable import FineTune

@Suite("Bluetooth explicit output selection")
@MainActor
struct BluetoothOutputSelectionTests {
    private func output(_ uid: String, transport: TransportType = .bluetooth) -> AudioDevice {
        AudioDevice(id: 100, uid: uid, name: "Same Name", icon: nil, supportsAutoEQ: true, transportType: transport)
    }

    @Test("MAC identity handles CoreAudio suffixes and rejects same-name devices")
    func identity() {
        #expect(BluetoothOutputIdentity.matches(mac: "AA:BB:CC:DD:EE:FF", device: output("aa-bb-cc-dd-ee-ff:output")))
        #expect(!BluetoothOutputIdentity.matches(mac: "AA:BB:CC:DD:EE:FF", device: output("11-22-33-44-55-66:output")))
        #expect(!BluetoothOutputIdentity.matches(mac: "AA:BB:CC:DD:EE:FF", device: output("AA-BB-CC-DD-EE-FF:output", transport: .usb)))
    }

    @Test("Latest Connect intent owns selection; unrelated appearances do not clear it")
    func latestIntent() async throws {
        let monitor = BluetoothDeviceMonitor(connectionOpener: { _ in 0 })
        let first = PairedBluetoothDevice(id: "11:22:33:44:55:66", name: "Same Name", icon: nil)
        let second = PairedBluetoothDevice(id: "AA:BB:CC:DD:EE:FF", name: "Same Name", icon: nil)
        monitor.connect(device: first)
        monitor.connect(device: second)
        #expect(!monitor.wantsToSelectOutput(output("11-22-33-44-55-66:output")))
        #expect(monitor.wantsToSelectOutput(output("AA-BB-CC-DD-EE-FF:output")))
        monitor.notifyDeviceAppearedInCoreAudio([output("11-22-33-44-55-66:output")])
        #expect(monitor.wantsToSelectOutput(output("AA-BB-CC-DD-EE-FF:output")))
        monitor.completeOutputSelection(output("AA-BB-CC-DD-EE-FF:output"), succeeded: true)
        #expect(!monitor.wantsToSelectOutput(output("AA-BB-CC-DD-EE-FF:output")))
        #expect(!monitor.connectingIDs.contains(second.id))
    }

    @Test("Failed and timed-out connections cannot change output later")
    func failureAndTimeout() async throws {
        let failed = BluetoothDeviceMonitor(connectionOpener: { _ in -1 })
        let timedOut = BluetoothDeviceMonitor(connectTimeoutSeconds: 0.01, connectionOpener: { _ in 0 })
        let device = PairedBluetoothDevice(id: "AA:BB:CC:DD:EE:FF", name: "Headphones", icon: nil)
        failed.connect(device: device)
        timedOut.connect(device: device)
        for _ in 0..<100 {
            if failed.connectingIDs.isEmpty && timedOut.connectingIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for monitor in [failed, timedOut] {
            #expect(monitor.connectingIDs.isEmpty)
            #expect(monitor.connectionErrors[device.id] != nil)
            #expect(!monitor.wantsToSelectOutput(output("AA-BB-CC-DD-EE-FF:output")))
        }
    }
}
