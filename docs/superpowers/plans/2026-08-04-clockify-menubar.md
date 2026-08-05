# Clockify Menu Bar App Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app that starts/stops Clockify time entries via a configurable global hotkey and a fast quick-entry panel.

**Architecture:** SwiftUI `MenuBarExtra` agent app (no Dock icon). A testable core — `ClockifyClient` (REST), `KeychainStore`, `AuthManager`, `TrackingStore`, `RecentDescriptions` — sits behind UI units (`QuickEntryPanel`, `AuthWindow`, `PreferencesView`) wired together in the app entry point. The core talks to Clockify through a `ClockifyAPI` protocol so stores are unit-testable with stubs; the client itself is tested with a mocked `URLProtocol`.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, Swift Package Manager (executable, zero external dependencies), `Carbon.HIToolbox` (`RegisterEventHotKey`) for the global hotkey, `Security` + `UserNotifications` system frameworks. Built with Command Line Tools only (no full Xcode): `swift build`/`swift test` for compilation and tests, plus a `build-app.sh` script that assembles and ad-hoc-signs the `.app` bundle.

> **Amendment (post-Task-1 blocker):** The plan originally depended on `sindresorhus/KeyboardShortcuts`. Every 2.x/3.x release of that package ships unguarded `#Preview` macro blocks in `Recorder.swift`, and `#Preview` requires the `PreviewsMacros` compiler plugin that only ships inside Xcode.app — it cannot compile under Command Line Tools alone (confirmed: no Xcode.app on the build machine, reproduced across all tagged versions ≥1.16.0). Per user decision, the dependency is dropped entirely; the global hotkey is implemented directly against Carbon's `RegisterEventHotKey`/`UnregisterEventHotKey`/`InstallEventHandler` APIs (the same primitives that package wraps), with a hand-rolled recorder view for rebinding. This removes the dependency line from `Package.swift` (Task 1) and changes `HotkeyManager` (Task 10) and the hotkey-recorder part of `PreferencesView` (Task 11) as detailed in those tasks below.

**Spec:** `docs/superpowers/specs/2026-08-04-clockify-menubar-design.md`

---

## Environment Notes (read once)

- Only Xcode Command Line Tools are installed (`swift build`/`swift test` work; `xcodebuild` does not). All build/test commands in this plan use `swift`, never `xcodebuild`.
- The macOS SDK bundled with CLT includes SwiftUI/AppKit, so GUI code compiles. However a `MenuBarExtra` app only *runs* from a `.app` bundle with an `Info.plist` containing `LSUIElement`. Task 12 builds that bundle.
- Keychain + UserNotifications need at least an ad-hoc code signature; `build-app.sh` handles `codesign --sign -` (Task 12).
- All Clockify timestamps are ISO 8601 UTC (e.g. `2026-08-04T10:54:00Z`).

## File Structure

Created under repo root:

```
Package.swift                              # SPM manifest: exe + test targets, KeyboardShortcuts dep
Sources/MiniClockify/
  Models.swift                             # Codable models + ClockifyError + ClockifyAPI protocol
  ClockifyClient.swift                     # URLSession REST client (conforms to ClockifyAPI)
  KeychainStore.swift                      # Security-framework wrapper for the API key
  RecentDescriptions.swift                 # pure filter() + fetch helper for autocomplete
  AuthManager.swift                        # @Observable auth state machine
  TrackingStore.swift                      # @Observable tracking state machine + project resolution
  Notifier.swift                           # error surfacing (UserNotifications + fallbacks)
  HotkeyManager.swift                      # KeyboardShortcuts registration + toggle wiring
  QuickEntryPanel.swift                    # NSPanel host + SwiftUI combobox view
  AuthWindow.swift                         # paste-API-key window/view
  PreferencesView.swift                    # hotkey recorder + sign out
  MiniClockifyApp.swift                        # @main MenuBarExtra, wires everything
Tests/MiniClockifyTests/
  URLProtocolMock.swift                    # test helper: canned responses
  ClockifyClientTests.swift
  RecentDescriptionsTests.swift
  TrackingStoreTests.swift
  KeychainStoreTests.swift
Resources/Info.plist                       # LSUIElement etc. (used by build-app.sh)
build-app.sh                               # assemble + ad-hoc sign MiniClockify.app
```

