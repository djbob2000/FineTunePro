import AppKit

@MainActor
final class MenuBarPopupPositioner {
    private let position: () -> MenuBarPopupPosition
    private let popupWindow: () -> NSWindow?
    private let statusItemFrame: () -> NSRect?
    private let visibleFrame: () -> NSRect?
    private var observers: [NSObjectProtocol] = []
    private var pendingPlacement: DispatchWorkItem?
    private var isApplyingFrame = false
    private var started = false

    init(
        position: @escaping () -> MenuBarPopupPosition,
        popupWindow: @escaping () -> NSWindow?,
        statusItemFrame: @escaping () -> NSRect?,
        visibleFrame: @escaping () -> NSRect?
    ) {
        self.position = position
        self.popupWindow = popupWindow
        self.statusItemFrame = statusItemFrame
        self.visibleFrame = visibleFrame
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        let windowNotifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
            NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]
        for name in windowNotifications {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, window === self.popupWindow() else { return }
                    self.reposition()
                }
            })
        }
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        reposition()
    }

    func stop() {
        started = false
        pendingPlacement?.cancel()
        pendingPlacement = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    /// Coalesce AppKit and SwiftUI size updates, then apply after the library has
    /// finished setting its frame. Corrective moves cannot enqueue another pass.
    func reposition() {
        guard started, !isApplyingFrame, pendingPlacement == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPlacement = nil
            guard self.started, let window = self.popupWindow(), window.isVisible,
                  let statusItemFrame = self.statusItemFrame(),
                  let visibleFrame = self.visibleFrame() else { return }
            let frame = self.position().frame(
                size: window.frame.size, statusItemFrame: statusItemFrame, visibleFrame: visibleFrame
            )
            guard frame != window.frame else { return }
            self.isApplyingFrame = true
            window.setFrame(frame, display: true, animate: false)
            self.isApplyingFrame = false
        }
        pendingPlacement = work
        DispatchQueue.main.async(execute: work)
    }
}
