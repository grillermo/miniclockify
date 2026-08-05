# Clockify Menu Bar App — Design

**Date:** 2026-08-04
**Status:** Approved

## Purpose

A lean macOS menu bar app for fast Clockify time tracking, replacing a broken
existing tool. The core flow: a global hotkey opens a quick-entry panel, you
type or pick a description, hit Enter to start tracking against your last-used
project; the same hotkey stops and logs the entry. No history window — speed
over features.

## Non-Goals (YAGNI)

- No scrollable history / weekly list window (the big list in the reference
  screenshot). Menu bar timer + quick-entry panel only.
- No Clockify Task-entity or Tag management. The dropdown is free-text over
  recent entry **descriptions** only.
- No email/password login. API key only.
- No multi-workspace switcher UI. Use the user's default workspace.
- No `.env` reading. API key is entered by the user and stored in Keychain.

## Target & Stack

- macOS 14 (Sonoma) or later.
- Swift + SwiftUI, `MenuBarExtra` for the menu bar shell.
- Swift Package Manager executable app.
- One external dependency: `sindresorhus/KeyboardShortcuts` (global hotkey
  registration + a ready-made recorder view for the configurable shortcut).
- Runs as a menu-bar-only agent: `LSUIElement` set (no Dock icon, no main
  window). Windows (AuthWindow, Preferences, QuickEntryPanel) are created
  programmatically as needed.
- Keychain access via a hand-rolled minimal wrapper over the `Security`
  framework (no dependency).

## Clockify API

- Base URL: `https://api.clockify.me/api/v1`
- Auth header: `X-Api-Key: <key>` on every request.
- Endpoints used:
  - `GET /user` — fetch current user, `id`, and `defaultWorkspace`.
  - `GET /workspaces/{workspaceId}/projects` — list projects (for name display
    and validating the remembered last-used project still exists).
  - `GET /workspaces/{workspaceId}/user/{userId}/time-entries?page-size=50` —
    recent entries, source for description autocomplete and for detecting an
    already-running entry on launch (an in-progress entry has `timeInterval.end
    == null`).
  - `POST /workspaces/{workspaceId}/time-entries` — start an entry. Body:
    `{ "start": "<ISO8601 UTC>", "description": "<text>", "projectId": "<id>" }`.
    `projectId` is **optional** — Clockify accepts project-less entries (the
    reference screenshot shows "No project yet"). Response includes the new
    entry `id`.
  - `PATCH /workspaces/{workspaceId}/user/{userId}/time-entries` — stop the
    user's currently-running timer. Body: `{ "end": "<now ISO8601>" }`. Verified
    against docs.clockify.me: this endpoint needs only the end time — no entry
    id and no resend of `start`.
  - `DELETE /workspaces/{workspaceId}/time-entries/{id}` — discard.
- All timestamps are ISO 8601 in UTC (e.g. `2026-08-04T10:54:00Z`).

## Components

Each unit has one purpose, a defined interface, and is testable in isolation.

### 1. `ClockifyClient`
- Async/await wrapper around `URLSession`. Injectable `URLSession` (default
  `.shared`) so tests can supply a mocked `URLProtocol`.
- Methods mirror the endpoints above, returning decoded model structs.
- Models: `ClockifyUser { id, defaultWorkspace }`, `Project { id, name, color }`,
  `TimeEntry { id, description, projectId, start, end }` (Codable, mapping
  `timeInterval.start/end`).
- Throws a typed `ClockifyError` (`.unauthorized`, `.network`, `.decoding`,
  `.server(status)`); `.unauthorized` (HTTP 401) is what AuthManager treats as
  an invalid key.
- Depends on: nothing but the API key + URLSession.

### 2. `KeychainStore`
- `save(key:)`, `load() -> String?`, `delete()` for the API key under a fixed
  service/account identifier.
- Thin wrapper over `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`.
- Depends on: `Security` framework only.

### 3. `AuthManager`
- On launch: `KeychainStore.load()`. If a key exists, validate with
  `GET /user`. On success, publish authenticated state + cached user/workspace.
  On missing key or `.unauthorized`, publish `.needsAuth` so the UI shows the
  paste window.
- `submit(key:)` — validate a pasted key, save to Keychain on success, else
  surface an error to the paste window without saving.
- `signOut()` — `KeychainStore.delete()`, return to `.needsAuth`.
- Depends on: `ClockifyClient`, `KeychainStore`.

### 4. `HotkeyManager`
- Registers the configurable shortcut via KeyboardShortcuts under a named
  shortcut. Ships a default binding (e.g. Control-Option-Command-T) applied on
  first run if the user has none set.
- On trigger, calls a single `toggle()` closure wired to `TrackingStore`.
- Depends on: KeyboardShortcuts package.

### 5. `TrackingStore` (`@Observable`)
- State machine: `.idle` or `.running(entryId, start, description, project)`.
- `toggle()`:
  - idle → publishes a `.requestQuickEntry` intent (the app layer observes this
    and presents the panel). The store never touches AppKit/SwiftUI directly,
    keeping it UI-free and unit-testable.
  - running → stop (see `stop()`).
- `start(description:project:)` → `POST` entry → move to `.running`, persist
  `lastUsedProjectId` (or nil) to UserDefaults.