Each file has one responsibility; stores never import AppKit/SwiftUI (they publish state/intents the app layer observes).

---

## Chunk 1: Scaffold + Models + REST Client

### Task 1: SPM scaffold that builds and tests

**Files:**
- Create: `Package.swift`
- Create: `Sources/MiniClockify/MiniClockifyApp.swift` (temporary placeholder `main`)
- Create: `Tests/MiniClockifyTests/SmokeTest.swift`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniClockify",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiniClockify",
            path: "Sources/MiniClockify"
        ),
        .testTarget(
            name: "MiniClockifyTests",
            dependencies: ["MiniClockify"],
            path: "Tests/MiniClockifyTests"
        )
    ]
)
```

> No external dependencies (amendment above) — `swift build` needs no network fetch.

- [ ] **Step 2: Write a temporary placeholder entry point**

`Sources/MiniClockify/MiniClockifyApp.swift`:
```swift
// Temporary placeholder; replaced by the real @main app in Task 11.
// NOTE: top-level statements (e.g. `print(...)`) are only allowed in a file
// literally named `main.swift`, so use an @main type here instead.
@main
struct Placeholder {
    static func main() {}
}
```

- [ ] **Step 3: Write the smoke test**

`Tests/MiniClockifyTests/SmokeTest.swift`:
```swift
import XCTest
@testable import MiniClockify

final class SmokeTest: XCTestCase {
    func testTrue() { XCTAssertTrue(true) }
}
```

- [ ] **Step 4: Resolve deps and build**

Run: `swift build`
Expected: PASS — "Compiling" then "Build complete".

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: PASS — 1 test passes.

- [ ] **Step 6: Add a `.gitignore` and commit**

Create `.gitignore`:
```
.build/
*.xcodeproj
MiniClockify.app/
```

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "chore: SPM scaffold for Clockify menu bar app"
```

---

### Task 2: Models + error type + API protocol

**Files:**
- Create: `Sources/MiniClockify/Models.swift`
- Test: `Tests/MiniClockifyTests/ClockifyClientTests.swift` (decoding tests added here first)

- [ ] **Step 1: Write failing decoding tests**

`Tests/MiniClockifyTests/ClockifyClientTests.swift`:
```swift
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
        let json = #"{"id":"p1","name":"Datacenters","color":"#FF0000"}"#.data(using: .utf8)!
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ModelDecodingTests`
Expected: FAIL — "cannot find 'ClockifyUser' in scope".

- [ ] **Step 3: Implement `Models.swift`**

```swift
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

struct TimeEntry: Codable, Equatable, Identifiable {
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
```

Note: the shared JSON decoder uses `.iso8601` date decoding — the client owns
that (Task 3). The Step-1 test already configures a matching decoder.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ModelDecodingTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MiniClockify/Models.swift Tests/MiniClockifyTests/ClockifyClientTests.swift
git commit -m "feat: Clockify models, error type, and API protocol"
```

---

### Task 3: `ClockifyClient` with mocked URLProtocol

**Files:**
- Create: `Sources/MiniClockify/ClockifyClient.swift`
- Create: `Tests/MiniClockifyTests/URLProtocolMock.swift`
- Modify: `Tests/MiniClockifyTests/ClockifyClientTests.swift`

- [ ] **Step 1: Write the URLProtocol mock helper**

`Tests/MiniClockifyTests/URLProtocolMock.swift`:
```swift
import Foundation

