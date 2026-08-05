import XCTest
@testable import MiniClockify

/// Configurable stub for ClockifyAPI used across store tests.
final class StubAPI: ClockifyAPI, @unchecked Sendable {
    var user = ClockifyUser(id: "u1", defaultWorkspace: "w1")
    var projectsList: [Project] = []
    var recent: [TimeEntry] = []
    var userError: Error?
    var startResult: TimeEntry?
    var startError: Error?
    var stopError: Error?
    var deleted: [String] = []
    private(set) var startCalls = 0

    func currentUser() async throws -> ClockifyUser {
        if let e = userError { throw e }; return user
    }
    func projects(workspaceId: String) async throws -> [Project] { projectsList }
    func recentTimeEntries(workspaceId: String, userId: String) async throws -> [TimeEntry] { recent }
    func startEntry(workspaceId: String, description: String, projectId: String?, start: Date) async throws -> TimeEntry {
        startCalls += 1
        if let e = startError { throw e }
        return startResult ?? TimeEntry(id: "new", description: description, projectId: projectId, start: start, end: nil)
    }
    func stopRunning(workspaceId: String, userId: String, end: Date) async throws -> TimeEntry {
        if let e = stopError { throw e }
        return TimeEntry(id: "stopped", description: "", projectId: nil, start: nil, end: end)
    }
    func deleteEntry(workspaceId: String, entryId: String) async throws { deleted.append(entryId) }
}

@MainActor
final class AuthManagerTests: XCTestCase {
    // Isolated keychain so tests never touch the production login-keychain item
    // that Task 12's manual verification relies on.
    let keychain = KeychainStore(service: "com.datacenters.miniclockify.authtest")
    override func setUp() { keychain.delete() }
    override func tearDown() { keychain.delete() }

    func testValidKeyBecomesAuthenticated() async {
        let stub = StubAPI()
        let auth = AuthManager(keychain: keychain, makeClient: { _ in stub })
        await auth.submit(key: "good")
        if case .authenticated(let user) = auth.state { XCTAssertEqual(user.id, "u1") }
        else { XCTFail("expected authenticated, got \(auth.state)") }
    }

    func testUnauthorizedKeepsNeedsAuth() async {
        let stub = StubAPI(); stub.userError = ClockifyError.unauthorized
        let auth = AuthManager(keychain: keychain, makeClient: { _ in stub })
        await auth.submit(key: "bad")
        if case .needsAuth(let msg) = auth.state { XCTAssertNotNil(msg) }
        else { XCTFail("expected needsAuth") }
    }

    // Regression: a server-side error must not be reported as a connection
    // problem, since that sends users down the wrong troubleshooting path.
    func testServerErrorDoesNotClaimConnectionProblem() async {
        let stub = StubAPI(); stub.userError = ClockifyError.server(500)
        let auth = AuthManager(keychain: keychain, makeClient: { _ in stub })
        await auth.submit(key: "irrelevant")
        if case .needsAuth(let msg) = auth.state {
            XCTAssertNotNil(msg)
            XCTAssertFalse(msg!.contains("connection"), "expected a server-error message, got: \(msg!)")
        } else { XCTFail("expected needsAuth") }
    }
}

@MainActor
final class ProjectResolutionTests: XCTestCase {
    func makeStore(_ stub: StubAPI) -> TrackingStore {
        let d = UserDefaults(suiteName: "resolve-\(UUID().uuidString)")!
        return TrackingStore(api: stub, workspaceId: "w1", userId: "u1", defaults: d)
    }

    func testTier1ValidLastUsed() {
        let stub = StubAPI()
        stub.projectsList = [Project(id: "p1", name: "A", color: nil),
                             Project(id: "p2", name: "B", color: nil)]
        let s = makeStore(stub); s.setProjects(stub.projectsList)
        s.lastUsedProjectId = "p2"
        XCTAssertEqual(s.resolveDefaultProject()?.id, "p2")
    }

    func testTier1StaleFallsThrough() {
        let stub = StubAPI()
        stub.projectsList = [Project(id: "p1", name: "A", color: nil)]
        let s = makeStore(stub); s.setProjects(stub.projectsList)
        s.lastUsedProjectId = "gone"
        s.recentProjectId = nil
        XCTAssertEqual(s.resolveDefaultProject()?.id, "p1")   // tier 3
    }

    func testTier2MostRecentEntryProject() {
        let stub = StubAPI()
        stub.projectsList = [Project(id: "p1", name: "A", color: nil),
                             Project(id: "p2", name: "B", color: nil)]
        let s = makeStore(stub); s.setProjects(stub.projectsList)
        s.lastUsedProjectId = nil
        s.recentProjectId = "p2"
        XCTAssertEqual(s.resolveDefaultProject()?.id, "p2")
    }