- **Pre-selected project resolution** (`resolveDefaultProject()`), evaluated
  when the panel opens, in order:
  1. `lastUsedProjectId` from UserDefaults, **if** it still exists in the
     fetched projects list (handles the deleted/archived case).
  2. Else the `projectId` of the most recent time-entry that has one (seeds a
     sensible default on first run without any stored preference).
  3. Else the first project in the fetched list (matches the described "first
     project pre-selected" behavior).
  4. Else `nil` → start a project-less entry ("No project yet"). This keeps a
     brand-new account with zero projects fully functional.
- `stop()` → `PATCH` end=now → `.idle`.
- `discard()` → `DELETE` → `.idle`.
- Publishes an elapsed-time string updated on a 1s timer while running, for the
  menu bar label.
- On launch, reconciles with server: if a running entry exists, adopt it into
  `.running` so the menu bar reflects reality.
- Depends on: `ClockifyClient`, UserDefaults.

### 6. `QuickEntryPanel`
- A borderless, floating `NSPanel` (`.nonactivatingPanel` style, hosting a
  SwiftUI view) that centers on the active screen, becomes key, and focuses a
  combobox text field.
- Combobox behavior:
  - Recent descriptions are owned by a `RecentDescriptions` helper: it calls
    `ClockifyClient.recentTimeEntries`, then applies a pure
    `filter(descriptions:query:)` function (dedup case-insensitively,
    most-recent-first order, substring match). The panel's view-model holds this
    helper; the pure filter function is what the autocomplete unit test targets.
  - Type-ahead filters the list by case-insensitive substring match.
  - ↑/↓ move the highlight; Enter starts tracking with the highlighted item, or,
    if none highlighted, the raw typed text (this is how a "new" description is
    created). Empty text is rejected (panel stays open).
  - Esc closes the panel without starting.
- Shows the pre-selected project (from `resolveDefaultProject()`, §5) as a small
  label, or "No project yet" when nil. Not editable in v1 (YAGNI — the
  resolution chain covers first-run and stale-project cases).
- Depends on: `TrackingStore`.

### 7. `AuthWindow` (paste key)
- Simple window: a secure/normal text field, "Save", and a link to where to
  find the key in Clockify profile settings. Shown when `AuthManager` is
  `.needsAuth`. Reports validation errors inline.

### 8. `PreferencesView`
- KeyboardShortcuts recorder for the hotkey.
- "Clear API key / sign out" button → `AuthManager.signOut()`.

### 9. Menu bar (`MenuBarExtra`)
- Label: timer string (e.g. `00:00:45`) when running, an icon when idle.
- Menu items: Stop timer, Discard timer (both only when running),
  Preferences…, Quit. (Reference-style "Continue latest" is out of scope.)

## Data Flow

```
Launch
  └─ AuthManager.load
       ├─ no/invalid key → AuthWindow (paste) ──save──► validate ──► authenticated
       └─ valid key ─────────────────────────────────────────────► authenticated
authenticated
  └─ fetch user + defaultWorkspace + projects (cache)
  └─ TrackingStore.reconcile (adopt running entry if any)
  └─ idle

Hotkey (idle)
  └─ QuickEntryPanel shows → load recent descriptions
       └─ type/select → Enter → TrackingStore.start → POST → running (menu bar ticks)

Hotkey (running)
  └─ TrackingStore.stop → PATCH end=now → idle
```

## Error Handling

- Notification channel: request `UserNotifications` authorization once, lazily,
  the first time an error needs surfacing. If the user grants it, errors show as
  system notifications. If denied (or not yet granted), errors fall back to
  in-app surfaces that need no permission: inline red text in the QuickEntryPanel
  for start failures, and a disabled/red menu item ("⚠️ Last action failed —
  retry") in the menu bar for stop/discard failures. The app never depends on
  notifications being authorized.
- Network/server errors on start/stop: surface via the channel above; for start,
  keep the panel open so the user can retry; for stop, keep state `.running` and
  allow retry via the menu.
- `.unauthorized` at any point: route back to `AuthManager.needsAuth`
  (AuthWindow), preserving any in-memory timer state where possible.
- Decoding errors are logged and surfaced as a generic "unexpected response"
  notification.

## Testing Strategy

- `ClockifyClient`: unit tests using a mocked `URLProtocol` returning canned
  JSON for each endpoint, asserting request URL/headers/body and decoded output,
  plus error mapping (401 → `.unauthorized`, 5xx → `.server`).
- `TrackingStore`: unit tests of the toggle/start/stop/discard state
  transitions, `lastUsedProjectId` persistence, and `resolveDefaultProject()`
  covering all four fallback tiers (valid last-used, stale last-used, most-recent
  entry, first project, and the zero-projects → nil case), with a stubbed client.
- Autocomplete filter: unit test of dedup + substring filtering + ordering.
- `KeychainStore`: integration test guarded to a test service id
  (save/load/delete round trip).
- Panel focus/hotkey registration: manual verification (documented checklist).

## Open Risks

- KeyboardShortcuts default-binding-on-first-run must not clobber a user's later
  custom binding; apply default only when no stored binding exists.
