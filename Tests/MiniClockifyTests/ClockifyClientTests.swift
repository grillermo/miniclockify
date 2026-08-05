import XCTest
@testable import MiniClockify

final class ModelDecodingTests: XCTestCase {
    func testUserDecodes() throws {
        let json = #"{"id":"u1","defaultWorkspace":"w1"}"#.data(using: .utf8)!
        let user = try JSONDecoder().decode(ClockifyUser.self, from: json)
        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(user.defaultWorkspace, "w1")
    }

    func testProjectDecodes() throws {
        let json = ##"{"id":"p1","name":"Datacenters","color":"#FF0000"}"##.data(using: .utf8)!
        let p = try JSONDecoder().decode(Project.self, from: json)
        XCTAssertEqual(p.id, "p1")
        XCTAssertEqual(p.name, "Datacenters")
    }

    func testTimeEntryMapsTimeInterval() throws {
        let json = #"""
        {"id":"e1","description":"work","projectId":"p1",
         "timeInterval":{"start":"2026-08-04T10:54:00Z","end":null}}
        """#.data(using: .utf8)!
        // Must match the client's ISO-8601 date strategy; a bare JSONDecoder
        // uses .deferredToDate and would leave start nil.
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let e = try dec.decode(TimeEntry.self, from: json)
        XCTAssertEqual(e.id, "e1")
        XCTAssertEqual(e.description, "work")
        XCTAssertEqual(e.projectId, "p1")
        XCTAssertNotNil(e.start)
        XCTAssertNil(e.end)
    }
}

final class ClockifyClientTests: XCTestCase {
    override func tearDown() { URLProtocolMock.handler = nil }

    func makeClient() -> ClockifyClient {
        ClockifyClient(apiKey: "KEY", session: URLProtocolMock.session())
    }

    func testCurrentUserSendsApiKeyHeaderAndDecodes() async throws {
        URLProtocolMock.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Api-Key"), "KEY")
            XCTAssertEqual(req.url?.absoluteString,
                           "https://api.clockify.me/api/v1/user")
            return (200, #"{"id":"u1","defaultWorkspace":"w1"}"#.data(using: .utf8)!)
        }
        let user = try await makeClient().currentUser()
        XCTAssertEqual(user.id, "u1")
    }

    func testProjectsURLKeepsQueryStringUnencoded() async throws {
        URLProtocolMock.handler = { req in
            // Regression guard: "?" must stay literal, not become "%3F".
            XCTAssertEqual(req.url?.absoluteString,
                "https://api.clockify.me/api/v1/workspaces/w1/projects?page-size=200")
            return (200, "[]".data(using: .utf8)!)
        }
        _ = try await makeClient().projects(workspaceId: "w1")
    }

    func testStopRunningPatchesUserEndpoint() async throws {
        URLProtocolMock.handler = { req in
            XCTAssertEqual(req.httpMethod, "PATCH")
            XCTAssertEqual(req.url?.absoluteString,
                "https://api.clockify.me/api/v1/workspaces/w1/user/u1/time-entries")
            return (200, #"{"id":"e1","description":"work","projectId":"p1","timeInterval":{"start":"2026-08-04T10:54:00Z","end":"2026-08-04T11:00:00Z"}}"#.data(using: .utf8)!)
        }
        let e = try await makeClient().stopRunning(
            workspaceId: "w1", userId: "u1", end: Date())
        XCTAssertNotNil(e.end)
    }

    func testStartEntryPostsBody() async throws {
        URLProtocolMock.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            return (201, #"{"id":"e1","description":"work","projectId":"p1","timeInterval":{"start":"2026-08-04T10:54:00Z","end":null}}"#.data(using: .utf8)!)
        }
        let e = try await makeClient().startEntry(
            workspaceId: "w1", description: "work", projectId: "p1",
            start: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(e.id, "e1")
    }

    func test401MapsToUnauthorized() async {
        URLProtocolMock.handler = { _ in (401, Data()) }
        do { _ = try await makeClient().currentUser(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ClockifyError, .unauthorized) }
    }

    func test500MapsToServer() async {
        URLProtocolMock.handler = { _ in (500, Data()) }
        do { _ = try await makeClient().currentUser(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ClockifyError, .server(500)) }
    }
}
