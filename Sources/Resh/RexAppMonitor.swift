import AppKit

/// App lifetime, not frontmost-app lifetime: switching to an editor must not
/// make the next Cmd+S cold. Keep only the native host when Rex is absent/asleep.
@MainActor
final class RexAppMonitor {
    static let bundleIdentifier = "com.superlogical.rex"
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
            !$0.isTerminated && $0.bundleIdentifier == Self.bundleIdentifier
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
