import AppKit

/// App lifetime, not frontmost-app lifetime: switching to an editor must not
/// make the next Cmd+S cold. Keep only the native host when Rex is absent/asleep.
@MainActor
final class RexAppMonitor {
    static let bundleIdentifier = "com.superlogical.rex"
    private static let preferences = UserDefaults(suiteName: "com.superlogical.rex")
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private(set) var isAvailable = false
    var onChange: ((Bool) -> Void)?

    /// Rex exposes no selected-session API. Its read-only focus preference is
    /// meaningful only for the frontmost app, never for an arbitrary --client.
    static func focusedSessionID(rexAppPID: Int32?) -> String? {
        guard let rexAppPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == rexAppPID,
              let data = preferences?.data(forKey: "Workspace.lastFocusedSession") else { return nil }
        struct Focus: Decodable { let sessionID: String }
        return try? JSONDecoder().decode(Focus.self, from: data).sessionID
    }

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
