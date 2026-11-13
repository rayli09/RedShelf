import Foundation
import XCTest
@testable import RedShelf

final class AccountVaultTests: XCTestCase {
    func testAccountSwitchPreservesSeparateSessionsAndRoundTrips() throws {
        let first = SavedAccount(id: "one", name: "First", session: StoredSession(cookies: ["a1": "one", "webId": "one", "web_session": "first"], sessionKey: Data([1])))
        let second = SavedAccount(id: "two", name: "Second", session: StoredSession(cookies: ["a1": "two", "webId": "two", "web_session": "second"], sessionKey: Data([2])))
        var vault = AccountVault()
        try vault.save(first)
        try vault.save(second)
        try vault.save(second)
        XCTAssertEqual(vault.accounts.count, 2)
        XCTAssertEqual(vault.active?.id, "two")
        XCTAssertEqual(try vault.activate(id: "one"), first.session)
        XCTAssertEqual(vault.active?.id, "one")
        XCTAssertThrowsError(try vault.activate(id: "missing"))
        XCTAssertEqual(vault.active?.id, "one")
        let restored = try JSONDecoder().decode(AccountVault.self, from: JSONEncoder().encode(vault))
        XCTAssertEqual(restored, vault)
        vault.remove(id: "one")
        XCTAssertNil(vault.active)
        XCTAssertEqual(vault.accounts, [second])
    }

    func testInvalidAndDuplicateAccountsAreRejected() throws {
        var vault = AccountVault()
        let invalid = SavedAccount(id: "one", name: "", session: StoredSession(cookies: [:], sessionKey: nil))
        XCTAssertThrowsError(try vault.save(invalid))
        XCTAssertTrue(vault.accounts.isEmpty)
        let duplicate = #"{"accounts":[{"id":"x","name":"a","session":{"cookies":{"a1":"a","webId":"a","web_session":"a"},"region":"xiaohongshu"}},{"id":"x","name":"b","session":{"cookies":{"a1":"b","webId":"b","web_session":"b"},"region":"xiaohongshu"}}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccountVault.self, from: Data(duplicate.utf8)))
        let missingActive = #"{"accounts":[],"activeID":"missing"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccountVault.self, from: Data(missingActive.utf8)))
    }
}
