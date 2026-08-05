import SwiftUI
import Carbon.HIToolbox

@main
struct MiniClockifyApp: App {
    @NSApplicationDelegateAdaptor(AppState.self) private var app

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: app)
        } label: {
            // Must be a View with @ObservedObject, not inline Scene content:
            // SwiftUI does not re-evaluate a Scene body on an ObservableObject's
            // @Published change, so an inline label would freeze at 00:00:00.
            MenuBarLabel(app: app)
        }
        Settings {
            // The conditional must live in a view observing AppState: the App
            // body runs before applicationDidFinishLaunching sets auth/hotkey,
            // and a scene-level `if let` snapshots the empty branch forever,
            // leaving a zero-width settings window.
            SettingsRoot(app: app)
        }
    }
}

@MainActor
final class AppState: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var auth: AuthManager?
    @Published var tracking: TrackingStore?
    @Published var elapsed = "00:00:00"

    private var panel: QuickEntryPanel?
    @Published var hotkey: HotkeyManager?
    private var authWindow: NSWindow?
    private var ticker: Timer?
    private var isHandlingToggle = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let auth = AuthManager()
        self.auth = auth
        hotkey = HotkeyManager(onToggle: { [weak self] in
            Task { await self?.handleToggle() }
        })
        Task { await bootstrap(auth) }
        startTicker()
    }

    private func bootstrap(_ auth: AuthManager) async {
        await auth.bootstrap()
        await refreshFromAuth()
    }

    private func refreshFromAuth() async {
        guard let auth else { return }
        switch auth.state {
        case .needsAuth: showAuthWindow()
        case .authenticated(let user):
            authWindow?.close(); authWindow = nil
            guard let client = auth.client else { return }
            let store = TrackingStore(api: client, workspaceId: user.defaultWorkspace,
                                      userId: user.id)
            let projects: [Project]
            do {
                projects = try await client.projects(workspaceId: user.defaultWorkspace)
            } catch {
                Notifier.notify("Could not load Clockify projects. Try again later.")
                projects = []
            }
            store.setProjects(projects)
            await store.reconcile()
            self.tracking = store
            self.panel = QuickEntryPanel(tracking: store, api: client)
        }
    }

    func handleToggle() async {
        guard !isHandlingToggle else { return }
        isHandlingToggle = true
        defer { isHandlingToggle = false }
        guard let tracking else { showAuthWindow(); return }
        await tracking.toggle()
        switch tracking.pendingIntent {
        case .requestQuickEntry: tracking.clearIntent(); panel?.show()
        case .requestStopConfirm: tracking.clearIntent(); panel?.showStopConfirm()
        case .none: break
        }
        surfaceError()
    }

    /// Menu Stop/Discard route through here so their failures are surfaced the
    /// same way as the hotkey path (spec §Error Handling).
    func stopFromMenu() async { await tracking?.stop(); surfaceError() }
    func discardFromMenu() async { await tracking?.discard(); surfaceError() }

    private func surfaceError() {
        // stop/discard intentionally stay .running on failure for retry; notify
        // (if authorized) and MenuContent also renders a red retry item inline.
        if let err = tracking?.lastError { Notifier.notify(err) }
    }

    private func showAuthWindow() {
        guard let auth else { return }
        if authWindow != nil { authWindow?.makeKeyAndOrderFront(nil); return }
        let hosting = NSHostingController(rootView: AuthWindowWrapper(auth: auth) { [weak self] in
            Task { await self?.refreshFromAuth() }
        })
        let w = NSWindow(contentViewController: hosting)
        w.title = "MiniClockify"; w.styleMask = [.titled, .closable]
        w.center(); authWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
    }

    private func updateElapsed() {
        guard case .running(_, let start, _, _)? = tracking?.state else { elapsed = "..."; return }
        let t = Int(Date().timeIntervalSince(start))
        elapsed = String(format: "%02d:%02d:%02d", t/3600, (t%3600)/60, t%60)
    }
}

/// Observing wrapper for the Settings scene so the window re-renders once
/// AppState finishes bootstrapping (see comment at the Settings scene).
struct SettingsRoot: View {
    @ObservedObject var app: AppState
    var body: some View {
        if let auth = app.auth, let hotkey = app.hotkey {
            PreferencesView(auth: auth, hotkey: hotkey)
        }
    }
}