final class URLProtocolMock: URLProtocol {
    /// Set before each test: given a request, return (status, body) or throw.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("no handler set") }
        do {
            let (status, data) = try handler(request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [URLProtocolMock.self]
        return URLSession(configuration: cfg)
    }
}
```

- [ ] **Step 2: Write failing client tests**

Append to `ClockifyClientTests.swift`:
```swift
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
```

Note: `URLProtocolMock` can't read the POST body directly (URLSession strips `httpBody` for custom protocols; it moves to `httpBodyStream`). Assert method/URL here; body construction is covered indirectly by the start/stop integration in Task 8. Do NOT assert on `req.httpBody`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ClockifyClientTests`
Expected: FAIL — "cannot find 'ClockifyClient' in scope".

- [ ] **Step 4: Implement `ClockifyClient.swift`**

```swift
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

    /// `path` may include a query string (e.g. "…/projects?page-size=200").
    /// We must NOT use appendingPathComponent — it percent-encodes "?" into
    /// "%3F", producing a malformed URL. Build the full string instead.
    private func request(_ path: String, method: String = "GET",
                         body: Data? = nil) -> URLRequest {
        let url = URL(string: base.absoluteString + "/" + path)!
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return r
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await perform(req)
        _ = resp
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ClockifyError.decoding }
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw ClockifyError.network }
        guard let http = resp as? HTTPURLResponse else { throw ClockifyError.network }
        switch http.statusCode {
        case 200...299: return (data, http)
        case 401: throw ClockifyError.unauthorized
        default: throw ClockifyError.server(http.statusCode)
        }
    }

    func currentUser() async throws -> ClockifyUser {
        try await send(request("user"), as: ClockifyUser.self)
    }

    func projects(workspaceId: String) async throws -> [Project] {
        try await send(request("workspaces/\(workspaceId)/projects?page-size=200"),
                       as: [Project].self)
    }

    func recentTimeEntries(workspaceId: String, userId: String) async throws -> [TimeEntry] {
        try await send(
            request("workspaces/\(workspaceId)/user/\(userId)/time-entries?page-size=50"),
            as: [TimeEntry].self)
    }

    func startEntry(workspaceId: String, description: String,
                    projectId: String?, start: Date) async throws -> TimeEntry {
        struct Body: Encodable { let start: Date; let description: String; let projectId: String? }
        let body = try encoder.encode(Body(start: start, description: description, projectId: projectId))
        return try await send(request("workspaces/\(workspaceId)/time-entries",
                                      method: "POST", body: body), as: TimeEntry.self)
    }

    func stopRunning(workspaceId: String, userId: String, end: Date) async throws -> TimeEntry {
        struct Body: Encodable { let end: Date }
        let body = try encoder.encode(Body(end: end))
        return try await send(request("workspaces/\(workspaceId)/user/\(userId)/time-entries",
                                      method: "PATCH", body: body), as: TimeEntry.self)
    }

    func deleteEntry(workspaceId: String, entryId: String) async throws {
        _ = try await perform(request("workspaces/\(workspaceId)/time-entries/\(entryId)",
                                      method: "DELETE"))
    }
}
```

Note on stop (verified against docs.clockify.me): the stop endpoint is
**`PATCH /workspaces/{wid}/user/{uid}/time-entries`** with body `{"end": ...}`.
It stops whatever timer is currently running for that user — no entry id and no
resend of `start` needed. This supersedes the spec's earlier PATCH-to-entry-id
description and removes the "resend start / clobber fields" risk entirely.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ClockifyClientTests`
Expected: PASS — 6 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/MiniClockify/ClockifyClient.swift Tests/MiniClockifyTests/URLProtocolMock.swift Tests/MiniClockifyTests/ClockifyClientTests.swift
git commit -m "feat: Clockify REST client with mocked-URLProtocol tests"
```

---

## Chunk 2: Keychain, Recent Descriptions, Auth + Tracking Stores

### Task 4: `KeychainStore`

**Files:**
- Create: `Sources/MiniClockify/KeychainStore.swift`
- Test: `Tests/MiniClockifyTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write failing round-trip test**

```swift
import XCTest
@testable import MiniClockify

final class KeychainStoreTests: XCTestCase {
    let store = KeychainStore(service: "com.datacenters.miniclockify.test")
    override func setUp() { store.delete() }
    override func tearDown() { store.delete() }

