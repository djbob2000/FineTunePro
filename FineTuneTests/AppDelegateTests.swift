// FineTuneTests/AppDelegateTests.swift
import Testing
import AppKit
@testable import FineTune

@Suite("AppDelegate")
@MainActor
struct AppDelegateTests {
    @Test("applicationShouldHandleReopen posts openSettingsWindow notification")
    func testReopenPostsNotification() async {
        let delegate = AppDelegate()
        
        var notificationReceived = false
        let expectation = NotificationCenter.default.addObserver(
            forName: .openSettingsWindow,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived = true
        }
        defer { NotificationCenter.default.removeObserver(expectation) }
        
        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        
        #expect(handled == true)
        #expect(notificationReceived == true)
    }
}
