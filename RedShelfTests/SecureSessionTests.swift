#if os(tvOS) && DEBUG
import Foundation
import Security
import XCTest
@testable import RedShelf

final class SecureSessionTests: XCTestCase {
    func testKeychainStoresAndUpdatesIsolatedAccountVault() throws {
        let service = "com.rayli.redshelf.test.\(UUID().uuidString)"
        let store = SecureSession(service: service)
        defer { try? store.removeForTesting() }
        XCTAssertNil(try store.load())

        let a = StoredSession(cookies: ["a1": "a", "webId": "a", "web_session": "a"], sessionKey: Data(repeating: 1, count: 32))
        let b = StoredSession(cookies: ["a1": "b", "webId": "b", "web_session": "b"], sessionKey: Data(repeating: 2, count: 32), region: .rednote)
        var vault = AccountVault()
        try vault.save(SavedAccount(id: "a", name: "A", session: a))
        try vault.save(SavedAccount(id: "b", name: "B", session: b))
        try store.save(vault)
        XCTAssertEqual(try store.load(), vault)

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "regional-accounts",
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        _ = try vault.activate(id: "a")
        try store.save(vault)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.active?.session, a)
        XCTAssertEqual(restored.accounts.first { $0.id == "b" }?.session, b)
        try store.removeForTesting()
        XCTAssertNil(try store.load())
    }
}
#endif
