import Foundation
import AppKit

/// Best-effort "pause triggers" for a menu bar time tracker.
/// - screensaver start/stop notifications (DistributedNotificationCenter)
/// - system sleep / screen sleep (NSWorkspace notifications)
/// - session resign active (lock / fast user switching)
final class ActivityMonitor {
    private var tokens: [Any] = []
    private var onPause: (() -> Void)?

    func start(onPause: @escaping () -> Void) {
        stop()
        self.onPause = onPause

        let ws = NSWorkspace.shared
        let nc = ws.notificationCenter

        tokens.append(nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.onPause?() })

        tokens.append(nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.onPause?() })

        tokens.append(nc.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.onPause?() })

        // Screensaver start (most direct for your request).
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.onPause?() })
    }

    func stop() {
        let ws = NSWorkspace.shared
        let nc = ws.notificationCenter
        for t in tokens { nc.removeObserver(t) }
        // DistributedNotificationCenter observers must also be removed via DNC.
        DistributedNotificationCenter.default().removeObserver(self)
        tokens.removeAll()
        onPause = nil
    }

    deinit { stop() }
}
