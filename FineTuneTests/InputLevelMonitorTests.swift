// FineTuneTests/InputLevelMonitorTests.swift
import Testing
@testable import FineTune
import Foundation

@Suite("InputLevelMonitor Tests")
@MainActor
struct InputLevelMonitorTests {
    @Test("Initial state has zero levels and no callbacks")
    func testInitialState() {
        let monitor = InputLevelMonitor()
        #expect(monitor.peakLevel == 0.0)
        #expect(monitor.channelLevels == [0.0, 0.0])
        #expect(!monitor.hasRecentAudioCallback(within: 1.0))
    }

    @Test("Starting with unknown device ID is safe and doesn't run")
    func testStartWithUnknownDevice() {
        let monitor = InputLevelMonitor()
        monitor.start(deviceID: .unknown)
        #expect(monitor.peakLevel == 0.0)
        #expect(!monitor.hasRecentAudioCallback(within: 1.0))
        monitor.stop()
    }

    @Test("Stopping a non-running monitor is a safe no-op")
    func testStopSafety() {
        let monitor = InputLevelMonitor()
        // stopping a non-running monitor should be a safe no-op
        monitor.stop()
        #expect(monitor.peakLevel == 0.0)
    }
}
