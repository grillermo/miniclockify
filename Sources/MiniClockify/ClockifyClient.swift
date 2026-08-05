import Foundation

// @unchecked Sendable: all stored properties are immutable; the JSONDecoder/
// Encoder are configured once at init and never mutated after.
final class ClockifyClient: ClockifyAPI, @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let base = URL(string: "https://api.clockify.me/api/v1")!

    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    /// Percent-encodes a dynamic ID (workspaceId/userId/entryId) so it's safe
    /// to interpolate into a URL path segment.
    private func encodedID(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// `path` may include a query string (e.g. "…/projects?page-size=200").
    /// We must NOT use appendingPathComponent — it percent-encodes "?" into
    /// "%3F", producing a malformed URL. Build the full string instead.
    /// Dynamic ID segments must already be percent-encoded by the caller via
    /// `encodedID` before being interpolated into `path`.
    private func request(_ path: String, method: String = "GET",
                         body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: base.absoluteString + "/" + path) else {
            throw ClockifyError.network
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return r
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let data = try await perform(req)
        do { return try decoder.decode(T.self, from: data) }
        catch {
            #if DEBUG
            print("ClockifyClient decoding error: \(error)")
            #endif
            throw ClockifyError.decoding
        }
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw ClockifyError.network }
        guard let http = resp as? HTTPURLResponse else { throw ClockifyError.network }
        switch http.statusCode {
        case 200...299: return data
        case 401: throw ClockifyError.unauthorized
        default: throw ClockifyError.server(http.statusCode)
        }
    }

    func currentUser() async throws -> ClockifyUser {
        try await send(request("user"), as: ClockifyUser.self)
    }

    func projects(workspaceId: String) async throws -> [Project] {
        try await send(request("workspaces/\(encodedID(workspaceId))/projects?page-size=200"),
                       as: [Project].self)
    }

    func recentTimeEntries(workspaceId: String, userId: String) async throws -> [TimeEntry] {
        try await send(
            request("workspaces/\(encodedID(workspaceId))/user/\(encodedID(userId))/time-entries?page-size=50"),
            as: [TimeEntry].self)
    }

    func startEntry(workspaceId: String, description: String,
                    projectId: String?, start: Date) async throws -> TimeEntry {
        struct Body: Encodable { let start: Date; let description: String; let projectId: String? }
        let body = try encoder.encode(Body(start: start, description: description, projectId: projectId))
        return try await send(request("workspaces/\(encodedID(workspaceId))/time-entries",
                                      method: "POST", body: body), as: TimeEntry.self)
    }

    func stopRunning(workspaceId: String, userId: String, end: Date) async throws -> TimeEntry {
        struct Body: Encodable { let end: Date }
        let body = try encoder.encode(Body(end: end))
        return try await send(request("workspaces/\(encodedID(workspaceId))/user/\(encodedID(userId))/time-entries",
                                      method: "PATCH", body: body), as: TimeEntry.self)
    }

    func deleteEntry(workspaceId: String, entryId: String) async throws {
        _ = try await perform(request("workspaces/\(encodedID(workspaceId))/time-entries/\(encodedID(entryId))",
                                      method: "DELETE"))
    }
}
