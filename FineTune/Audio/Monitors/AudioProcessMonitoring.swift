@MainActor
protocol AudioProcessMonitoring: AnyObject {
    var activeApps: [AudioApp] { get }
    var onAppsChanged: (([AudioApp]) -> Void)? { get set }

    /// Registered audio clients, including paused clients whose taps can be prepared before playback.
    var capturableApps: [AudioApp] { get }
    var onCapturableAppsChanged: (([AudioApp]) -> Void)? { get set }

    func start()
    func stop()
    func refreshNow()
}

extension AudioProcessMonitoring {
    var capturableApps: [AudioApp] { activeApps }
    var onCapturableAppsChanged: (([AudioApp]) -> Void)? {
        get { nil }
        set {}
    }
    func refreshNow() {}
}