    func testTier4NoProjectsReturnsNil() {
        let stub = StubAPI()
        let s = makeStore(stub); s.setProjects([])
        s.lastUsedProjectId = nil; s.recentProjectId = nil
        XCTAssertNil(s.resolveDefaultProject())
    }

    func testTier1BeatsTier2WhenBothSet() {
        let stub = StubAPI()
        stub.projectsList = [Project(id: "p1", name: "A", color: nil),
                             Project(id: "p2", name: "B", color: nil)]
        let s = makeStore(stub); s.setProjects(stub.projectsList)
        s.lastUsedProjectId = "p1"   // tier 1
        s.recentProjectId = "p2"     // tier 2 present but must lose
        XCTAssertEqual(s.resolveDefaultProject()?.id, "p1")
    }

    func testStaleTier2FallsThroughToTier3() {
        let stub = StubAPI()
        stub.projectsList = [Project(id: "p1", name: "A", color: nil)]
        let s = makeStore(stub); s.setProjects(stub.projectsList)
        s.lastUsedProjectId = nil
        s.recentProjectId = "gone"   // stale: not in projects list
        XCTAssertEqual(s.resolveDefaultProject()?.id, "p1")   // tier 3
    }
}

@MainActor
final class TrackingTransitionTests: XCTestCase {
    func makeStore(_ stub: StubAPI) -> TrackingStore {
        let d = UserDefaults(suiteName: "trans-\(UUID().uuidString)")!
        return TrackingStore(api: stub, workspaceId: "w1", userId: "u1", defaults: d)
    }

    func testToggleIdleRequestsQuickEntry() async {
        let s = makeStore(StubAPI())
        await s.toggle()
        XCTAssertEqual(s.pendingIntent, .requestQuickEntry)
    }

    func testStartMovesToRunningAndPersistsProject() async {
        let stub = StubAPI()
        stub.startResult = TimeEntry(id: "e9", description: "work", projectId: "p2",
                                     start: Date(timeIntervalSince1970: 10), end: nil)
        let s = makeStore(stub)
        await s.start(description: "work", projectId: "p2")
        if case .running(let id, _, let desc, let pid) = s.state {
            XCTAssertEqual(id, "e9"); XCTAssertEqual(desc, "work"); XCTAssertEqual(pid, "p2")
        } else { XCTFail("expected running") }
        XCTAssertEqual(s.lastUsedProjectId, "p2")
    }

    func testToggleWhileRunningRequestsStopConfirm() async {
        let stub = StubAPI()
        stub.startResult = TimeEntry(id: "e9", description: "w", projectId: nil,
                                     start: Date(timeIntervalSince1970: 10), end: nil)
        let s = makeStore(stub)
        await s.start(description: "w", projectId: nil)
        await s.toggle()   // running -> ask for confirmation, stay running
        XCTAssertEqual(s.pendingIntent, .requestStopConfirm)
        guard case .running = s.state else { return XCTFail("expected still running") }
    }

    func testDiscardDeletesAndGoesIdle() async {
        let stub = StubAPI()
        stub.startResult = TimeEntry(id: "e9", description: "w", projectId: nil,
                                     start: Date(timeIntervalSince1970: 10), end: nil)
        let s = makeStore(stub)
        await s.start(description: "w", projectId: nil)
        await s.discard()
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(stub.deleted, ["e9"])
    }

    func testReconcileAdoptsRunningEntry() async {
        let stub = StubAPI()
        stub.recent = [TimeEntry(id: "open", description: "ongoing", projectId: "p1",
                                 start: Date(timeIntervalSince1970: 5), end: nil),
                       TimeEntry(id: "done", description: "x", projectId: nil,
                                 start: Date(timeIntervalSince1970: 1),
                                 end: Date(timeIntervalSince1970: 2))]
        let s = makeStore(stub)
        await s.reconcile()
        if case .running(let id, _, _, _) = s.state { XCTAssertEqual(id, "open") }
        else { XCTFail("expected adopted running entry") }
    }

    func testStartWithExplicitPastDateUsesThatStart() async {
        let stub = StubAPI()   // echoes the start arg back in its TimeEntry
        let past = Date(timeIntervalSince1970: 1000)
        let s = makeStore(stub)
        await s.start(description: "w", projectId: nil, start: past)
        if case .running(_, let start, _, _) = s.state {
            XCTAssertEqual(start, past)
        } else { XCTFail("expected running") }
    }

    func testStartFailureKeepsIdleAndSurfacesError() async {
        let stub = StubAPI(); stub.startError = ClockifyError.network
        let s = makeStore(stub)
        await s.start(description: "w", projectId: nil)
        XCTAssertEqual(s.state, .idle)
        XCTAssertNotNil(s.lastError)
    }
}
