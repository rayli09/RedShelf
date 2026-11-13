import Foundation
import CryptoKit

private final class MockServer: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    static var responseHeaders: ((URLRequest) -> [String: String])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw FeedError.invalidResponse }
            let (status, body) = try handler(request)
            var headers = ["Content-Type": "application/json"]
            Self.responseHeaders?(request).forEach { headers[$0.key] = $0.value }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class ConcurrentMockServer: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().async { [self] in
            do {
                guard let handler = Self.handler, let url = request.url else { throw FeedError.invalidResponse }
                let (status, body) = try handler(request)
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

private enum TestFailure: Error { case unexpectedRequest, failed(String) }
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure.failed(message) }
}
private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockServer.self]
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
}
private func makeClient(serverPublicKey: Data? = nil, cookies: [String: String] = ["a1": "test", "webId": "test"],
                        save: @escaping (StoredSession) throws -> Void) throws -> SignedClient {
    let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
    return try SignedClient(session: session(), initialCookies: cookies, saveVault: { vault in
        guard let stored = vault.active?.session else { throw FeedError.invalidResponse }
        try save(stored)
    }, signerScriptURL: script, sessionKeyServerPublicKey: serverPublicKey)
}
private func testVault(_ stored: StoredSession) throws -> AccountVault {
    var vault = AccountVault()
    try vault.save(SavedAccount(id: "test-user", name: "Test", session: stored))
    return vault
}
private func requestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}
private func verifySignature(_ request: URLRequest) throws {
    guard let header = request.value(forHTTPHeaderField: "x-s"), header.hasPrefix("XYS_") else { return }
    let custom = Array("ZmserbBoHQtNP+wOcza/LpngG8yJq42KWYj0DSfdikx3VT16IlUAFM97hECvuRX5")
    let standard = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    let translated = String(header.dropFirst(4).map { character in
        guard let index = custom.firstIndex(of: character) else { return character }
        return standard[index]
    })
    guard let decoded = Data(base64Encoded: translated),
          let value = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
          let digest = value["x5"] as? String, let path = request.url?.path else { throw TestFailure.failed("invalid XYS signature") }
    if path == "/api/qrcode/userinfo" {
        let proof = value["x6"] as? [String: String]
        let encrypted = value["x7"] as? [String: String]
        try expect(proof?["xhs-pc-web"]?.isEmpty == false && encrypted?["xhs-pc-web"]?.isEmpty == false,
                   "the exchanged session key was not included in the signature")
    }
    var content = Data(path.utf8)
    if request.httpMethod == "POST" {
        content += requestBody(request)
    } else if let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery {
        content += Data("?\(query)".utf8)
    } else { return }
    let expected = Insecure.MD5.hash(data: content).map { String(format: "%02x", $0) }.joined()
    try expect(digest == expected, "signature does not match transmitted body")
}

private func verifySessionProof(_ request: URLRequest, key: Data) throws {
    guard let header = request.value(forHTTPHeaderField: "x-s"), header.hasPrefix("XYS_") else { throw TestFailure.failed("missing XYS signature") }
    let custom = Array("ZmserbBoHQtNP+wOcza/LpngG8yJq42KWYj0DSfdikx3VT16IlUAFM97hECvuRX5")
    let standard = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    let translated = String(header.dropFirst(4).map { character in custom.firstIndex(of: character).map { standard[$0] } ?? character })
    guard let bytes = Data(base64Encoded: translated),
          let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          let proof = envelope["x7"] as? [String: String], let encoded = proof["xhs-pc-web"],
          let raw = Data(base64Encoded: encoded), raw.count >= 24 else { throw TestFailure.failed("missing session proof") }
    let expected = Data(Insecure.SHA1.hash(data: key + raw.prefix(4)))
    try expect(Data(raw.dropFirst(4).prefix(20)) == expected, "signature used the wrong session key")
}

@main
private struct AuthFlowChecks {
    static func main() async throws {
        try await successfulConfirmation()
        try await confirmedPollCanEstablishVerifiedSession()
        try await verifyAccountAfterCompletionFailure()
        try await overseasConfirmationUsesIsolatedRegion()
        try await overseasFailureRestoresDomesticGuest()
        try await overseasGuestIsNeverSavedAsAccount()
        try await rejectedResponseCannotChangeSession()
        try await mismatchedIdentityMustNotPersist()
        try await failedCompletionMustNotPersist()
        try await riskErrorIsActionableAndRedacted()
        try await guestIdentityMustNotPersist()
        try await invalidGuestKeyStopsLogin()
        try await missingGuestSessionStopsLogin()
        try await newLoginInvalidatesOldActivation()
        try await restoredSessionRetainsItsSigningKey()
        try await localSignOutClearsSession()
        try await signOutInvalidatesInFlightResponse()
        try await switchInvalidatesOldAccountResponse()
        try await switchesBetweenIsolatedAccounts()
        try await detailCacheRespectsAccountAndInteractions()
        try await detailPrefetchCannotCrossAccountSwitch()
        try await expiredSessionStopsRequestsAndPreservesAccounts()
        try await refreshedCookiesSurviveAccountSwitchAndRestart()
        try await profileIdentityAndNameAreSafe()
        try await expiredCodeMustNotPersist()
        print("QR login flow checks passed")
    }

