import AppKit
import ReshCore

/// App lifetime, not frontmost-app lifetime: switching to an editor must not
/// make the next Cmd+S cold. Keep only the native host when Rex is absent/asleep.
@MainActor
final class RexAppMonitor {
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private(set) var isAvailable = false
    var onChange: ((Bool) -> Void)?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.willSleepNotification { self.sleeping = true }
                    if name == NSWorkspace.didWakeNotification { self.sleeping = false }
                    self.refresh()
                }
            })
        }
    }

    func refresh() {
        let available = !sleeping && NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && PanelShortcut.launcherIsEnabled(frontmostBundleID: $0.bundleIdentifier)
        }
        guard available != isAvailable else { return }
        isAvailable = available
        onChange?(available)
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []; onChange = nil
    }
}
