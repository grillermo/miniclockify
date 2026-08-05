import Foundation
import Observation

// @MainActor for the same reason as AuthManager (see its header comment).
@MainActor
@Observable
final class TrackingStore {
    enum State: Equatable {
        case idle
        case running(entryId: String, start: Date, description: String, projectId: String?)
    }
    enum Intent: Equatable { case requestQuickEntry, requestStopConfirm }

    private(set) var state: State = .idle
    var pendingIntent: Intent?          // observed by app layer
    private(set) var projects: [Project] = []
    var recentProjectId: String?        // project of most recent entry (tier 2)

    private let api: ClockifyAPI
    let workspaceId: String
    let userId: String
    private let defaults: UserDefaults
    private let lastUsedKey = "lastUsedProjectId"

    var lastUsedProjectId: String? {
        get { defaults.string(forKey: lastUsedKey) }
        set { defaults.setValue(newValue, forKey: lastUsedKey) }
    }

    init(api: ClockifyAPI, workspaceId: String, userId: String,
         defaults: UserDefaults = .standard) {
        self.api = api; self.workspaceId = workspaceId
        self.userId = userId; self.defaults = defaults
    }

    func setProjects(_ p: [Project]) { projects = p }

    /// 4-tier fallback (see spec §5).
    func resolveDefaultProject() -> Project? {
        if let id = lastUsedProjectId, let p = projects.first(where: { $0.id == id }) { return p }
        if let id = recentProjectId, let p = projects.first(where: { $0.id == id }) { return p }
        return projects.first
    }

    var lastError: String?

    func toggle() async {
        switch state {
        case .idle: pendingIntent = .requestQuickEntry
        // Running no longer stops immediately: the hotkey opens a confirm panel
        // (Enter = stop & log). The menu Stop button still calls stop() directly.
        case .running: pendingIntent = .requestStopConfirm
        }
    }

    func clearIntent() { pendingIntent = nil }

    func start(description: String, projectId: String?, start: Date = Date()) async {
        do {
            let entry = try await api.startEntry(
                workspaceId: workspaceId, description: description,
                projectId: projectId, start: start)
            lastUsedProjectId = projectId
            state = .running(entryId: entry.id, start: entry.start ?? Date(),
                             description: entry.description, projectId: entry.projectId)
            lastError = nil
        } catch {
            lastError = message(for: error)
        }
    }

    func stop() async {
        guard case .running = state else { return }
        do {
            _ = try await api.stopRunning(workspaceId: workspaceId, userId: userId, end: Date())
            state = .idle; lastError = nil
        } catch {
            lastError = message(for: error)   // stay running, allow retry
        }
    }

    func discard() async {
        guard case .running(let id, _, _, _) = state else { return }
        do {
            try await api.deleteEntry(workspaceId: workspaceId, entryId: id)
            state = .idle; lastError = nil
        } catch {
            lastError = message(for: error)
        }
    }

    /// Adopt an already-running server entry + seed tier-2 recentProjectId.
    func reconcile() async {
        guard let entries = try? await api.recentTimeEntries(
                workspaceId: workspaceId, userId: userId) else { return }
        recentProjectId = entries.first(where: { $0.projectId != nil })?.projectId
        if let open = entries.first(where: { $0.end == nil }) {
            state = .running(entryId: open.id, start: open.start ?? Date(),
                             description: open.description, projectId: open.projectId)
        }
    }

    private func message(for error: Error) -> String {
        switch error as? ClockifyError {
        case .unauthorized: return "Authentication expired."
        case .server(let c): return "Clockify error (\(c))."
        default: return "Could not reach Clockify."
        }
    }
}
