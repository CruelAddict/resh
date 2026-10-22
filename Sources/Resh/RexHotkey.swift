import AppKit
import Carbon
import ReshCore

/// Register a virtual key, not a character. Registration exists only while Rex is
/// the frontmost application, so Save in every other application is untouched.
@MainActor
final class RexHotkey {
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private var observer: NSObjectProtocol?
    private(set) var registrationStatus: OSStatus = noErr
    var onPress: (() -> Void)?
    var isRegistered: Bool { hotkey != nil }

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        registrationStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                id.signature == 0x72657368, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<RexHotkey>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.onPress?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRegistration() }
            }
        updateRegistration()
    }

    /// Exercise the native callback without posting global keyboard input or asking for Accessibility.
    func exerciseHandler() -> OSStatus {
        guard isRegistered else { return OSStatus(eventNotHandledErr) }
        var event: EventRef?
        var id = EventHotKeyID(signature: 0x72657368, id: 1)
        let status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
        guard status == noErr, let event else { return status }
        defer { ReleaseEvent(event) }
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &id)
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    private func updateRegistration() {
        let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let shouldRegister = PanelShortcut.launcherIsEnabled(frontmostBundleID: active)
        if shouldRegister, hotkey == nil, handler != nil {
            registrationStatus = RegisterEventHotKey(UInt32(PanelShortcut.launcherKeyCode), UInt32(cmdKey),
                EventHotKeyID(signature: 0x72657368, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        } else if !shouldRegister, let hotkey {
            UnregisterEventHotKey(hotkey)
            self.hotkey = nil
        }
    }

    func stop() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        hotkey = nil; handler = nil; observer = nil
    }
}
