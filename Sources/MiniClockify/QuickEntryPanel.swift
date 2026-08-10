import SwiftUI
import AppKit

@MainActor
final class QuickEntryPanel {
    private var panel: NSPanel?
    private let tracking: TrackingStore
    private let api: ClockifyAPI

    init(tracking: TrackingStore, api: ClockifyAPI) {
        self.tracking = tracking; self.api = api
    }

    func show() {
        if panel != nil { close(); return }
        let project = tracking.resolveDefaultProject()
        let view = QuickEntryView(
            tracking: tracking, api: api, project: project,
            onDone: { [weak self] in self?.close() })
        present(NSHostingController(rootView: view), height: 290)
    }

    /// Hotkey-while-running confirmation: same floating panel, Enter stops & logs.
    func showStopConfirm() {
        if panel != nil { close(); return }
        // The description can be arbitrarily long, so the panel is made tall enough
        // for the wrapped text instead of clipping it at a fixed height.
        //
        // We measure the height up front and keep the window size ours alone —
        // `sizingOptions = []` stops the hosting view publishing SwiftUI's sizes to
        // the window. Both ways of letting it size the window failed: the minimum
        // content size it derives from a wrapping Text stretched the panel far past
        // the screen, and `.preferredContentSize` resizing this fixed-size panel
        // threw an uncaught exception in AppKit's layout pass on open.
        let view = StopConfirmView(
            tracking: tracking, onDone: { [weak self] in self?.close() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        var description = ""
        if case .running(_, _, let d, _) = tracking.state { description = d }
        present(hosting,
                height: StopConfirmMetrics.panelHeight(
                    description: description, width: Self.width, maxHeight: Self.maxHeight))
    }

    private static let width: CGFloat = 460

    /// Never taller than most of the screen, however long the description is.
    private static var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) * 0.8
    }

    private func present(_ hosting: NSViewController, height: CGFloat) {
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.setContentSize(NSSize(width: Self.width, height: height))
        p.center()
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.close(); panel = nil }
}

struct QuickEntryView: View {
    @Bindable var tracking: TrackingStore
    let api: ClockifyAPI
    let project: Project?
    let onDone: () -> Void

    @State private var text = ""
    @State private var startTime = Date()
    @State private var all: [String] = []
    @State private var highlighted = 0
    @State private var starting = false
    /// Set to the value we just Tab-completed to; suppresses the ghost suggestion
    /// so Tab reverts to normal focus-advance until the user types again.
    @State private var accepted: String?
    @FocusState private var focused: Bool

    private var matches: [String] {
        RecentDescriptions.filter(descriptions: all, query: text)
    }

    /// Inline autocomplete candidate (dimmed ghost tail), or nil when nothing to
    /// complete or the current text was just accepted via Tab.
    private var suggestion: String? {
        guard accepted != text else { return nil }
        return RecentDescriptions.firstAutocomplete(descriptions: all, query: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What are you working on?", text: $text)
                .textFieldStyle(.plain).font(.title3).focused($focused)
                .disabled(starting)
                // Dimmed ghost of the autocomplete candidate. For a prefix match
                // the remaining tail is laid out just past the cursor; for a
                // mid-word (substring) match the whole suggestion is shown as a
                // "→ …" hint after the typed text, since it can't align inline.
                .overlay(alignment: .leading) {
                    if let s = suggestion {
                        ghost(for: s)
                            .font(.title3)
                            .allowsHitTesting(false)
                    }
                }
                .onSubmit { start() }
                .onChange(of: text) { _, _ in highlighted = 0 }  // reset on filter change
                // Tab accepts the ghost suggestion in place; with none, fall through
                // (.ignored) so focus advances to the DatePicker as usual.
                .onKeyPress(.tab) {
                    guard let s = suggestion else { return .ignored }
                    text = s
                    accepted = s
                    return .handled
                }
            HStack {
                Text(project.map { "→ \($0.name)" } ?? "→ No project yet")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                DatePicker("", selection: $startTime, in: ...Date(),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden().disabled(starting)
                    .onKeyPress(.return) { start(); return .handled }
            }
            if let err = tracking.lastError {
                Text(err).font(.caption).foregroundStyle(.red)   // inline retry surface
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(matches.prefix(5).enumerated()), id: \.offset) { i, d in
                        Text(d)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(i == highlighted ? Color.accentColor.opacity(0.25) : .clear)
                            .onTapGesture { text = d; start() }
                    }
                }
            }.frame(maxHeight: 230)
        }
        .padding(16)
        .task {
            focused = true
            startTime = Date()   // reset to "now" each time the panel opens
            all = await RecentDescriptions.fetch(
                api: api, workspaceId: tracking.workspaceId, userId: tracking.userId)
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) {
            guard !starting else { return .handled }
            onDone()
            return .handled
        }
    }

    private func ghost(for s: String) -> Text {
        if s.lowercased().hasPrefix(text.lowercased()) {
            return Text(String(s.prefix(text.count))).foregroundStyle(.clear)
                + Text(s.dropFirst(text.count)).foregroundStyle(.tertiary)
        }
        return Text(text).foregroundStyle(.clear)
            + Text("  → \(s)").foregroundStyle(.tertiary)
    }

    private func move(_ d: Int) {
        let n = min(matches.count, 5)
        guard n > 0 else { return }
        highlighted = (highlighted + d + n) % n
    }

    private func start() {
        guard !starting else { return }
        let chosen: String
        let m = matches
        if m.indices.contains(highlighted)
            && (text.isEmpty || m[highlighted].localizedCaseInsensitiveContains(text)) {
            chosen = m[highlighted]
        } else {
            chosen = text.trimmingCharacters(in: .whitespaces)
        }
        guard !chosen.isEmpty else { return }   // reject empty; panel stays
        starting = true
        Task {
            await tracking.start(description: chosen, projectId: project?.id, start: startTime)
            starting = false
            // Only dismiss on success. On failure `start` stays .idle and sets
            // lastError, which renders inline above so the user can retry.
            if tracking.lastError == nil { onDone() }
        }
    }
}

