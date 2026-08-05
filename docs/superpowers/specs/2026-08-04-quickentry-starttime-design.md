# Quick-Entry Start-Time Editing — Design

**Goal:** Let the user adjust the start time of a new time entry directly in the quick-entry panel (opened by the global hotkey), instead of always starting "now."

**Context:** Builds on the existing Clockify menu bar app (`docs/superpowers/plans/2026-08-04-clockify-menubar.md`). The quick-entry panel (`QuickEntryPanel.swift` → `QuickEntryView`) only ever appears when `TrackingStore.state == .idle`, so this feature is scoped entirely to starting a new entry — it has no interaction with the running/stop/discard paths.

## UI

Add a native SwiftUI `DatePicker` (`displayedComponents: .hourAndMinute`) next to the description field in `QuickEntryView`, bound to a new `@State private var startTime = Date()`.

- **Default:** Resets to the current time each time the panel opens (matches today's behavior when left untouched).
- **Range:** Constrained via `in: ...Date()` (an open-ended range up to "now"). This is a hard UI constraint — the control itself cannot select a future time, so no separate validation or error state is needed for this.

## Data flow

`TrackingStore.start(description:projectId:)` gains a third parameter:

```swift
func start(description: String, projectId: String?, start: Date = Date()) async
```

The default value preserves every existing call site and test (Task 8's `TrackingTransitionTests` call `start(description:projectId:)` with no third argument). The passed-in `start` replaces the internal `Date()` call when invoking `api.startEntry(workspaceId:description:projectId:start:)`.

`QuickEntryView.start()` passes `startTime` (the bound `@State`) instead of relying on the store's internal default.

## Testing

One new `TrackingStore` test: starting with an explicit past `start` date produces a `.running` state whose `start` matches that date (using the existing `StubAPI`, which already echoes the `start` argument back in its constructed `TimeEntry` when `startResult` isn't overridden).

No new tests for `QuickEntryView` itself — per the existing plan's Chunk 3 convention, SwiftUI/AppKit views are verified manually, not unit tested.

## Out of scope

- Editing the start time of an already-running entry.
- Any server-side validation beyond what Clockify's API already does — the UI-level range constraint is a UX nicety, not a security/correctness boundary.
