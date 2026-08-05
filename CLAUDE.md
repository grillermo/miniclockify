# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A lean macOS **menu bar app** for fast Clockify time tracking. Core flow: a
global hotkey (default ⌃⌥⌘⇧C) opens a floating quick-entry panel → type/pick a
description → Enter starts a timer against the last-used project; the same hotkey
opens a stop-confirm panel (Enter = stop & log). No history window — speed over
features. Design lives in `docs/superpowers/specs/2026-08-04-clockify-menubar-design.md`.

SwiftUI + AppKit, Swift 6 with strict concurrency, macOS 14+, no third-party
dependencies.

## Commands

```bash
swift build                          # debug build
swift test                           # run all tests
swift test --filter TrackingStoreTests           # one test class
swift test --filter TrackingStoreTests/testStart # one test method

./build-app.sh [debug|release]       # build .app bundle + ad-hoc codesign (default release)
./build [debug|release]              # kill running app, rebuild bundle, relaunch
```

Ad-hoc codesigning (`build-app.sh`) is required for Keychain access and
notifications to work — running the bare `.build/…/MiniClockify` binary won't have
them.

## Architecture

`AppState` (`MiniClockifyApp.swift`) is the `@MainActor NSApplicationDelegate` that
wires everything together and owns the object graph:

- **AuthManager** — API-key auth state machine (`.needsAuth` / `.authenticated`).
  Loads/validates key from Keychain at launch, holds the live `ClockifyAPI` client.
- **TrackingStore** — timer state machine (`.idle` / `.running`). All timer
  mutations go through it. On failure it keeps state `.running` and sets
  `lastError` so the action can be retried.
- **HotkeyManager** — Carbon global hotkey (`RegisterEventHotKey`), the one part
  that stays Carbon because SwiftUI has no system-wide hotkey API. Persists the
  binding to `UserDefaults`, survives relaunch, rebindable from PreferencesView.
- **QuickEntryPanel** — floating `NSPanel` for the entry and stop-confirm views.
- **ClockifyClient** — the `ClockifyAPI` REST implementation (api.clockify.me/v1,
  `X-Api-Key` header).

### Key patterns

- **Intent indirection**: `TrackingStore.toggle()` does not act directly — it
  sets `pendingIntent` (`.requestQuickEntry` / `.requestStopConfirm`), which the
  app layer (`AppState.handleToggle`) reads to decide which panel to show. This
  keeps the store UI-agnostic and testable.
- **`ClockifyAPI` protocol** (`Models.swift`) abstracts the network so stores are
  tested against a stub, and `ClockifyClient` against `URLProtocolMock` — no
  live network in tests.
- **Everything UI-adjacent is `@MainActor`** to satisfy Swift strict concurrency;
  `ClockifyAPI` is `Sendable` so main-actor stores can hold it. Test classes are
  `@MainActor` to match.
- **`@Observable` (not `ObservableObject`)** for AuthManager/TrackingStore.
  Exception: `AppState` is `ObservableObject` because SwiftUI `Scene`/`MenuBarExtra`
  labels only re-render off `@ObservedObject`, not `@Observable` — see the long
  comments in `MiniClockifyApp.swift` explaining the menu-bar label and Settings-window
  re-render quirks before changing them.
- **Project resolution**: `resolveDefaultProject()` is a tiered fallback
  (lastUsed → recent-from-server → first). `reconcile()` adopts an
  already-running server entry at launch and seeds the recent project.

### Menu-bar / LSUIElement gotchas

The app is `LSUIElement` (`.accessory`, no Dock icon). Accessory apps can't
reliably bring a window to the front, so opening Preferences flips activation
policy to `.regular`, activates, then opens and repositions the Settings window
(SwiftUI creates it asynchronously at zero width — the code retries until it has
real dimensions). `SettingsWindowCloseObserver` restores `.accessory` on the
window's `willCloseNotification` so the temporary Dock icon disappears again —
the app is never meant to keep a Dock icon. Read the comments before touching this.

Esc closes the Settings window (not the app): a hidden `.cancelAction` button in
`PreferencesView` calls `performClose` on the window matched by SwiftUI's private
`com_apple_SwiftUI_Settings_window` identifier. The `HotkeyRecorderCatcher`
swallows keys while recording a combo, so Esc only reaches the button when not
capturing.

## Config

- API key is stored in the Keychain (service `com.datacenters.miniclockify`), not in
  `.env`. The `.env` `CLOCKIFY_API_KEY` is dev/testing convenience only and is
  gitignored.
- Bundle id / `Info.plist` live in `Resources/Info.plist`.


## Development

After EVERY successful change run ./build
And on successful build do a commit with a description of the changes