/// Confirmation shown when the hotkey is pressed while a timer runs. Enter stops
/// & logs the entry; Escape cancels and leaves it running. Reuses the floating
/// QuickEntryPanel window (see QuickEntryPanel.showStopConfirm).
/// Key-chord matching for StopConfirmView, pulled out as a pure function because
/// SwiftUI's `onKeyPress` closures can't be driven from `swift test` — this way the
/// matching rule is unit tested even though the wiring still needs a live run.
/// Panel sizing for StopConfirmView, pulled out as pure functions for the same
/// reason as StopConfirmKeys: the math is unit tested even though only a live run
/// exercises the real NSPanel.
enum StopConfirmMetrics {
    /// Shown in place of an empty description.
    static let placeholder = "(No description)"

    /// Horizontal inset of the description text — the view's 16pt padding, both sides.
    static let horizontalPadding: CGFloat = 16

    /// Height of everything except the description: elapsed readout, divider, hint
    /// row, VStack spacing and vertical padding. Calibrated against the fixed 120pt
    /// panel this replaced, which fit exactly one line of description.
    static let chromeHeight: CGFloat = 100

    /// Height the panel needs to show `description` in full, capped at `maxHeight`.
    static func panelHeight(
        description: String, width: CGFloat, maxHeight: CGFloat,
        font: NSFont = .preferredFont(forTextStyle: .title3)
    ) -> CGFloat {
        let text = description.isEmpty ? placeholder : description
        let available = max(1, width - horizontalPadding * 2)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return min(chromeHeight + ceil(bounds.height), maxHeight)
    }
}

enum StopConfirmKeys {
    /// ⌘⌫ — discard the running entry. The backspace key reaches SwiftUI as
    /// U+007F (delete) or U+0008 (backspace) depending on the event source, so
    /// both are accepted. Other modifiers alongside ⌘ are tolerated.
    static func isDiscardChord(character: Character, modifiers: EventModifiers) -> Bool {
        guard modifiers.contains(.command) else { return false }
        return character == "\u{7F}" || character == "\u{8}"
    }
}

struct StopConfirmView: View {
    @Bindable var tracking: TrackingStore
    let onDone: () -> Void

    /// Non-nil while a stop or discard request is in flight; blocks re-entry and
    /// disables the other action so the two can't race.
    @State private var busy: Action?
    @FocusState private var focused: Bool

    private enum Action { case stop, discard }

    private var running: (desc: String, start: Date)? {
        if case .running(_, let start, let desc, _) = tracking.state { return (desc, start) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = running {
                // Wraps over as many lines as it needs — the panel is sized to
                // fit (QuickEntryPanel.showStopConfirm), so nothing gets clipped.
                Text(r.desc.isEmpty ? StopConfirmMetrics.placeholder : r.desc)
                    .font(.title3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // TimelineView keeps the elapsed readout live while the panel is open.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed(since: r.start))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if let err = tracking.lastError {
                Text(err).font(.caption).foregroundStyle(.red)   // inline retry surface
            }
            Divider()
            Text("Press ↩ to stop and log · ⌘⌫ to discard · esc to cancel")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focused($focused)
        .task { focused = true }
        .onKeyPress(.return) { run(.stop); return .handled }
        // ⌘⌫ deletes the running entry outright — same as the menu bar's
        // "Discard timer". Matched through the general handler because
        // `.onKeyPress(.delete)` only fires for an unmodified press, and the
        // backspace key arrives as U+0008 or U+007F depending on the source.
        .onKeyPress(phases: .down) { press in
            guard StopConfirmKeys.isDiscardChord(
                character: press.key.character, modifiers: press.modifiers)
            else { return .ignored }
            run(.discard)
            return .handled
        }
        .onKeyPress(.escape) {
            guard busy == nil else { return .handled }
            onDone(); return .handled
        }
    }

    private func run(_ action: Action) {
        guard busy == nil else { return }
        busy = action
        Task {
            switch action {
            case .stop: await tracking.stop()
            case .discard: await tracking.discard()
            }
            busy = nil
            // Only dismiss on success; on failure the store stays .running and
            // sets lastError, rendered inline above so the user can retry.
            if tracking.lastError == nil { onDone() }
        }
    }

    private func elapsed(since start: Date) -> String {
        let t = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", t/3600, (t%3600)/60, t%60)
    }
}
