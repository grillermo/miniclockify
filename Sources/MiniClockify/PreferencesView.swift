import SwiftUI
import Carbon.HIToolbox

struct PreferencesView: View {
    let auth: AuthManager
    let hotkey: HotkeyManager
    @State private var recording = false
    /// The saved binding currently active. Held locally because HotkeyManager
    /// isn't observable, so the view refreshes this on a successful save.
    @State private var saved: HotkeyManager.Binding
    /// A captured-but-not-yet-saved combo. nil when there's nothing pending.
    @State private var draft: HotkeyManager.Binding?
    @State private var errorMessage: String?

    init(auth: AuthManager, hotkey: HotkeyManager) {
        self.auth = auth
        self.hotkey = hotkey
        _saved = State(initialValue: hotkey.binding)
    }

    var body: some View {
        Form {
            HStack {
                Text("Toggle timer hotkey")
                Button(shortcutLabel) { recording.toggle() }
                    .buttonStyle(.borderedProminent)
                    .tint(recording ? .accentColor : Color(nsColor: .controlColor))
                    .foregroundStyle(recording ? Color.white : Color.primary)
                    .background(HotkeyRecorderCatcher(isActive: $recording) { keyCode, modifiers in
                        draft = HotkeyManager.Binding(keyCode: keyCode, modifiers: modifiers)
                        errorMessage = nil
                        recording = false
                    })
                Button("Save") { save() }
                    .disabled(draft == nil || draft == saved)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Button("Sign out / clear API key", role: .destructive) { auth.signOut() }
        }
        .padding(20)
        .fixedSize()
        // Esc closes the Settings window (not the app). Hidden zero-size button
        // grabs the cancel action; the HotkeyRecorderCatcher swallows keys while
        // recording, so Esc only reaches here when we're not capturing a combo.
        .background(
            Button("", action: closeSettingsWindow)
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }

    /// Closes just the Settings window. Looks it up by SwiftUI's stable private
    /// identifier (same one positionSettingsWindowNearMenuBar uses).
    private func closeSettingsWindow() {
        NSApp.windows
            .first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?
            .performClose(nil)
    }

    private var shortcutLabel: String {
        if recording { return "Press keys…" }
        return label(for: draft ?? saved)
    }

    private func save() {
        guard let draft else { return }
        if hotkey.rebind(draft) {
            saved = draft
            self.draft = nil
            errorMessage = nil
        } else {
            errorMessage = draft.modifiers == 0
                ? "Shortcut needs at least one modifier key (⌘/⌥/⌃/⇧)."
                : "That shortcut is unavailable (already in use)."
        }
    }

    private func label(for binding: HotkeyManager.Binding) -> String {
        var parts: [String] = []
        if binding.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if binding.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if binding.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if binding.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: binding.keyCode))
        return parts.joined()
    }
}

/// Invisible NSView that becomes first responder while `isActive` and reports
/// the next raw keyDown as a Carbon key code + modifier mask. Kept tiny and
/// AppKit-only so PreferencesView (SwiftUI) stays declarative.
private struct HotkeyRecorderCatcher: NSViewRepresentable {
    @Binding var isActive: Bool
    let onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView(); v.onCapture = onCapture; return v
    }
    func updateNSView(_ view: CatcherView, context: Context) {
        view.isActive = isActive
        if isActive {
            view.window?.makeFirstResponder(view)
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    final class CatcherView: NSView {
        var onCapture: ((UInt32, UInt32) -> Void)?
        /// Only capture keystrokes while the recorder is armed. Without this the
        /// view swallows every keyDown the moment it becomes first responder
        /// (e.g. right after the window opens), auto-capturing an unwanted combo.
        var isActive = false
        override var acceptsFirstResponder: Bool { isActive }
        override func keyDown(with event: NSEvent) {
            guard isActive else { super.keyDown(with: event); return }
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            onCapture?(UInt32(event.keyCode), mods)
        }
    }
}

/// Minimal virtual-keycode → display-name lookup for the recorder label.
/// Only covers letters/digits (sufficient for a hotkey like ⌃⌥⌘T); unknown
/// codes fall back to a numeric placeholder rather than crashing.
enum KeyCodeNames {
    private static let names: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z"
    ]
    static func name(for code: UInt32) -> String { names[code] ?? "#\(code)" }
}
