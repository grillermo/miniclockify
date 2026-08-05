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
