import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey: works from a background
/// (accessory) app and needs no special permissions, unlike NSEvent global
/// monitors.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var handler: (() -> Void)?

    private init() {}

    /// Default binding: Cmd+Shift+V.
    func registerDefaultHotKey() {
        register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let selfPointer = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData -> OSStatus in
                    guard let userData else { return noErr }
                    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in
                        center.handler?()
                    }
                    return noErr
                },
                1,
                &eventType,
                selfPointer,
                &eventHandlerRef
            )
        }

        let hotKeyID = EventHotKeyID(signature: 0x434C_5059, id: 1) // 'CLPY'
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