    private static func refreshedCookiesSurviveAccountSwitchAndRestart() async throws {
        var vault = try testVault(StoredSession(cookies: ["a1": "test", "webId": "test", "web_session": "old"], sessionKey: nil))
        try vault.save(SavedAccount(id: "other", name: "Other", session: StoredSession(cookies: ["a1": "other", "webId": "other", "web_session": "other"], sessionKey: nil)))
        _ = try vault.activate(id: "test-user")
        var saved = vault
        var requestCount = 0
        MockServer.handler = { request in
            requestCount += 1
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let expected = requestCount <= 2 ? "old" : (requestCount == 3 ? "other" : "renewed")
            try expect(cookie.contains("web_session=\(expected)"), "wrong session after cookie rotation")
            if requestCount == 1 { return (200, #"{"success":false,"code":-1}"#) }
            return (200, #"{"success":true,"data":{"items":[]}}"#)
        }
        MockServer.responseHeaders = { _ in requestCount <= 2 ? ["Set-Cookie": "web_session=renewed; Domain=.xiaohongshu.com; Path=/; Secure"] : [:] }
        defer { MockServer.responseHeaders = nil }
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let client = try SignedClient(session: session(), initialVault: vault, saveVault: { saved = $0 }, signerScriptURL: script)
        do { _ = try await client.homeFeed(); throw TestFailure.failed("failed response accepted") }
        catch is TestFailure { throw TestFailure.failed("failed response accepted") }
        catch { }
        try expect(saved.active?.session.cookies["web_session"] == "old", "failed response persisted cookies")
        _ = try await client.homeFeed()
        try expect(saved.active?.session.cookies["web_session"] == "renewed", "rotated session was not persisted")
        try await client.switchAccount(id: "other")
        _ = try await client.homeFeed()
        try await client.switchAccount(id: "test-user")
        _ = try await client.homeFeed()
        let restored = try SignedClient(session: session(), initialVault: saved, saveVault: { _ in }, signerScriptURL: script)
        _ = try await restored.homeFeed()
    }

    private static func detailCacheRespectsAccountAndInteractions() async throws {
        var vault = try testVault(StoredSession(cookies: ["a1": "a", "webId": "a", "web_session": "a"], sessionKey: nil))
        try vault.save(SavedAccount(id: "other", name: "Other", session: StoredSession(cookies: ["a1": "b", "webId": "b", "web_session": "b"], sessionKey: nil)))
        _ = try vault.activate(id: "test-user")
        var detailRequests = 0
        var commentRequests = 0
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/sns/web/v1/feed":
                detailRequests += 1
                return (200, #"{"success":true,"data":{"items":[{"note_card":{"title":"Test"}}]}}"#)
            case "/api/sns/web/v1/note/like": return (200, #"{"success":true,"data":null}"#)
            case "/api/sns/web/v2/comment/page":
                commentRequests += 1
                return (200, #"{"success":true,"data":{"comments":[],"cursor":"","has_more":false}}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let client = try SignedClient(session: session(), initialVault: vault, saveVault: { _ in }, signerScriptURL: script)
        let note = FeedNote(id: "note", title: "Test", author: "", cover: nil, avatar: nil, likes: "", isVideo: false, accessToken: "token", source: "pc_feed")
        _ = try await client.noteDetail(for: note)
        _ = try await client.noteDetail(for: note)
        try expect(detailRequests == 1, "detail was not reused")
        _ = try await client.comments(for: note)
        _ = try await client.comments(for: note)
        _ = try await client.comments(for: note, cursor: "next")
        try expect(commentRequests == 2, "first-page comments were not reused or pagination was cached")
        try await client.setLiked(true, noteID: note.id)
        _ = try await client.noteDetail(for: note)
        _ = try await client.comments(for: note)
        try expect(detailRequests == 2, "interaction did not invalidate detail")
        try expect(commentRequests == 3, "interaction did not invalidate comments")
        try await client.switchAccount(id: "other")
        _ = try await client.noteDetail(for: note)
        _ = try await client.comments(for: note)
        try expect(detailRequests == 3, "detail leaked across accounts")
        try expect(commentRequests == 4, "comments leaked across accounts")
    }

    private static func detailPrefetchCannotCrossAccountSwitch() async throws {
        var vault = try testVault(StoredSession(cookies: ["a1": "a", "webId": "a", "web_session": "a"], sessionKey: nil))
        try vault.save(SavedAccount(id: "other", name: "Other", session: StoredSession(cookies: ["a1": "b", "webId": "b", "web_session": "b"], sessionKey: nil)))
        _ = try vault.activate(id: "test-user")
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests = 0
        ConcurrentMockServer.handler = { request in
            lock.lock(); requests += 1; let attempt = requests; lock.unlock()
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if attempt == 1 {
                try expect(cookie.contains("web_session=a"), "prefetch used the wrong account")
                started.signal()
                guard release.wait(timeout: .now() + 10) == .success else { throw TestFailure.failed("prefetch not released") }
            } else {
                try expect(cookie.contains("web_session=b"), "new account received old cache")
            }
            return (200, #"{"success":true,"data":{"items":[{"note_card":{"title":"Test"}}]}}"#)
        }
        defer { ConcurrentMockServer.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConcurrentMockServer.self]
        config.httpShouldSetCookies = false
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let client = try SignedClient(session: URLSession(configuration: config), initialVault: vault, saveVault: { _ in }, signerScriptURL: script)
        let note = FeedNote(id: "note", title: "Test", author: "", cover: nil, avatar: nil, likes: "", isVideo: false, accessToken: "token", source: "pc_feed")
        let old = Task { try await client.noteDetail(for: note) }
        let ready = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        guard ready else { release.signal(); throw TestFailure.failed("prefetch did not start") }
        try await client.switchAccount(id: "other")
        release.signal()
        do { _ = try await old.value; throw TestFailure.failed("old account prefetch returned") }
        catch is CancellationError { }
        _ = try await client.noteDetail(for: note)
        try expect(requests == 2, "new account did not fetch its own detail")
    }

    private static func expiredSessionStopsRequestsAndPreservesAccounts() async throws {
        let stored = StoredSession(cookies: ["a1": "a", "webId": "a", "web_session": "a"], sessionKey: nil)
        let vault = try testVault(stored)
        var requests = 0
        MockServer.handler = { _ in requests += 1; return (200, #"{"success":false,"code":-100}"#) }
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let client = try SignedClient(session: session(), initialVault: vault, saveVault: { _ in throw TestFailure.failed("expired account was overwritten") }, signerScriptURL: script)
        do { _ = try await client.homeFeed(); throw TestFailure.failed("expired session accepted") }
        catch FeedError.sessionExpired { }
        try expect(!(await client.isLoggedIn), "expired session remained active")
        let accounts = await client.accounts
        try expect(accounts.count == 1 && !accounts[0].isActive, "expired account was removed")
        do { _ = try await client.homeFeed(); throw TestFailure.failed("expired session retried") }
        catch FeedError.unavailable { }
        try expect(requests == 1, "expired session sent another request")
    }

    private static func overseasGuestIsNeverSavedAsAccount() async throws {
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        var saved = false
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/qrcode/userinfo": return (200, #"{"success":true,"data":{"codeStatus":2,"userId":"user-a","geoZone":1}}"#)
            case "/api/sns/web/v1/login/activate":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
                guard let raw = body?["client_public_key_base64"], let bytes = Data(base64Encoded: raw) else { throw TestFailure.unexpectedRequest }
                let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes)
                let shared = try serverKey.sharedSecretFromKeyAgreement(with: publicKey)
                let key = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
                let box = try AES.GCM.seal(Data(repeating: 0x73, count: 32), using: key)
                let ssk = (Data(box.nonce) + box.ciphertext + box.tag).base64EncodedString()
                let response = try JSONSerialization.data(withJSONObject: ["success": true, "data": ["session": "regional-guest", "ssk": ssk]])
                return (200, String(decoding: response, as: UTF8.self))
            case "/api/sns/web/v1/login/qrcode/status":
                return (200, #"{"success":true,"data":{"login_info":{"user_id":"user-a"}}}"#)
            case "/api/sns/web/v2/user/me":
                return (200, #"{"success":true,"data":{"guest":true,"user_id":"user-a"}}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = try makeClient(serverPublicKey: serverKey.publicKey.rawRepresentation) { _ in saved = true }
        do {
            _ = try await client.checkLogin(LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!))
            throw TestFailure.failed("regional guest was accepted")
        } catch is TestFailure { throw TestFailure.failed("regional guest was accepted") }
        catch { }
        try expect(!saved, "regional guest was saved as an account")
    }

    private static func overseasFailureRestoresDomesticGuest() async throws {
        var polls = 0
        var saved = false
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/qrcode/userinfo":
                try expect(request.url?.host == "edith.xiaohongshu.com", "failure left wrong active region")
                try expect((request.value(forHTTPHeaderField: "Cookie") ?? "").contains("web_session=domestic-guest"), "failure did not restore domestic session")
                polls += 1
                return polls == 1 ? (200, #"{"success":true,"data":{"codeStatus":2,"userId":"user-a","geoZone":1}}"#)
                                  : (200, #"{"success":true,"data":{"codeStatus":3}}"#)
            case "/api/sns/web/v1/login/activate":
                try expect(request.url?.host == "webapi.rednote.com", "regional activation used wrong host")
                return (500, "")
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = try makeClient(cookies: ["a1": "domestic-secret", "webId": "shared-web", "web_session": "domestic-guest"]) { _ in saved = true }
        let challenge = LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!)
        for _ in 0..<2 {
            do { _ = try await client.checkLogin(challenge); throw TestFailure.failed("failed regional login accepted") }
            catch is TestFailure { throw TestFailure.failed("failed regional login accepted") }
            catch { }
        }
        try expect(!saved && polls == 2, "failed regional login changed persisted state")
    }

    private static func overseasConfirmationUsesIsolatedRegion() async throws {
        MockServer.responseHeaders = { request in
            guard request.url?.host == "webapi.rednote.com" else { return [:] }
            if request.url?.path.hasSuffix("activate") == true {
                return ["Set-Cookie": "web_session=regional-guest; Domain=.rednote.com; Path=/; Secure"]
            }
            if request.url?.path.hasSuffix("qrcode/status") == true {
                return ["Set-Cookie": "web_session=regional-user; Domain=.rednote.com; Path=/; Secure"]
            }
            return [:]
        }
        defer { MockServer.responseHeaders = nil }
        for zone in [1, 2] {
            var saved: StoredSession?
            let serverKey = Curve25519.KeyAgreement.PrivateKey()
            let guestKey = Data(repeating: 0x71, count: 32)
            let accountKey = Data(repeating: 0x72, count: 32)
            MockServer.handler = { request in
                switch request.url?.path {
                case "/api/qrcode/userinfo":
                    try expect(request.url?.host == "edith.xiaohongshu.com", "confirmation used wrong origin")
                    let fields = zone == 1 ? "\"accountGeographicZone\":\"US\",\"accountHolderCountry\":\"US\"" : "\"account_geographic_zone\":\"US\",\"account_holder_country\":\"US\""
                    return (200, "{\"success\":true,\"data\":{\"codeStatus\":2,\"userId\":\"user-a\",\"geoZone\":\(zone),\(fields)}}")
                case "/api/sns/web/v1/login/activate", "/api/sns/web/v1/login/qrcode/status":
                    try expect(request.url?.host == "webapi.rednote.com", "overseas request used wrong origin")
                    try expect(request.value(forHTTPHeaderField: "Origin") == "https://www.rednote.com", "wrong regional origin header")
                    let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                    try expect(!cookie.contains("domestic-secret") && !cookie.contains("domestic-guest"), "domestic cookies leaked to RedNote")
                    let encoded: String?
                    let key: Data
                    if request.url?.path.hasSuffix("activate") == true {
                        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
                        encoded = body?["client_public_key_base64"]
                        key = guestKey
                        try expect(cookie.contains("webId=shared-web"), "redirect lost web identity")
                    } else {
                        try expect(request.value(forHTTPHeaderField: "x-rednote-datactry") == "US", "missing regional header")
                        try expect(request.value(forHTTPHeaderField: "x-rednote-holderctry") == "US", "missing holder header")
                        try verifySessionProof(request, key: guestKey)
                        encoded = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_public_key_base64" }?.value
                        key = accountKey
                    }
                    guard let encoded, let bytes = Data(base64Encoded: encoded) else { throw TestFailure.failed("missing regional exchange key") }
                    let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes)
                    let shared = try serverKey.sharedSecretFromKeyAgreement(with: publicKey)
                    let symmetric = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
                    let sealed = try AES.GCM.seal(key, using: symmetric)
                    let ssk = (Data(sealed.nonce) + sealed.ciphertext + sealed.tag).base64EncodedString()
                    let data: [String: Any] = request.url?.path.hasSuffix("activate") == true
                        ? ["ssk": ssk]
                        : ["login_info": ["user_id": "user-a", "ssk": ssk]]
                    let response = try JSONSerialization.data(withJSONObject: ["success": true, "data": data])
                    return (200, String(decoding: response, as: UTF8.self))
                case "/api/sns/web/v1/homefeed":
                    try expect(request.url?.host == "webapi.rednote.com", "regional session restored to wrong host")
                    try expect((request.value(forHTTPHeaderField: "Cookie") ?? "").contains("web_session=regional-user"), "regional account cookie missing")
                    try verifySessionProof(request, key: accountKey)
                    return (200, #"{"success":true,"data":{"items":[]}}"#)
                default: throw TestFailure.unexpectedRequest
                }
            }
            let client = try makeClient(serverPublicKey: serverKey.publicKey.rawRepresentation,
                                        cookies: ["a1": "domestic-secret", "webId": "shared-web", "web_session": "domestic-guest"]) { saved = $0 }
            guard case .authenticated = try await client.checkLogin(LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!)) else { throw TestFailure.failed("regional session not authenticated") }
            try expect(saved?.region == .rednote && saved?.sessionKey == accountKey, "regional session not saved")
            _ = try await client.homeFeed()
            guard let saved else { throw TestFailure.failed("missing saved regional account") }
            let bytes = try JSONEncoder().encode(testVault(saved))
            let restoredVault = try JSONDecoder().decode(AccountVault.self, from: bytes)
            let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
            let restored = try SignedClient(session: session(), initialVault: restoredVault, saveVault: { _ in }, signerScriptURL: script)
            _ = try await restored.homeFeed()
        }
    }

    private static func switchInvalidatesOldAccountResponse() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let keyA = Data(repeating: 0x61, count: 32), keyB = Data(repeating: 0x62, count: 32)
        let a = StoredSession(cookies: ["a1": "a", "webId": "a", "web_session": "a"], sessionKey: keyA)
        let b = StoredSession(cookies: ["a1": "b", "webId": "b", "web_session": "b"], sessionKey: keyB)
        var vault = try testVault(a)
        try vault.save(SavedAccount(id: "b", name: "B", session: b))
        _ = try vault.activate(id: "test-user")
        MockServer.responseHeaders = { request in
            (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("web_session=a")
                ? ["Set-Cookie": "web_session=stale; Domain=.xiaohongshu.com; Path=/; Secure"] : [:]
        }
        defer { MockServer.responseHeaders = nil }
        MockServer.handler = { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if cookie.contains("web_session=a") {
                try verifySessionProof(request, key: keyA)
                started.signal()
                guard release.wait(timeout: .now() + 10) == .success else { throw TestFailure.failed("old request not released") }
            } else {
                try expect(cookie.contains("web_session=b"), "old response changed new account cookie")
                try verifySessionProof(request, key: keyB)
            }
            return (200, #"{"success":true,"data":{"items":[]}}"#)
        }
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let client = try SignedClient(session: session(), initialVault: vault, saveVault: { _ in }, signerScriptURL: script)
        let request = Task { try await client.homeFeed() }
        let ready = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        guard ready else { release.signal(); throw TestFailure.failed("old request not started") }
        try await client.switchAccount(id: "b")
        release.signal()
        do { _ = try await request.value; throw TestFailure.failed("old account response accepted") }
        catch is CancellationError { }
        _ = try await client.homeFeed()
    }

    private static func rejectedResponseCannotChangeSession() async throws {
        var calls = 0
        MockServer.responseHeaders = { _ in ["Set-Cookie": "web_session=poison; Domain=.xiaohongshu.com; Path=/; Secure"] }
        defer { MockServer.responseHeaders = nil }
        MockServer.handler = { request in
            try expect(request.value(forHTTPHeaderField: "Cookie")?.contains("web_session=guest") == true,
                       "failed response changed the current session")
            calls += 1
            if calls == 1 { return (200, #"{"success":false,"code":-1}"#) }
            return (200, #"{"success":true,"data":{"codeStatus":3}}"#)
        }
        let client = try makeClient(cookies: ["a1": "test", "webId": "test", "web_session": "guest"]) { _ in
            throw TestFailure.failed("failed request saved credentials")
        }
        let challenge = LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!)
        for _ in 0..<3 {
            do { _ = try await client.checkLogin(challenge); throw TestFailure.failed("failed request accepted") }
            catch is TestFailure { throw TestFailure.failed("failed request accepted") }
            catch { }
        }
        try expect(calls == 3, "test did not exercise rejected and expired responses")
    }

    private static func confirmedPollCanEstablishVerifiedSession() async throws {
        var completions = 0
        var saved: StoredSession?
        MockServer.responseHeaders = { request in
            request.url?.path == "/api/qrcode/userinfo" ? ["Set-Cookie": "web_session=confirmed; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Domain=.xiaohongshu.com; Path=/; Secure, web_session_sec=secure-value; Domain=.xiaohongshu.com; Path=/; Secure"] : [:]
        }
        defer { MockServer.responseHeaders = nil }
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/qrcode/userinfo":
                return (200, #"{"success":true,"data":{"codeStatus":2,"userId":"user-a"}}"#)
            case "/api/sns/web/v2/user/me":
                try expect(request.value(forHTTPHeaderField: "Cookie")?.contains("web_session=confirmed") == true, "confirmed cookie was not sent")
                return (200, #"{"success":true,"data":{"guest":false,"user_id":"user-a"}}"#)
            case "/api/sns/web/v1/login/qrcode/status":
                completions += 1
                return (200, #"{"success":false,"code":-1}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let challenge = LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!)
        let client = try makeClient { saved = $0 }
        guard case .authenticated = try await client.checkLogin(challenge) else { throw TestFailure.failed("verified poll did not log in") }
        try expect(saved?.cookies["web_session"] == "confirmed" && saved?.cookies["web_session_sec"] == "secure-value" && completions == 0,
                   "confirmed cookies were lost or completion was called unnecessarily")
        let failing = try makeClient { _ in throw TestFailure.failed("save failed") }
        do { _ = try await failing.checkLogin(challenge); throw TestFailure.failed("save failure ignored") }
        catch TestFailure.failed(let message) where message == "save failed" { }
        let loggedIn = await failing.isLoggedIn
        try expect(completions == 0 && !loggedIn, "save failure triggered completion or authenticated")
        var mismatchedSaved = false
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/qrcode/userinfo": return (200, #"{"success":true,"data":{"codeStatus":2,"userId":"user-a"}}"#)
            case "/api/sns/web/v2/user/me": return (200, #"{"success":true,"data":{"guest":false,"user_id":"other"}}"#)
            case "/api/sns/web/v1/login/qrcode/status": return (200, #"{"success":false,"code":-1}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let mismatch = try makeClient { _ in mismatchedSaved = true }
        do { _ = try await mismatch.checkLogin(challenge); throw TestFailure.failed("wrong account authenticated") }
        catch is TestFailure { throw TestFailure.failed("wrong account authenticated") }
        catch { }
        try expect(!mismatchedSaved, "unverified poll session was saved")
    }

    private static func verifyAccountAfterCompletionFailure() async throws {
        let challenge = LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!)
        for returnedIdentity in ["expected", "other", "guest"] {
            var profileChecks = 0
            var saved: StoredSession?
            MockServer.handler = { request in
                switch request.url?.path {
                case "/api/qrcode/userinfo": return (200, #"{"success":true,"data":{"codeStatus":2,"userId":"expected"}}"#)
                case "/api/sns/web/v1/login/qrcode/status": return (200, #"{"success":false,"code":-1}"#)
                case "/api/sns/web/v2/user/me":
                    profileChecks += 1
                    if profileChecks == 1 || returnedIdentity == "guest" {
                        return (200, #"{"success":true,"data":{"guest":true,"user_id":"expected"}}"#)
                    }
                    return (200, "{\"success\":true,\"data\":{\"guest\":false,\"user_id\":\"\(returnedIdentity)\"}}")
                default: throw TestFailure.unexpectedRequest
                }
            }
            let client = try makeClient(cookies: ["a1": "test", "webId": "test", "web_session": "guest"]) { saved = $0 }
            if returnedIdentity == "expected" {
                guard case .authenticated = try await client.checkLogin(challenge) else { throw TestFailure.failed("verified account not accepted") }
                try expect(saved != nil, "verified account was not saved")
            } else {
                do { _ = try await client.checkLogin(challenge); throw TestFailure.failed("unverified account accepted") }
                catch is TestFailure { throw TestFailure.failed("unverified account accepted") }
                catch { }
                try expect(saved == nil, "unverified account was saved")
            }
            try expect(profileChecks == 2, "completion error did not trigger identity verification")
            if returnedIdentity == "expected" {
                profileChecks = 0
                let failing = try makeClient(cookies: ["a1": "test", "webId": "test", "web_session": "guest"]) { _ in
                    throw TestFailure.failed("save failed")
                }
                do { _ = try await failing.checkLogin(challenge); throw TestFailure.failed("save failure ignored") }
                catch TestFailure.failed(let message) where message == "save failed" { }
                try expect(!(await failing.isLoggedIn), "save failure authenticated the account")
            }
        }
    }

    private static func profileIdentityAndNameAreSafe() async throws {
        let stored = StoredSession(cookies: ["a1": "a", "webId": "a", "web_session": "a"], sessionKey: nil)
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        var saves = 0
        let client = try SignedClient(session: session(), initialVault: testVault(stored), saveVault: { _ in
            saves += 1
            throw TestFailure.failed("save failed")
        }, signerScriptURL: script)
        MockServer.handler = { _ in (200, #"{"success":true,"data":{"user_id":"other","nickname":"Wrong"}}"#) }
        do { _ = try await client.profile(); throw TestFailure.failed("wrong profile accepted") }
        catch is TestFailure { throw TestFailure.failed("wrong profile accepted") }
        catch { }
        try expect(saves == 0, "mismatched profile changed saved accounts")
        MockServer.handler = { _ in (200, #"{"success":true,"data":{"user_id":"test-user","nickname":"Updated"}}"#) }
        let profile = try await client.profile()
        let accounts = await client.accounts
        let loggedIn = await client.isLoggedIn
        try expect(profile.name == "Updated" && saves == 1, "valid profile unavailable after name save failure")
        try expect(accounts.first?.name == "Test" && loggedIn, "failed name save changed session")
        do {
            _ = try await client.userNotes(.collected, userID: "other")
            throw TestFailure.failed("personal notes accepted another account")
        } catch FeedError.unavailable { }
    }

    private static func switchesBetweenIsolatedAccounts() async throws {
        let keyA = Data(repeating: 0x31, count: 32), keyB = Data(repeating: 0x32, count: 32)
        let sessionA = StoredSession(cookies: ["a1": "a", "webId": "a", "web_session": "a"], sessionKey: keyA)
        let sessionB = StoredSession(cookies: ["a1": "b", "webId": "b", "web_session": "b"], sessionKey: keyB, region: .rednote)
        var vault = try testVault(sessionA)
        try vault.save(SavedAccount(id: "other", name: "Other", session: sessionB))
        _ = try vault.activate(id: "test-user")
        var persisted = vault
        var rejectSave = false
        var expectedSession = "b"
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let client = try SignedClient(session: session(), initialVault: vault, saveVault: { value in
            if rejectSave { throw TestFailure.failed("save failed") }
            persisted = value
        }, signerScriptURL: script)
        MockServer.handler = { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            try expect(cookie.contains("web_session=\(expectedSession)"), "request used the wrong active account")
            if cookie.contains("web_session=a") {
                try expect(request.url?.host == "edith.xiaohongshu.com", "domestic account used wrong origin")
                try verifySessionProof(request, key: keyA)
            }
            else if cookie.contains("web_session=b") {
                try expect(request.url?.host == "webapi.rednote.com", "overseas account used wrong origin")
                try verifySessionProof(request, key: keyB)
            }
            else { throw TestFailure.failed("unexpected session") }
            return (200, #"{"success":true,"data":{"items":[]}}"#)
        }
        try await client.switchAccount(id: "other")
        try expect(persisted.activeID == "other", "switch was not persisted")
        _ = try await client.homeFeed()
        let restored = try SignedClient(session: session(), initialVault: persisted, saveVault: { _ in }, signerScriptURL: script)
        _ = try await restored.homeFeed()
        rejectSave = true
        do { try await client.switchAccount(id: "test-user"); throw TestFailure.failed("save was ignored") }
        catch TestFailure.failed(let message) where message == "save failed" { }
        _ = try await client.homeFeed()
        try expect(persisted.activeID == "other", "failed switch changed active account")
        rejectSave = false
        try await client.beginAddingAccount()
        try expect(!(await client.isLoggedIn), "adding an account should use a fresh guest")
        try await client.switchAccount(id: "test-user")
        expectedSession = "a"
        _ = try await client.homeFeed()
        try await client.signOut()
        try expect(persisted.accounts.count == 1 && persisted.accounts.first?.id == "other" && persisted.activeID == nil,
                   "sign out removed another account")
    }

    private static func riskErrorIsActionableAndRedacted() async throws {
        var persisted = false
        for code in [300011, 300012, 300013, 300015, 461, 471] {
            for isHTTP in (code == 461 || code == 471 ? [false, true] : [false]) {
                MockServer.handler = { request in
                    switch request.url?.path {
                    case "/api/qrcode/userinfo":
                        return (200, #"{"success":true,"data":{"codeStatus":2,"userId":"expected"}}"#)
                    case "/api/sns/web/v1/login/qrcode/status":
                        return (isHTTP ? code : 200, "{\"success\":false,\"code\":\(code),\"msg\":\"private-server-detail\"}")
                    default: throw TestFailure.unexpectedRequest
                    }
                }
                let client = try makeClient { _ in persisted = true }
                do {
                    _ = try await client.checkLogin(LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!))
                    throw TestFailure.failed("risk response accepted")
                } catch is TestFailure { throw TestFailure.failed("risk response accepted") }
                catch {
                    let message = error.localizedDescription
                    try expect(message.contains("安全限制") && message.contains("\(code)"), "risk was not surfaced")
                    try expect(!message.contains("private-server-detail"), "raw server message leaked")
                }
            }
        }
        try expect(!persisted, "risk failure saved a session")
    }

    private static func signOutInvalidatesInFlightResponse() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        MockServer.handler = { _ in
            started.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw TestFailure.failed("request was not released") }
            return (200, #"{"success":true,"data":{"items":[]}}"#)
        }
        let stored = StoredSession(cookies: ["a1": "test", "webId": "test", "web_session": "stored"], sessionKey: nil)
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let client = try SignedClient(session: session(), initialVault: testVault(stored), saveVault: { _ in }, signerScriptURL: script)
        let request = Task { try await client.homeFeed() }
        let didStart = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        guard didStart else { release.signal(); throw TestFailure.failed("request did not start") }
        try await client.signOut()
        release.signal()
        do {
            _ = try await request.value
            throw TestFailure.failed("response from old session was accepted")
        } catch is CancellationError { }
        try expect(!(await client.isLoggedIn), "old response restored a signed-out session")
    }

    private static func localSignOutClearsSession() async throws {
        let key = Data(repeating: 0x41, count: 32)
        let stored = StoredSession(cookies: ["a1": "test", "webId": "test", "web_session": "stored"], sessionKey: key)
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        var deletes = 0
        let client = try SignedClient(session: session(), initialVault: testVault(stored), saveVault: { _ in deletes += 1 }, signerScriptURL: script)
        try await client.signOut()
        let signedIn = await client.isLoggedIn
        try expect(deletes == 1 && !signedIn, "sign out did not clear the local session")
        do {
            _ = try await client.homeFeed()
            throw TestFailure.failed("signed-out client accessed feed")
        } catch FeedError.unavailable { }

        MockServer.handler = { request in
            try verifySessionProof(request, key: key)
            return (200, #"{"success":true,"data":{"items":[]}}"#)
        }
        let failed = try SignedClient(session: session(), initialVault: testVault(stored),
                                      saveVault: { _ in throw TestFailure.failed("keychain deletion failed") }, signerScriptURL: script)
        do {
            try await failed.signOut()
            throw TestFailure.failed("failed deletion was reported as success")
        } catch TestFailure.failed(let message) where message == "keychain deletion failed" { }
        try expect(await failed.isLoggedIn, "failed deletion should preserve the session")
        _ = try await failed.homeFeed()
    }

    private static func restoredSessionRetainsItsSigningKey() async throws {
        let key = Data(repeating: 0x37, count: 32)
        MockServer.handler = { request in
            guard request.url?.path == "/api/sns/web/v1/homefeed" else { throw TestFailure.unexpectedRequest }
            try verifySessionProof(request, key: key)
            return (200, #"{"success":true,"data":{"items":[]}}"#)
        }
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let stored = StoredSession(cookies: ["a1": "test", "webId": "test", "web_session": "stored"], sessionKey: key)
        let client = try SignedClient(session: session(), initialVault: testVault(stored), saveVault: { _ in }, signerScriptURL: script)
        try expect(await client.isLoggedIn, "stored session should restore")
        _ = try await client.homeFeed()
    }

    private static func guestIdentityMustNotPersist() async throws {
        var persisted = false
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/qrcode/userinfo": return (200, #"{"success":true,"data":{"codeStatus":2,"userId":"expected"}}"#)
            case "/api/sns/web/v1/login/qrcode/status": return (200, #"{"success":true,"data":{"login_info":{"user_id":"expected"}}}"#)
            case "/api/sns/web/v2/user/me": return (200, #"{"success":true,"data":{"guest":true,"basic_info":{"user_id":"expected"}}}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = try makeClient(cookies: ["a1": "test", "webId": "test", "web_session": "guest"]) { _ in persisted = true }
        do {
            _ = try await client.checkLogin(LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!))
            throw TestFailure.failed("guest identity accepted")
        } catch is TestFailure { throw TestFailure.failed("guest identity accepted") }
        catch { }
        try expect(!persisted, "guest session must not be saved")
        try expect(!(await client.isLoggedIn), "guest session must not be authenticated")
    }

    private static func invalidGuestKeyStopsLogin() async throws {
        var createdQR = false
        var activations = 0
        MockServer.responseHeaders = { _ in ["Set-Cookie": "web_session=bad-header; Domain=.xiaohongshu.com; Path=/; Secure"] }
        defer { MockServer.responseHeaders = nil }
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/sns/web/v1/login/activate":
                activations += 1
                try expect(request.value(forHTTPHeaderField: "Cookie")?.contains("web_session=original") == true,
                           "failed activation left a stale guest session")
                return (200, #"{"success":true,"data":{"session":"bad-body","ssk":"invalid"}}"#)
            case "/api/sns/web/v1/login/qrcode/create":
                createdQR = true
                return (200, #"{"success":true,"data":{"qr_id":"id","code":"code","url":"xhsdiscover://login"}}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = try makeClient(cookies: ["a1": "test", "webId": "test", "web_session": "original"]) { _ in throw TestFailure.failed("must not persist") }
        for _ in 0..<2 {
            do {
                _ = try await client.beginLogin()
                throw TestFailure.failed("invalid guest key accepted")
            } catch is TestFailure { throw TestFailure.failed("invalid guest key accepted") }
            catch { }
        }
        try expect(activations == 2 && !createdQR, "invalid guest key must stop before creating a QR")
        try expect(!(await client.isLoggedIn), "invalid guest key must not authenticate")
    }

    private static func missingGuestSessionStopsLogin() async throws {
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        var createdQR = false
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/sns/web/v1/login/activate":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
                guard let encoded = body?["client_public_key_base64"], let bytes = Data(base64Encoded: encoded) else { throw TestFailure.unexpectedRequest }
                let secret = try serverKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes))
                let key = secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
                let box = try AES.GCM.seal(Data(repeating: 0x41, count: 32), using: key)
                let encrypted = (Data(box.nonce) + box.ciphertext + box.tag).base64EncodedString()
                return (200, "{\"success\":true,\"data\":{\"ssk\":\"\(encrypted)\"}}")
            case "/api/sns/web/v1/login/qrcode/create":
                createdQR = true
                throw TestFailure.unexpectedRequest
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = try makeClient(serverPublicKey: serverKey.publicKey.rawRepresentation) { _ in throw TestFailure.failed("must not persist") }
        do { _ = try await client.beginLogin(); throw TestFailure.failed("missing guest session accepted") }
        catch is TestFailure { throw TestFailure.failed("missing guest session accepted") }
        catch { }
        let loggedIn = await client.isLoggedIn
        try expect(!createdQR && !loggedIn, "missing guest session started login")
    }

    private static func newLoginInvalidatesOldActivation() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let guestKey = Data(repeating: 0x41, count: 32)
        let lock = NSLock()
        var activations = 0
        ConcurrentMockServer.handler = { request in
            switch request.url?.path {
            case "/api/sns/web/v1/login/activate":
                lock.lock(); activations += 1; let attempt = activations; lock.unlock()
                if attempt == 1 {
                    started.signal()
                    guard release.wait(timeout: .now() + 10) == .success else { throw TestFailure.failed("old activation not released") }
                    return (200, #"{"success":true,"data":{"session":"old","ssk":"invalid"}}"#)
                }
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
                guard let encoded = body?["client_public_key_base64"], let bytes = Data(base64Encoded: encoded) else { throw TestFailure.unexpectedRequest }
                let secret = try serverKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes))
                let key = secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
                let box = try AES.GCM.seal(guestKey, using: key)
                let encrypted = (Data(box.nonce) + box.ciphertext + box.tag).base64EncodedString()
                return (200, "{\"success\":true,\"data\":{\"session\":\"new\",\"ssk\":\"\(encrypted)\"}}")
            case "/api/sns/web/v1/login/qrcode/create":
                return (200, #"{"success":true,"data":{"qr_id":"id","code":"code","url":"xhsdiscover://login"}}"#)
            case "/api/qrcode/userinfo":
                try expect(request.value(forHTTPHeaderField: "Cookie")?.contains("web_session=new") == true, "old activation overwrote new session")
                try verifySessionProof(request, key: guestKey)
                return (200, #"{"success":true,"data":{"codeStatus":0}}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        defer { ConcurrentMockServer.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConcurrentMockServer.self]
        config.httpShouldSetCookies = false
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
        let client = try SignedClient(session: URLSession(configuration: config), initialCookies: ["a1": "test", "webId": "test"], saveVault: { _ in throw TestFailure.failed("must not persist") }, signerScriptURL: script, sessionKeyServerPublicKey: serverKey.publicKey.rawRepresentation)
        let old = Task { try await client.beginLogin() }
        let ready = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        guard ready else { release.signal(); throw TestFailure.failed("old activation did not start") }
        let challenge: LoginChallenge
        do { challenge = try await client.beginLogin() }
        catch { release.signal(); throw error }
        release.signal()
        do { _ = try await old.value; throw TestFailure.failed("old activation accepted") }
        catch is CancellationError { }
        guard case .waiting = try await client.checkLogin(challenge) else { throw TestFailure.failed("new challenge was not retained") }
    }

    private static func failedCompletionMustNotPersist() async throws {
        var persisted = false
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/qrcode/userinfo": return (200, #"{"success":true,"data":{"codeStatus":2,"userId":"expected"}}"#)
            case "/api/sns/web/v1/login/qrcode/status": return (200, #"{"success":false,"code":-1}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = try makeClient { _ in persisted = true }
        do {
            _ = try await client.checkLogin(LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!))
            throw TestFailure.failed("failed completion accepted")
        } catch is TestFailure { throw TestFailure.failed("failed completion accepted") }
        catch { try expect(error.localizedDescription.contains("无法建立登录会话"), "completion failure should be identifiable") }
        try expect(!persisted, "failed completion must not save a session")
        try expect(!(await client.isLoggedIn), "failed completion must not authenticate")
    }

    private static func successfulConfirmation() async throws {
        var polls = 0
        var saved: StoredSession?
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let expectedKey = Data(repeating: 0x42, count: 32)
        let expectedAccountKey = Data(repeating: 0x55, count: 32)
        MockServer.handler = { request in
            if request.url?.path != "/livestream/123" {
                try expect(request.value(forHTTPHeaderField: "x-s")?.hasPrefix("XYS_") == true, "request lacks XYS signature")
                try verifySignature(request)
            }
            switch request.url?.path {
            case "/api/sns/web/v1/login/activate":
                let payload = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
                guard let encoded = payload?["client_public_key_base64"], let data = Data(base64Encoded: encoded) else { throw TestFailure.failed("missing exchange public key") }
                let clientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
                let shared = try serverKey.sharedSecretFromKeyAgreement(with: clientKey)
                let symmetric = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
                let box = try AES.GCM.seal(expectedKey, using: symmetric)
                let encrypted = Data(box.nonce) + box.ciphertext + box.tag
                let response = try JSONSerialization.data(withJSONObject: ["success": true, "data": ["session": "guest", "ssk": encrypted.base64EncodedString()]])
                return (200, String(decoding: response, as: UTF8.self))
            case "/api/sns/web/v1/login/qrcode/create": return (200, #"{"success":true,"data":{"qr_id":"id","code":"code","url":"xhsdiscover://login"}}"#)
            case "/api/qrcode/userinfo":
                try verifySessionProof(request, key: expectedKey)
                try expect(request.httpMethod == "POST", "poll must be POST")
                try expect(request.value(forHTTPHeaderField: "service-tag") == "webcn", "poll tag missing")
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
                try expect(body?["qrId"] == "id" && body?["code"] == "code", "incorrect challenge")
                defer { polls += 1 }
                return (200, [#"{"success":true,"data":{"codeStatus":0}}"#,
                              #"{"success":true,"data":{"codeStatus":1}}"#,
                              #"{"success":true,"data":{"codeStatus":2,"userId":"user-a"}}"#][min(polls, 2)])
            case "/api/sns/web/v1/login/qrcode/status":
                try expect(request.value(forHTTPHeaderField: "x-login-mode") == "", "domestic QR completion lacks login mode header")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                try expect(query.contains { $0.name == "qr_id" && $0.value == "id" }, "wrong completion parameter")
                guard let encoded = query.first(where: { $0.name == "client_public_key_base64" })?.value,
                      let data = Data(base64Encoded: encoded) else { throw TestFailure.failed("missing completion public key") }
                let clientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
                let shared = try serverKey.sharedSecretFromKeyAgreement(with: clientKey)
                let symmetric = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
                let box = try AES.GCM.seal(expectedAccountKey, using: symmetric)
                let encrypted = Data(box.nonce) + box.ciphertext + box.tag
                let response = try JSONSerialization.data(withJSONObject: ["success": true, "data": ["login_info": ["user_id": "user-a", "session": "authenticated", "ssk": encrypted.base64EncodedString()]]])
                return (200, String(decoding: response, as: UTF8.self))
            case "/api/sns/web/v1/homefeed":
                try verifySessionProof(request, key: expectedAccountKey)
                try expect(request.value(forHTTPHeaderField: "x-rap-param")?.isEmpty == false, "feed lacks risk parameter")
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                if body?["cursor_score"] as? String == "page-2" {
                    try expect(body?["note_index"] as? Int == 1 && body?["refresh_type"] as? Int == 3, "incorrect next page parameters")
                    return (200, #"{"success":true,"data":{"cursor_score":"","items":[{"id":"note-2","note_card":{"title":"下一页"}}]}}"#)
                }
                try expect(body?["cursor_score"] as? String == "" && body?["note_index"] as? Int == 0 && body?["refresh_type"] as? Int == 1, "incorrect first page parameters")
                return (200, #"{"success":true,"data":{"cursor_score":"page-2","items":[{"id":"note-1","xsec_token":"a+b/c=","note_card":{"title":"标题","user":{"nickname":"作者"}}}]}}"#)
            case "/api/sns/web/v1/feed":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                try expect(body?["xsec_token"] as? String == "a+b/c=", "detail lost note token")
                return (200, #"{"success":true,"data":{"items":[{"note_card":{"title":"标题","desc":"内容","user":{"nickname":"作者"},"image_list":[{"info_list":[{"image_scene":"WB_DFT","url":"https://example.com/image.jpg"}]}],"video":{"media":{"stream":{"EF4":[{"master_url":"https://example.com/video.mp4"}]}}}}}]}}"#)
            case "/api/sns/web/v2/comment/page":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                try expect(query.contains { $0.name == "xsec_token" && $0.value == "a+b/c=" }, "comments corrupted token")
                return (200, #"{"success":true,"data":{"comments":[{"id":"comment-1","content":"评论","user_info":{"nickname":"读者"}}],"cursor":"","has_more":false}}"#)
            case "/api/sns/web/v2/comment/sub/page":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                try expect(query.contains { $0.name == "root_comment_id" && $0.value == "comment-1" }, "reply root missing")
                try expect(query.contains { $0.name == "xsec_token" && $0.value == "a+b/c=" }, "reply token corrupted")
                return (200, #"{"success":true,"data":{"comments":[{"id":"reply-1","content":"回复"}],"cursor":"","has_more":false}}"#)
            case "/api/sns/web/v1/search/notes":
                try expect(request.value(forHTTPHeaderField: "x-rap-param")?.isEmpty == false, "search lacks risk parameter")
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                try expect(body?["keyword"] as? String == "猫" && body?["note_type"] as? Int == 1,
                           "search parameters do not match the selected filter")
                return (200, #"{"success":true,"data":{"items":[{"id":"search-1","xsec_token":"search-token","note_card":{"title":"结果"}}],"has_more":true}}"#)
            case "/api/sns/web/v1/search/usersearch":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                let search = body?["search_user_request"] as? [String: Any]
                try expect(search?["keyword"] as? String == "猫" && search?["biz_type"] as? String == "web_search_user", "invalid user search request")
                return (200, #"{"success":true,"data":{"users":[{"id":"creator","name":"创作者","xsec_token":"creator-token"}],"has_more":false}}"#)
            case "/api/sns/web/v2/user/me":
                if request.value(forHTTPHeaderField: "Cookie")?.contains("web_session=guest") == true {
                    return (200, #"{"success":true,"data":{"guest":true}}"#)
                }
                return (200, #"{"success":true,"data":{"guest":false,"user_id":"user-a","nickname":"测试用户","red_id":"red-id"}}"#)
            case "/api/sns/web/v1/user/otherinfo":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                try expect(query.contains { $0.name == "target_user_id" && $0.value == "user-a" }, "profile details requested for wrong user")
                return (200, #"{"success":true,"data":{"basic_info":{"user_id":"user-a","desc":"简介"},"interactions":[{"type":"fans","count":"227"}]}}"#)
            case "/api/sns/red/live/web/feed/v1/squarefeed":
                try expect(request.url?.host == "live-room.xiaohongshu.com", "live feed used wrong origin")
                try expect(request.value(forHTTPHeaderField: "xy-common-params") == "platform=web", "live feed platform header missing")
                try verifySessionProof(request, key: expectedAccountKey)
                return (200, #"{"success":true,"data":{"feeds":[{"live":{"t_room_info":{"room_id_str":"123","name":"直播"},"t_live_host_info":{"nickname":"主播"}}}]}}"#)
            case "/livestream/123":
                try expect(request.url?.host == "www.xiaohongshu.com", "live room used wrong origin")
                return (200, #"<script>window.__INITIAL_STATE__={"liveStream":{"pageStatus":"success","liveStatus":"success","roomData":{"roomInfo":{"roomId":"123","status":2,"monetizeType":0,"joinLimitTypes":[0],"pullConfig":{"h264":[{"master_url":"https://v.xhscdn.com/live/123.m3u8"}]}}}}};</script>"#)
            case "/api/sns/web/v1/user_posted", "/api/sns/web/v1/note/like/page", "/api/sns/web/v2/note/collect/page":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                try expect(query.contains { $0.name == "user_id" && ($0.value == "user-a" || $0.value == "creator") }, "notes requested for wrong user")
                if query.contains(where: { $0.name == "user_id" && $0.value == "creator" }) {
                    try expect(query.contains { $0.name == "xsec_token" && $0.value == "creator-token" }, "creator token not forwarded")
                }
                return (200, #"{"success":true,"data":{"notes":[{"note_id":"personal-1","display_title":"个人笔记","xsec_token":"personal-token"}],"cursor":"next","has_more":true}}"#)
            case "/api/sns/web/v1/note/like", "/api/sns/web/v1/note/dislike":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
                try expect(body?["note_oid"] == "note-1", "like request targeted wrong note")
                return (200, #"{"success":true,"data":null}"#)
            case "/api/sns/web/v1/note/collect", "/api/sns/web/v1/note/uncollect":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
                let key = request.url?.path.hasSuffix("/uncollect") == true ? "note_ids" : "note_id"
                try expect(body?[key] == "note-1", "favorite request targeted wrong note")
                return (200, #"{"success":true,"data":null}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = try makeClient(serverPublicKey: serverKey.publicKey.rawRepresentation) { saved = $0 }
        let challenge = try await client.beginLogin()
        guard case .waiting = try await client.checkLogin(challenge) else { throw TestFailure.failed("expected waiting") }
        guard case .scanned = try await client.checkLogin(challenge) else { throw TestFailure.failed("expected scanned") }
        guard case .authenticated = try await client.checkLogin(challenge) else { throw TestFailure.failed("expected authenticated") }
        try expect(await client.isLoggedIn, "verified session must be active")
        try expect(saved?.cookies["web_session"] == "authenticated", "verified session must be saved")
        try expect(saved?.sessionKey == expectedAccountKey, "account session key must be saved with verified session")
        let feed = try await client.homeFeed()
        try expect(feed.notes.count == 1 && feed.notes[0].accessToken == "a+b/c=", "feed did not retain note token")
        let next = try await client.homeFeed(cursor: feed.cursor, noteIndex: feed.notes.count)
        try expect(next.notes.first?.id == "note-2" && next.cursor.isEmpty, "feed pagination failed")
        let detail = try await client.noteDetail(for: feed.notes[0])
        try expect(detail.title == "标题" && detail.images.count == 1 && detail.video != nil, "detail not parsed")
        let comments = try await client.comments(for: feed.notes[0])
        try expect(comments.comments.first?.content == "评论", "comments not parsed")
        let replies = try await client.replies(for: feed.notes[0], rootID: "comment-1")
        try expect(replies.comments.first?.content == "回复", "replies not parsed")
        let searchID = try await client.newSearchID()
        let search = try await client.searchNotes(keyword: "猫", type: 1, page: 1, searchID: searchID)
        try expect(search.hasMore && search.notes.first?.source == "pc_search", "search source or pagination lost")
        let people = try await client.searchUsers(keyword: "猫", page: 1, searchID: searchID)
        guard let creator = people.users.first else { throw TestFailure.failed("user search returned no users") }
        try expect(creator.name == "创作者" && creator.token == "creator-token", "user search fields lost")
        let publicNotes = try await client.publicUserNotes(user: creator)
        try expect(publicNotes.notes.first?.id == "personal-1", "public user notes missing")
        let profile = try await client.profile()
        try expect(profile.id == "user-a" && profile.name == "测试用户", "profile not parsed")
        let details = try await client.profileDetails(profile)
        try expect(details.biography == "简介" && details.followers == "227", "profile details not parsed")
        let accounts = await client.accounts
        try expect(accounts.first?.name == "测试用户", "verified account name was not saved")
        let rooms = try await client.liveRooms()
        try expect(rooms.first?.id == "123" && rooms.first?.host == "主播", "live feed not parsed")
        let stream = try await client.liveStream(roomID: "123")
        try expect(stream.host == "v.xhscdn.com", "live room stream not resolved")
        for collection in UserNoteCollection.allCases {
            let page = try await client.userNotes(collection, userID: profile.id)
            try expect(page.hasMore && page.cursor == "next" && page.notes.first?.accessToken == "personal-token", "personal notes not parsed")
        }
        try await client.setLiked(true, noteID: "note-1")
        try await client.setLiked(false, noteID: "note-1")
        try await client.setCollected(true, noteID: "note-1")
        try await client.setCollected(false, noteID: "note-1")
    }

    private static func mismatchedIdentityMustNotPersist() async throws {
        var persisted = false
        MockServer.handler = { request in
            switch request.url?.path {
            case "/api/qrcode/userinfo": return (200, #"{"success":true,"data":{"codeStatus":2,"userId":"expected"}}"#)
            case "/api/sns/web/v1/login/qrcode/status": return (200, #"{"success":true,"data":{"login_info":{"user_id":"other","session":"other-session"}}}"#)
            case "/api/sns/web/v2/user/me": return (200, #"{"success":true,"data":{"basic_info":{"user_id":"other"}}}"#)
            default: throw TestFailure.unexpectedRequest
            }
        }
        let client = try makeClient { _ in persisted = true }
        do {
            _ = try await client.checkLogin(LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!))
            throw TestFailure.failed("mismatched account accepted")
        } catch is TestFailure { throw TestFailure.failed("mismatched account accepted") }
        catch { }
        try expect(!persisted, "unverified session must not be saved")
        try expect(!(await client.isLoggedIn), "unverified session must not be active")
    }

    private static func expiredCodeMustNotPersist() async throws {
        var persisted = false
        MockServer.handler = { _ in (200, #"{"success":true,"data":{"codeStatus":3}}"#) }
        let client = try makeClient { _ in persisted = true }
        do {
            _ = try await client.checkLogin(LoginChallenge(id: "id", code: "code", url: URL(string: "xhsdiscover://login")!))
            throw TestFailure.failed("expired code accepted")
        } catch is TestFailure { throw TestFailure.failed("expired code accepted") }
        catch { }
        try expect(!persisted, "expired code must not save a session")
    }
}
