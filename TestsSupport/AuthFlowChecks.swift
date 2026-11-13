import Foundation
import CryptoKit

private final class MockServer: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw FeedError.invalidResponse }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
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
private func makeClient(serverPublicKey: Data? = nil, save: @escaping (StoredSession) throws -> Void) throws -> SignedClient {
    let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Generated/WebSigner.js")
    return try SignedClient(session: session(), initialCookies: ["a1": "test", "webId": "test"], saveSession: save, signerScriptURL: script, sessionKeyServerPublicKey: serverPublicKey)
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
        try await mismatchedIdentityMustNotPersist()
        try await failedCompletionMustNotPersist()
        try await expiredCodeMustNotPersist()
        print("QR login flow checks passed")
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
            try expect(request.value(forHTTPHeaderField: "x-s")?.hasPrefix("XYS_") == true, "request lacks XYS signature")
            try verifySignature(request)
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
                return (200, #"{"success":true,"data":{"items":[{"id":"note-1","xsec_token":"a+b/c=","note_card":{"title":"标题","user":{"nickname":"作者"}}}]}}"#)
            case "/api/sns/web/v1/feed":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                try expect(body?["xsec_token"] as? String == "a+b/c=", "detail lost note token")
                return (200, #"{"success":true,"data":{"items":[{"note_card":{"title":"标题","desc":"内容","user":{"nickname":"作者"},"image_list":[{"url_default":"https://example.com/image.jpg"}]}}]}}"#)
            case "/api/sns/web/v2/comment/page":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                try expect(query.contains { $0.name == "xsec_token" && $0.value == "a+b/c=" }, "comments corrupted token")
                return (200, #"{"success":true,"data":{"comments":[{"id":"comment-1","content":"评论","user_info":{"nickname":"读者"}}],"cursor":"","has_more":false}}"#)
            case "/api/sns/web/v1/search/notes":
                try expect(request.value(forHTTPHeaderField: "x-rap-param")?.isEmpty == false, "search lacks risk parameter")
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                try expect(body?["keyword"] as? String == "猫" && body?["note_type"] as? Int == 1,
                           "search parameters do not match the selected filter")
                return (200, #"{"success":true,"data":{"items":[{"id":"search-1","xsec_token":"search-token","note_card":{"title":"结果"}}],"has_more":true}}"#)
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
        try expect(feed.count == 1 && feed[0].accessToken == "a+b/c=", "feed did not retain note token")
        let detail = try await client.noteDetail(for: feed[0])
        try expect(detail.title == "标题" && detail.images.count == 1, "detail not parsed")
        let comments = try await client.comments(for: feed[0])
        try expect(comments.comments.first?.content == "评论", "comments not parsed")
        let searchID = try await client.newSearchID()
        let search = try await client.searchNotes(keyword: "猫", type: 1, page: 1, searchID: searchID)
        try expect(search.hasMore && search.notes.first?.source == "pc_search", "search source or pagination lost")
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
