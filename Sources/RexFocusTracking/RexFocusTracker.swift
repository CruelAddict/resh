import AppKit
import Foundation

/// Temporary adapter for Rex's private focus preference. Replace this target when
/// Rex exposes selected-session events. No timers or UserDefaults fallback live here.
@MainActor
public final class RexFocusTracker {
    public var onChange: (() -> Void)?
    public var onDiagnostic: ((Error?) -> Void)?
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.superlogical.rex.plist")
    private let activationCenter = NSWorkspace.shared.notificationCenter
    private var watcher: FileWatcher?
    private var activationObserver: NSObjectProtocol?
    private var sessionID: String?
    private var generation = 0

    public init() {}

    deinit {
        watcher?.stop()
        if let activationObserver { activationCenter.removeObserver(activationObserver) }
    }

    public func start() {
        guard watcher == nil else { return }
        generation += 1
        let request = generation, url = url
        watcher = FileWatcher(url: url, onChange: { [weak self] in
            let result = Result { try Self.read(url) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == request else { return }
                    switch result {
                    case let .success(id):
                        self.sessionID = id
                        self.onDiagnostic?(nil)
                    case let .failure(error):
                        self.sessionID = nil
                        self.onDiagnostic?(error)
                    }
                    self.onChange?()
                }
            }
        }, onError: { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == request else { return }
                    self.onDiagnostic?(error)
                }
            }
        })
        activationObserver = activationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
    }

    public func stop() {
        generation += 1
        watcher?.stop(); watcher = nil
        if let activationObserver { activationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        sessionID = nil
    }

    /// A single preference describes the frontmost Rex app, not arbitrary clients.
    public func selectedSession(in processID: Int32?) -> String? {
        guard let processID, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.superlogical.rex", app.processIdentifier == processID else { return nil }
        return sessionID
    }

    private nonisolated static func read(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        guard let preferences = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let value = preferences["Workspace.lastFocusedSession"] else { return nil }
        guard let value = value as? Data else { throw CocoaError(.propertyListReadCorrupt) }
        struct Focus: Decodable { let sessionID: String }
        let focus = try JSONDecoder().decode(Focus.self, from: value)
        guard !focus.sessionID.isEmpty else { throw CocoaError(.propertyListReadCorrupt) }
        return focus.sessionID
    }
}