    func testSaveLoadDelete() {
        XCTAssertNil(store.load())
        store.save("abc123")
        XCTAssertEqual(store.load(), "abc123")
        store.save("def456")            // overwrite
        XCTAssertEqual(store.load(), "def456")
        store.delete()
        XCTAssertNil(store.load())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeychainStoreTests`
Expected: FAIL — "cannot find 'KeychainStore' in scope".

- [ ] **Step 3: Implement `KeychainStore.swift`**

```swift
import Foundation
import Security

final class KeychainStore {
    private let service: String
    private let account = "api-key"

    init(service: String = "com.datacenters.miniclockify") { self.service = service }

    func save(_ value: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KeychainStoreTests`
Expected: PASS. If the unsigned test binary can't reach the keychain
(`save` then `load` returns nil, e.g. `errSecMissingEntitlement`), guard the
test body with a skip instead of asserting:
```swift
store.save("abc123")
try XCTSkipIf(store.load() == nil, "Keychain requires a signed bundle")
```
placed right after the first `save`, then rely on Task 12's manual verification.
Try unsigned first — it usually works from the login keychain.

- [ ] **Step 5: Commit**

```bash
git add Sources/MiniClockify/KeychainStore.swift Tests/MiniClockifyTests/KeychainStoreTests.swift
git commit -m "feat: Keychain wrapper for API key storage"
```

---

### Task 5: `RecentDescriptions` pure filter

**Files:**
- Create: `Sources/MiniClockify/RecentDescriptions.swift`
- Test: `Tests/MiniClockifyTests/RecentDescriptionsTests.swift`

- [ ] **Step 1: Write failing filter tests**

```swift
import XCTest
@testable import MiniClockify

final class RecentDescriptionsTests: XCTestCase {
    func testDedupKeepsMostRecentFirst() {
        let input = ["fix bug", "write docs", "fix bug", "deploy"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: ""),
                       ["fix bug", "write docs", "deploy"])
    }

    func testDedupIsCaseInsensitiveKeepingFirstCasing() {
        let input = ["Fix Bug", "fix bug", "deploy"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: ""),
                       ["Fix Bug", "deploy"])
    }

    func testSubstringCaseInsensitive() {
        let input = ["Fix Bug", "write docs", "DEPLOY"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: "o"),
                       ["write docs", "DEPLOY"])
    }

    func testEmptyDescriptionsDropped() {
        let input = ["", "  ", "real"]
        XCTAssertEqual(RecentDescriptions.filter(descriptions: input, query: ""), ["real"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RecentDescriptionsTests`
Expected: FAIL — "cannot find 'RecentDescriptions'".

- [ ] **Step 3: Implement `RecentDescriptions.swift`**

```swift
import Foundation

enum RecentDescriptions {
    /// Pure: dedup case-insensitively (first occurrence wins, original casing
    /// kept), drop blank, filter by case-insensitive substring. Matches spec §6.
    static func filter(descriptions: [String], query: String) -> [String] {
        var seen = Set<String>()      // lowercased keys
        var result: [String] = []
        for d in descriptions {
            let trimmed = d.trimmingCharacters(in: .whitespaces)
            let key = d.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(d)
        }
        guard !query.isEmpty else { return result }
        return result.filter { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    /// Fetch recent entry descriptions, most-recent-first, via the API.
    static func fetch(api: ClockifyAPI, workspaceId: String, userId: String) async -> [String] {
        let entries = (try? await api.recentTimeEntries(workspaceId: workspaceId, userId: userId)) ?? []
        return entries.map(\.description)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RecentDescriptionsTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MiniClockify/RecentDescriptions.swift Tests/MiniClockifyTests/RecentDescriptionsTests.swift
git commit -m "feat: recent-descriptions dedup/filter for autocomplete"
```

---

### Task 6: `AuthManager`

**Files:**
- Create: `Sources/MiniClockify/AuthManager.swift`
- Test: `Tests/MiniClockifyTests/TrackingStoreTests.swift` (shared stub lives here; AuthManager tests added)

- [ ] **Step 1: Write the shared API stub + failing AuthManager tests**

`Tests/MiniClockifyTests/TrackingStoreTests.swift`:
```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AuthManagerTests`
Expected: FAIL — "cannot find 'AuthManager'".

- [ ] **Step 3: Implement `AuthManager.swift`**

```swift
import Foundation
import Observation

// @MainActor: consumed from the @MainActor AppState (Chunk 3) and mutates
// observable UI state; keeping it main-isolated avoids Swift strict-concurrency
// data-race diagnostics. Store test classes are annotated @MainActor to match.
@MainActor
@Observable
final class AuthManager {
    enum State: Equatable {
        case needsAuth(String?)          // optional error message
        case authenticated(ClockifyUser)
    }

    private(set) var state: State = .needsAuth(nil)
    private(set) var client: ClockifyAPI?

    private let keychain: KeychainStore
    private let makeClient: @Sendable (String) -> ClockifyAPI

    init(keychain: KeychainStore = KeychainStore(),
         makeClient: @escaping @Sendable (String) -> ClockifyAPI = { ClockifyClient(apiKey: $0) }) {
        self.keychain = keychain
        self.makeClient = makeClient
    }

    /// Called at launch. Validates any stored key.
    func bootstrap() async {
        guard let key = keychain.load() else { state = .needsAuth(nil); return }
        await validate(key: key, saveOnSuccess: false)
    }

    func submit(key: String) async {
        await validate(key: key, saveOnSuccess: true)
    }

    private func validate(key: String, saveOnSuccess: Bool) async {
        let client = makeClient(key)
        do {
            let user = try await client.currentUser()
            if saveOnSuccess { keychain.save(key) }
            self.client = client
            state = .authenticated(user)
        } catch ClockifyError.unauthorized {
            state = .needsAuth("Invalid API key.")
        } catch {
            state = .needsAuth("Could not reach Clockify. Check your connection.")
        }
    }

    func signOut() {
        keychain.delete()
        client = nil
        state = .needsAuth(nil)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AuthManagerTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MiniClockify/AuthManager.swift Tests/MiniClockifyTests/TrackingStoreTests.swift
git commit -m "feat: AuthManager state machine with key validation"
```

---

### Task 7: `TrackingStore` — project resolution

**Files:**
- Create: `Sources/MiniClockify/TrackingStore.swift`
- Modify: `Tests/MiniClockifyTests/TrackingStoreTests.swift`

- [ ] **Step 1: Write failing resolution tests**

Append to `TrackingStoreTests.swift`:
```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectResolutionTests`
Expected: FAIL — "cannot find 'TrackingStore'".

- [ ] **Step 3: Implement the resolution parts of `TrackingStore.swift`**

```swift
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
    enum Intent: Equatable { case requestQuickEntry }

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
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectResolutionTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MiniClockify/TrackingStore.swift Tests/MiniClockifyTests/TrackingStoreTests.swift
git commit -m "feat: TrackingStore project-resolution fallback chain"
```

---

### Task 8: `TrackingStore` — start / stop / discard / reconcile

**Files:**
- Modify: `Sources/MiniClockify/TrackingStore.swift`
- Modify: `Tests/MiniClockifyTests/TrackingStoreTests.swift`

- [ ] **Step 1: Write failing transition tests**

Append to `TrackingStoreTests.swift`:
```swift
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

    func testToggleWhileRunningStops() async {
        let stub = StubAPI()
        stub.startResult = TimeEntry(id: "e9", description: "w", projectId: nil,
                                     start: Date(timeIntervalSince1970: 10), end: nil)
        let s = makeStore(stub)
        await s.start(description: "w", projectId: nil)
        await s.toggle()   // running -> stop
        XCTAssertEqual(s.state, .idle)
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

    func testStartFailureKeepsIdleAndSurfacesError() async {
        let stub = StubAPI(); stub.startError = ClockifyError.network
        let s = makeStore(stub)
        await s.start(description: "w", projectId: nil)
        XCTAssertEqual(s.state, .idle)
        XCTAssertNotNil(s.lastError)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TrackingTransitionTests`
Expected: FAIL — missing methods.

- [ ] **Step 3: Extend `TrackingStore.swift`**

Add inside the class:
```swift
    var lastError: String?

    func toggle() async {
        switch state {
        case .idle: pendingIntent = .requestQuickEntry
        case .running: await stop()
        }
    }

    func clearIntent() { pendingIntent = nil }

    func start(description: String, projectId: String?) async {
        do {
            let entry = try await api.startEntry(
                workspaceId: workspaceId, description: description,
                projectId: projectId, start: Date())
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TrackingTransitionTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS — all tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/MiniClockify/TrackingStore.swift Tests/MiniClockifyTests/TrackingStoreTests.swift
git commit -m "feat: TrackingStore start/stop/discard/reconcile transitions"
```

---

## Chunk 3: UI, Hotkey, App Assembly, Bundle

> Chunk 3 is mostly UI wiring and is verified manually (no unit tests for AppKit/SwiftUI views). Commit after each task. Keep views thin — they only observe stores and call their methods.

### Task 9: `Notifier` (error surfacing)

**Files:**
- Create: `Sources/MiniClockify/Notifier.swift`

- [ ] **Step 1: Implement `Notifier.swift`**

```swift
import Foundation
import UserNotifications

/// Lazily requests notification auth; never required. Callers also surface
/// errors inline (panel) / in the menu, so a denial degrades gracefully.
enum Notifier {
    static func notify(_ message: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            func post() {
                let content = UNMutableNotificationContent()
                content.title = "Clockify"; content.body = message
                center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                  content: content, trigger: nil))
            }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { post() }
                }
            case .authorized, .provisional: post()
            default: break   // denied: rely on inline/menu fallback
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/MiniClockify/Notifier.swift
git commit -m "feat: Notifier with lazy auth + graceful denial"
```

---

### Task 10: `HotkeyManager`

**Files:**
- Create: `Sources/MiniClockify/HotkeyManager.swift`

No external dependency (see plan amendment) — registers a global hotkey directly
via Carbon's `RegisterEventHotKey`/`InstallEventHandler`. Default binding is
⌃⌥⌘T. The binding (key code + modifier flags) persists in `UserDefaults` so
`PreferencesView` (Task 11) can rebind it at runtime.

- [ ] **Step 1: Implement `HotkeyManager.swift`**

```swift
import Foundation
import Carbon.HIToolbox
import AppKit

/// Wraps Carbon's global-hotkey API (RegisterEventHotKey). Carbon has no
/// Swift-native replacement for *system-wide* hotkeys outside the app's own
/// key window, so this stays Carbon despite the rest of the app being
/// SwiftUI/AppKit. Persists the binding so it survives relaunch and can be
/// changed from PreferencesView without restarting the app.
@MainActor
final class HotkeyManager {
    struct Binding: Equatable, Codable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier mask (cmdKey | optionKey | controlKey | shiftKey)

        static let `default` = Binding(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: UInt32(cmdKey | optionKey | controlKey))
    }

    private static let defaultsKey = "hotkeyBinding"
    private let defaults: UserDefaults
    private let onToggle: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x434c4b46 /* "CLKF" */), id: 1)

    private(set) var binding: Binding

    init(defaults: UserDefaults = .standard, onToggle: @escaping () -> Void) {
        self.defaults = defaults
        self.onToggle = onToggle
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Binding.self, from: data) {
            binding = saved
        } else {
            binding = .default
        }
        installHandler()
        register(binding)
    }

    /// Re-registers with a new binding and persists it.
    func rebind(_ new: Binding) {
        unregister()
        binding = new
        if let data = try? JSONEncoder().encode(new) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        register(new)
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if hkID.id == manager.hotKeyID.id { manager.onToggle() }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    private func register(_ binding: Binding) {
        RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/MiniClockify/HotkeyManager.swift
git commit -m "feat: global hotkey registration via Carbon with persisted binding"
```

---

### Task 11: UI views + `@main` app wiring

**Files:**
- Create: `Sources/MiniClockify/AuthWindow.swift`
- Create: `Sources/MiniClockify/PreferencesView.swift`
- Create: `Sources/MiniClockify/QuickEntryPanel.swift`
- Replace: `Sources/MiniClockify/MiniClockifyApp.swift`

- [ ] **Step 1: `AuthWindow.swift`**

```swift
import SwiftUI

struct AuthWindow: View {
    let auth: AuthManager   // reads only; Observation tracks state in body
    @State private var key = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Clockify").font(.headline)
            Text("Paste your API key (Clockify → Profile Settings → API).")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("API key", text: $key)
                .textFieldStyle(.roundedBorder)
            if case .needsAuth(let msg?) = auth.state {
                Text(msg).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(busy ? "Checking…" : "Save") {
                    busy = true
                    Task { await auth.submit(key: key); busy = false }
                }
                .disabled(key.isEmpty || busy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
```

- [ ] **Step 2: `PreferencesView.swift`**

```swift
import SwiftUI
import Carbon.HIToolbox

struct PreferencesView: View {
    let auth: AuthManager
    let hotkey: HotkeyManager
    @State private var recording = false

    var body: some View {
        Form {
            HStack {
                Text("Toggle timer:")
                Button(recording ? "Press keys…" : label(for: hotkey.binding)) {
                    recording = true
                }
                .background(HotkeyRecorderCatcher(isActive: $recording) { keyCode, modifiers in
                    hotkey.rebind(HotkeyManager.Binding(keyCode: keyCode, modifiers: modifiers))
                    recording = false
                })
            }
            Button("Sign out / clear API key", role: .destructive) { auth.signOut() }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func label(for binding: HotkeyManager.Binding) -> String {
        var parts: [String] = []
        if binding.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if binding.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if binding.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if binding.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: binding.keyCode))
        return parts.joined()
    }
}

/// Invisible NSView that becomes first responder while `isActive` and reports
/// the next raw keyDown as a Carbon key code + modifier mask. Kept tiny and
/// AppKit-only so PreferencesView (SwiftUI) stays declarative.
private struct HotkeyRecorderCatcher: NSViewRepresentable {
    @Binding var isActive: Bool
    let onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView(); v.onCapture = onCapture; return v
    }
    func updateNSView(_ view: CatcherView, context: Context) {
        if isActive { view.window?.makeFirstResponder(view) }
    }

    final class CatcherView: NSView {
        var onCapture: ((UInt32, UInt32) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            onCapture?(UInt32(event.keyCode), mods)
        }
    }
}

/// Minimal virtual-keycode → display-name lookup for the recorder label.
/// Only covers letters/digits (sufficient for a hotkey like ⌃⌥⌘T); unknown
/// codes fall back to a numeric placeholder rather than crashing.
enum KeyCodeNames {
    private static let names: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z"
    ]
    static func name(for code: UInt32) -> String { names[code] ?? "#\(code)" }
}
```

- [ ] **Step 3: `QuickEntryPanel.swift`** (NSPanel host + combobox view)

```swift
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
        let hosting = NSHostingController(rootView: view)
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.setContentSize(NSSize(width: 460, height: 150))
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
    @State private var all: [String] = []
    @State private var highlighted = 0
    @State private var starting = false
    @FocusState private var focused: Bool

    private var matches: [String] {
        RecentDescriptions.filter(descriptions: all, query: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What are you working on?", text: $text)
                .textFieldStyle(.plain).font(.title3).focused($focused)
                .disabled(starting)
                .onSubmit { start() }
                .onChange(of: text) { _, _ in highlighted = 0 }  // reset on filter change
            Text(project.map { "→ \($0.name)" } ?? "→ No project yet")
                .font(.caption).foregroundStyle(.secondary)
            if let err = tracking.lastError {
                Text(err).font(.caption).foregroundStyle(.red)   // inline retry surface
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(matches.prefix(6).enumerated()), id: \.offset) { i, d in
                        Text(d)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(i == highlighted ? Color.accentColor.opacity(0.25) : .clear)
                            .onTapGesture { text = d; start() }
                    }
                }
            }.frame(maxHeight: 90)
        }
        .padding(16)
        .task {
            focused = true
            all = await RecentDescriptions.fetch(
                api: api, workspaceId: tracking.workspaceId, userId: tracking.userId)
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { onDone(); return .handled }
    }

    private func move(_ d: Int) {
        let n = min(matches.count, 6)
        guard n > 0 else { return }
        highlighted = (highlighted + d + n) % n
    }

    private func start() {
        guard !starting else { return }
        let chosen: String
        let m = matches
        if !m.isEmpty && text.isEmpty == false
            && m.indices.contains(highlighted)
            && m[highlighted].localizedCaseInsensitiveContains(text) {
            chosen = m[highlighted]
        } else {
            chosen = text.trimmingCharacters(in: .whitespaces)
        }
        guard !chosen.isEmpty else { return }   // reject empty; panel stays
        starting = true
        Task {
            await tracking.start(description: chosen, projectId: project?.id)
            starting = false
            // Only dismiss on success. On failure `start` stays .idle and sets
            // lastError, which renders inline above so the user can retry.
            if tracking.lastError == nil { onDone() }
        }
    }
}
```

- [ ] **Step 4: Replace `MiniClockifyApp.swift` with the real `@main`**

```swift
import SwiftUI

@main
struct MiniClockifyApp: App {
    @NSApplicationDelegateAdaptor(AppState.self) private var app

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: app)
        } label: {
            switch app.tracking?.state {
            case .running: Text(app.elapsed)
            default: Image(systemName: "timer")
            }
        }
        Settings {
            if let auth = app.auth, let hotkey = app.hotkey {
                PreferencesView(auth: auth, hotkey: hotkey)
            }
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
            let projects = (try? await client.projects(workspaceId: user.defaultWorkspace)) ?? []
            store.setProjects(projects)
            await store.reconcile()
            self.tracking = store
            self.panel = QuickEntryPanel(tracking: store, api: client)
        }
    }

    func handleToggle() async {
        guard let tracking else { showAuthWindow(); return }
        await tracking.toggle()
        if tracking.pendingIntent == .requestQuickEntry {
            tracking.clearIntent(); panel?.show()
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
        w.title = "Clockify"; w.styleMask = [.titled, .closable]
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
        guard case .running(_, let start, _, _)? = tracking?.state else { elapsed = "00:00:00"; return }
        let t = Int(Date().timeIntervalSince(start))
        elapsed = String(format: "%02d:%02d:%02d", t/3600, (t%3600)/60, t%60)
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

struct MenuContent: View {
    @ObservedObject var app: AppState
    var body: some View {
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
        SettingsLink { Text("Preferences…") }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: PASS. Fix any compile errors (SwiftUI `onKeyPress` requires macOS 14 — confirmed target). If `@Bindable` on `AuthManager` errors, ensure `AuthManager` is `@Observable` (Task 6).

- [ ] **Step 6: Commit**

```bash
git add Sources/MiniClockify/AuthWindow.swift Sources/MiniClockify/PreferencesView.swift Sources/MiniClockify/QuickEntryPanel.swift Sources/MiniClockify/MiniClockifyApp.swift
git commit -m "feat: menu bar UI, quick-entry panel, auth window, app wiring"
```

---

### Task 12: `.app` bundle assembly + ad-hoc sign

**Files:**
- Create: `Resources/Info.plist`
- Create: `build-app.sh`

- [ ] **Step 1: Write `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MiniClockify</string>
    <key>CFBundleIdentifier</key><string>com.datacenters.miniclockify</string>
    <key>CFBundleExecutable</key><string>MiniClockify</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Datacenters</string>
</dict>
</plist>
```

- [ ] **Step 2: Write `build-app.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
APP="MiniClockify.app"
BIN=".build/${CONFIG}/MiniClockify"

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MiniClockify"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so Keychain + notifications work.
codesign --force --sign - --deep "$APP"

echo "Built $APP"
```

- [ ] **Step 3: Lint the script**

Run: `shellcheck build-app.sh`
Expected: no errors.

- [ ] **Step 4: Make executable and build the app**

Run: `chmod +x build-app.sh && ./build-app.sh`
Expected: "Built MiniClockify.app".

- [ ] **Step 5: Manual verification checklist**

Run: `open MiniClockify.app`
Verify by hand (document results in the commit message or a `MANUAL_TEST.md`):
- Menu bar icon appears, no Dock icon (LSUIElement).
- First launch shows the paste-key window; entering a valid key dismisses it; invalid key shows red error.
- API key persists across relaunch (Keychain), no re-prompt.
- Global hotkey (⌃⌥⌘T) opens the quick-entry panel with the text field focused.
- Typing filters recent descriptions; ↑/↓ move highlight; Enter starts tracking; menu bar shows a ticking timer.
- Same hotkey stops; time logged in Clockify web.
- Menu: Stop / Discard while running; Preferences opens the recorder; rebinding the hotkey works; Sign out returns to paste-key window.

If macOS blocks the global hotkey, grant Accessibility permission in System Settings → Privacy & Security (note this in MANUAL_TEST.md).

- [ ] **Step 6: Commit**

```bash
git add Resources/Info.plist build-app.sh
git commit -m "build: .app bundle assembly and ad-hoc signing script"
```

---

## Definition of Done

- `swift test` passes (client, keychain, recent-descriptions, auth, tracking store).
- `./build-app.sh` produces a launchable `MiniClockify.app`.
- Manual checklist in Task 12 all verified.
- The three original flows work end-to-end: authenticate on first launch → hotkey opens focused quick-entry with a pre-selected project → Enter starts → same hotkey stops and logs.
- Start/stop/discard failures are visibly surfaced (inline red text in the panel for start; a red "⚠️ … Try again" menu item for stop/discard; plus a system notification when authorized) and never fail silently.
