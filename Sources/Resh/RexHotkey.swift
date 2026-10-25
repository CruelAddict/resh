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
    private var isPressed = false
    private(set) var registrationStatus: OSStatus = noErr
    var onPress: (() -> Void)?
    var isRegistered: Bool { hotkey != nil }

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        registrationStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                id.signature == 0x72657368, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<RexHotkey>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    shortcut.isPressed = false
                } else if !shortcut.isPressed {
                    shortcut.isPressed = true
                    shortcut.onPress?()
                }
            }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRegistration() }
            }
        updateRegistration()
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
            isPressed = false
        }
    }

    func stop() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        hotkey = nil; handler = nil; observer = nil
        isPressed = false
    }
}
