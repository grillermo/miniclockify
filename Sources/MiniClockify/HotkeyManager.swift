import Foundation
import Carbon.HIToolbox
import AppKit

/// Wraps Carbon's global-hotkey API (RegisterEventHotKey). Carbon has no
/// Swift-native replacement for *system-wide* hotkeys outside the app's own
/// key window, so this stays Carbon despite the rest of the app being
/// SwiftUI/AppKit. Persists the binding so it survives relaunch and can be
/// changed from PreferencesView without restarting the app.
@MainActor
final class HotkeyManager {
    struct Binding: Equatable, Codable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier mask (cmdKey | optionKey | controlKey | shiftKey)

        static let `default` = Binding(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
    }

    private static let defaultsKey = "hotkeyBinding"
    private let defaults: UserDefaults
    private let onToggle: () -> Void
    // Accessed from `deinit`, which runs nonisolated even on a @MainActor
    // class; these pointer types aren't Sendable, so mark them
    // nonisolated(unsafe). In practice they're only ever touched on the
    // main actor (init/rebind/unregister) or during teardown.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x434c4b46 /* "CLKF" */), id: 1)

    private(set) var binding: Binding

    init(defaults: UserDefaults = .standard, onToggle: @escaping () -> Void) {
        self.defaults = defaults
        self.onToggle = onToggle
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Binding.self, from: data) {
            binding = saved
        } else {
            binding = .default
        }
        installHandler()
        if !register(binding) {
            // The loaded/saved binding may be claimed by another app now;
            // fall back to the default combo (best-effort, never throw
            // from init). If even the default fails, leave hotKeyRef nil —
            // a degraded-but-safe state with no active hotkey.
            binding = .default
            _ = register(binding)
        }
    }

    /// Re-registers with a new binding and persists it on success. On
    /// failure, rolls back to the previous binding (best-effort) and leaves
    /// the persisted value untouched.
    @discardableResult
    func rebind(_ new: Binding) -> Bool {
        guard new.modifiers != 0 else { return false }
        let previous = binding
        unregister()
        if register(new) {
            binding = new
            if let data = try? JSONEncoder().encode(new) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
            return true
        } else {
            binding = previous
            _ = register(previous)
            return false
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if hkID.id == manager.hotKeyID.id { manager.onToggle() }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    /// Registers `binding` with Carbon. Returns true if registration
    /// succeeded (`noErr`), false otherwise (e.g. the combo is already
    /// claimed by another app).
    private func register(_ binding: Binding) -> Bool {
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    private func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }
}
