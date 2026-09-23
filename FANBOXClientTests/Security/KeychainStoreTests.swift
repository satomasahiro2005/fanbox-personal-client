import XCTest
@testable import FANBOXClient

final class KeychainStoreTests: XCTestCase {
    private var keychain: KeychainStore!

    override func setUp() {
        super.setUp()
        keychain = KeychainStore(service: "ai.nemut.FANBOXClient.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? keychain.removeAll()
        keychain = nil
        super.tearDown()
    }

    func testSetReadUpdateRemove() throws {
        XCTAssertNil(try keychain.data(for: "k1"))
        try keychain.set(Data("v1".utf8), for: "k1")
        XCTAssertEqual(try keychain.data(for: "k1"), Data("v1".utf8))
        // Update in place.
        try keychain.set(Data("v2".utf8), for: "k1")
        XCTAssertEqual(try keychain.string(for: "k1"), "v2")
        try keychain.remove("k1")
        XCTAssertNil(try keychain.data(for: "k1"))
        // Removing a missing item is not an error.
        XCTAssertNoThrow(try keychain.remove("k1"))
    }

    func testAllKeysAndServiceIsolation() throws {
        XCTAssertEqual(try keychain.allKeys(), [])
        try keychain.setString("a", for: "credential.B")
        try keychain.setString("b", for: "credential.A")
        XCTAssertEqual(try keychain.allKeys(), ["credential.A", "credential.B"])

        let other = KeychainStore(service: keychain.service + ".other")
        defer { try? other.removeAll() }
        XCTAssertEqual(try other.allKeys(), [])
        XCTAssertNil(try other.data(for: "credential.A"))

        try keychain.removeAll()
        XCTAssertEqual(try keychain.allKeys(), [])
    }

    func testLargeBinaryValueRoundTrips() throws {
        let blob = Data((0..<8_192).map { UInt8($0 % 251) })
        try keychain.set(blob, for: "blob")
        XCTAssertEqual(try keychain.data(for: "blob"), blob)
    }
}
