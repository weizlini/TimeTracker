import Foundation
import AppKit

final class ActivityMonitor {
    private var onStop: (() -> Void)?
    private var onUnlock: (() -> Void)?

    private var stopFired = false

    private var ncObservers: [Any] = []
    private var wsObservers: [Any] = []
    private var distObservers: [Any] = []

    func start(onStop: @escaping () -> Void, onUnlock: @escaping () -> Void) {
        stop()

        self.onStop = onStop
        self.onUnlock = onUnlock
        self.stopFired = false

        let nc = NotificationCenter.default
        let wsnc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // Session resign (sometimes on lock/login window)
        ncObservers.append(nc.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fireStopOnce()
        })

        // Sleep
        wsObservers.append(wsnc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fireStopOnce()
        })

        // Displays sleep
        wsObservers.append(wsnc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fireStopOnce()
        })

        // Screensaver start (covers some screensaver paths)
        distObservers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fireStopOnce()
        })

        // Screen lock (covers Touch ID lock / Lock Screen)
        distObservers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fireStopOnce()
        })

        // Screen unlock (prompt resume)
        distObservers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stopFired = false
            self.onUnlock?()
        })
    }

    func stop() {
        let nc = NotificationCenter.default
        let wsnc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        for o in ncObservers { nc.removeObserver(o) }
        for o in wsObservers { wsnc.removeObserver(o) }
        for o in distObservers { dnc.removeObserver(o) }

        ncObservers.removeAll()
        wsObservers.removeAll()
        distObservers.removeAll()

        onStop = nil
        onUnlock = nil
        stopFired = false
    }

    private func fireStopOnce() {
        guard !stopFired else { return }
        stopFired = true
        onStop?()
    }

    deinit { stop() }
}
