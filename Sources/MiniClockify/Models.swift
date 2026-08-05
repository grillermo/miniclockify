import Foundation

struct ClockifyUser: Codable, Equatable {
    let id: String
    let defaultWorkspace: String
}

struct Project: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let color: String?
}

struct TimeEntry: Decodable, Equatable, Identifiable {
    let id: String
    let description: String
    let projectId: String?
    let start: Date?
    let end: Date?

    enum CodingKeys: String, CodingKey { case id, description, projectId, timeInterval }
    private struct Interval: Codable { let start: Date?; let end: Date? }

    init(id: String, description: String, projectId: String?, start: Date?, end: Date?) {
        self.id = id; self.description = description; self.projectId = projectId
        self.start = start; self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        projectId = try? c.decode(String.self, forKey: .projectId)
        let iv = try? c.decode(Interval.self, forKey: .timeInterval)
        start = iv?.start; end = iv?.end
    }
}

enum ClockifyError: Error, Equatable {
    case unauthorized
    case network
    case decoding
    case server(Int)
}

/// Abstraction so stores can be tested with a stub instead of the live client.
/// `Sendable` so `@MainActor` stores can hold it under Swift strict concurrency.
protocol ClockifyAPI: Sendable {
    func currentUser() async throws -> ClockifyUser
    func projects(workspaceId: String) async throws -> [Project]
    func recentTimeEntries(workspaceId: String, userId: String) async throws -> [TimeEntry]
    func startEntry(workspaceId: String, description: String, projectId: String?, start: Date) async throws -> TimeEntry
    /// Stops the user's currently-running timer. Clockify's stop endpoint is
    /// PATCH /workspaces/{wid}/user/{uid}/time-entries with body {"end": ...};
    /// it needs only the end time (no entryId / no resend of start).
    func stopRunning(workspaceId: String, userId: String, end: Date) async throws -> TimeEntry
    func deleteEntry(workspaceId: String, entryId: String) async throws
}