/// Bridges AuthManager state changes back to AppState after submit.
struct AuthWindowWrapper: View {
    @Bindable var auth: AuthManager
    let onAuthenticated: () -> Void
    var body: some View {
        AuthWindow(auth: auth)
            .onChange(of: authKey) { _, _ in
                if case .authenticated = auth.state { onAuthenticated() }
            }
    }
    private var authKey: String {
        if case .authenticated(let u) = auth.state { return u.id }; return ""
    }
}

/// Menu-bar icon + live elapsed clock. As a View with @ObservedObject it
/// re-renders every second when the ticker updates AppState.elapsed.
struct MenuBarLabel: View {
    @ObservedObject var app: AppState
    var body: some View {
        Image(systemName: "timer")
        if case .running? = app.tracking?.state {
            Text(app.elapsed)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var app: AppState
    // SettingsLink opens the window but never activates an LSUIElement
    // (.accessory) app, so it appears behind everything = "nothing happens".
    // Activate first, then open, so the window comes to the front.
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("Log time \(shortcutLabel)") { Task { await app.handleToggle() } }
        Divider()
        if case .running? = app.tracking?.state {
            Button("Stop timer") { Task { await app.stopFromMenu() } }
            Button("Discard timer") { Task { await app.discardFromMenu() } }
            if let err = app.tracking?.lastError {
                // Permission-free fallback when a stop/discard failed and the
                // timer is still running (spec §Error Handling).
                Text("⚠️ \(err) Try again.").foregroundStyle(.red)
            }
            Divider()
        }
        Button("Preferences…") {
            // Accessory (LSUIElement) apps can't reliably bring a window
            // front. Switch to .regular so a Dock icon appears and the
            // Settings window is focusable, then activate and open.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            positionSettingsWindowNearMenuBar()
        }
        Button("Quit") { NSApp.terminate(nil) }
    }

    /// Formatted current toggle shortcut (e.g. "⌃⌥⌘⇧C") for the menu label,
    /// falling back to empty if the hotkey manager isn't ready yet.
    private var shortcutLabel: String {
        guard let binding = app.hotkey?.binding else { return "" }
        var parts: [String] = []
        if binding.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if binding.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if binding.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if binding.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: binding.keyCode))
        return parts.joined()
    }
}

/// Moves the SwiftUI Settings window just below the menu bar icon, horizontally
/// centered on it (falling back to the top-right corner if the icon can't be
/// located). `openSettings()` creates the window asynchronously, so retry a few
/// times until it exists (identifier is SwiftUI's private-but-stable Settings id).
@MainActor
private func positionSettingsWindowNearMenuBar(attempt: Int = 0) {
    // Also wait for layout: right after openSettings() the window briefly
    // exists at zero width, and positioning off that size pushes the real
    // window off the screen edge.
    let window = NSApp.windows.first {
        $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            && $0.frame.width > 100
    }
    guard let window, let screen = NSScreen.main else {
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            positionSettingsWindowNearMenuBar(attempt: attempt + 1)
        }
        return
    }
    let visible = screen.visibleFrame
    let size = window.frame.size

    // MenuBarExtra hides its NSStatusItem, but the icon's button lives in an
    // NSStatusBarWindow whose frame tells us where the icon sits.
    let statusFrame = NSApp.windows.first {
        $0.className.contains("NSStatusBarWindow")
    }?.frame

    let x: CGFloat
    if let statusFrame {
        // Center under the icon, clamped to stay on-screen.
        let centered = statusFrame.midX - size.width / 2
        x = min(max(centered, visible.minX + 8), visible.maxX - size.width - 8)
    } else {
        x = visible.maxX - size.width - 8
    }
    let origin = NSPoint(x: x, y: visible.maxY - size.height - 8)
    window.setFrameOrigin(origin)

    // Preferences flips the app to .regular so its window can come to the
    // front (see the "Preferences…" button). Restore .accessory once the
    // window closes so the Dock icon disappears again.
    SettingsWindowCloseObserver.watch(window)
}

/// One-shot observer that restores `.accessory` activation policy when the
/// Settings window closes, so the Dock icon added for Preferences goes away.
/// A dedicated `@MainActor` class keeps the token capture Swift 6-clean.
@MainActor
private final class SettingsWindowCloseObserver {
    private var token: NSObjectProtocol?

    static func watch(_ window: NSWindow) {
        let observer = SettingsWindowCloseObserver()
        observer.token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.accessory)
                observer.stop()
            }
        }
    }

    private func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
