import Foundation
import Security
import Signer

struct LoginChallenge {
    let id: String
    let code: String
    let url: URL
}

enum LoginProgress { case waiting, scanned, authenticated }

struct StoredSession: Codable {
    let cookies: [String: String]
    let sessionKey: Data?
}

private enum LoginRequestError: LocalizedError {
    case http(Int)
    case api(Int)
    case malformed
    case expired
    case completion
    case identityMismatch
    case network

    var errorDescription: String? {
        switch self {
        case let .http(status): return "服务器返回 HTTP \(status)"
        case let .api(code): return "小红书返回错误 \(code)"
        case .malformed: return "服务器返回了无法识别的数据"
        case .expired: return "二维码已过期，请重新生成"
        case .completion: return "手机确认后无法建立登录会话，请重试"
        case .identityMismatch: return "无法验证登录账号，请重试"
        case .network: return "无法连接小红书，请检查网络"
        }
    }
}

private enum SecureSession {
    private static let service = "com.rayli.redshelf.session"
    static func load() -> StoredSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "active",
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: "active"]
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw FeedError.invalidResponse }
        } else if status != errSecSuccess { throw FeedError.invalidResponse }
    }
}

private final class RestrictedRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", let host = request.url?.host,
              host == "edith.xiaohongshu.com" || host == "www.xiaohongshu.com" else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

actor SignedClient {
    static let shared = try? SignedClient()
    private static let agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 Edg/142.0.0.0"
    private let session: URLSession
    private let signer: WebSigner
    private let saveSession: (StoredSession) throws -> Void
    private let sessionKeyServerPublicKey: Data?
    private var cookies: [String: String]
    private var sessionKey: Data?
    private var authenticated: Bool
    private var lastLoggedQRStatus: Int?

    // These diagnostics intentionally contain no request bodies, URLs with
    // query strings, account identifiers, cookies, signatures, or QR values.
    private func log(_ event: String) {
        print("[RedShelf.Auth] \(event)")
    }

    private func errorCategory(_ message: String) -> String {
        let text = message.lowercased()
        if text.contains("sign") || text.contains("签名") { return "signature" }
        if text.contains("expired") || text.contains("过期") { return "expired" }
        if text.contains("risk") || text.contains("风控") || text.contains("验证") { return "verification" }
        if text.contains("login") || text.contains("登录") { return "login" }
        return "other"
    }

    init(session suppliedSession: URLSession? = nil,
         initialCookies: [String: String]? = nil,
         saveSession: ((StoredSession) throws -> Void)? = nil,
         signerScriptURL: URL? = nil,
         sessionKeyServerPublicKey: Data? = nil) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = suppliedSession ?? URLSession(configuration: configuration, delegate: RestrictedRedirects(), delegateQueue: nil)
        signer = try WebSigner(scriptURL: signerScriptURL)
        self.saveSession = saveSession ?? SecureSession.save
        self.sessionKeyServerPublicKey = sessionKeyServerPublicKey
        if let initialCookies {
            cookies = initialCookies
            sessionKey = nil
            authenticated = false
        } else if let saved = SecureSession.load(), saved.cookies["web_session"] != nil {
            cookies = saved.cookies
            sessionKey = saved.sessionKey
            try signer.setSessionKey(saved.sessionKey)
            authenticated = true
        } else {
            var error: NSError?
            let value = SignerNewSession(&error)
            if let error { throw error }
            let data = Data(value.utf8)
            cookies = try JSONDecoder().decode([String: String].self, from: data)
            sessionKey = nil
            authenticated = false
        }
    }

    var isLoggedIn: Bool { authenticated }

    func homeFeed() async throws -> [FeedNote] {
        let payload: [String: Any] = ["cursor_score": "", "num": 35, "refresh_type": 1,
                                      "note_index": 0, "unread_begin_note_id": "", "unread_end_note_id": "",
                                      "unread_note_count": 0, "category": "homefeed_recommend", "search_key": "",
                                      "need_num": 40, "image_scenes": ["FD_PRV_WEBP", "FD_WM_WEBP"]]
        let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let body = String(data: raw, encoding: .utf8) else { throw FeedError.invalidResponse }
        let result = try await call(method: "POST", uri: "/api/sns/web/v1/homefeed", body: body)
        return try FeedParser.parseHomeFeed(result)
    }

    func noteDetail(for note: FeedNote) async throws -> NoteDetail {
        guard authenticated, !note.accessToken.isEmpty else { throw FeedError.unavailable }
        let payload: [String: Any] = ["source_note_id": note.id,
                                      "image_formats": ["jpg", "webp", "avif"],
                                      "extra": ["need_body_topic": "1"],
                                      "xsec_source": note.source, "xsec_token": note.accessToken]
        let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let body = String(data: raw, encoding: .utf8) else { throw FeedError.invalidResponse }
        return try FeedParser.parseAPIDetail(try await call(method: "POST", uri: "/api/sns/web/v1/feed", body: body))
    }

    func comments(for note: FeedNote, cursor: String = "") async throws -> CommentPage {
        guard authenticated, !note.accessToken.isEmpty else { throw FeedError.unavailable }
        let uri = try queryURI(path: "/api/sns/web/v2/comment/page", parameters: [
            "note_id": note.id, "cursor": cursor, "top_comment_id": "",
            "image_formats": "jpg,webp,avif", "xsec_token": note.accessToken,
        ])
        return try FeedParser.parseComments(try await call(method: "GET", uri: uri, body: ""))
    }

    func setLiked(_ value: Bool, noteID: String) async throws {
        guard authenticated, !noteID.isEmpty else { throw FeedError.unavailable }
        let body = try JSONEncoder().encode(["note_oid": noteID])
        guard let text = String(data: body, encoding: .utf8) else { throw FeedError.invalidResponse }
        _ = try await call(method: "POST", uri: value ? "/api/sns/web/v1/note/like" : "/api/sns/web/v1/note/dislike", body: text, allowEmptyData: true)
    }

    func setCollected(_ value: Bool, noteID: String) async throws {
        guard authenticated, !noteID.isEmpty else { throw FeedError.unavailable }
        let body = try JSONEncoder().encode([value ? "note_id" : "note_ids": noteID])
        guard let text = String(data: body, encoding: .utf8) else { throw FeedError.invalidResponse }
        _ = try await call(method: "POST", uri: value ? "/api/sns/web/v1/note/collect" : "/api/sns/web/v1/note/uncollect", body: text, allowEmptyData: true)
    }

    func newSearchID() throws -> String { try signer.newSearchID() }

    func searchNotes(keyword: String, type: Int, page: Int, searchID: String) async throws -> SearchPage {
        guard authenticated, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...2).contains(type), page > 0, !searchID.isEmpty else { throw FeedError.invalidResponse }
        let filters = [
            ["tags": ["general"], "type": "sort_type"],
            ["tags": ["不限"], "type": "filter_note_type"],
            ["tags": ["不限"], "type": "filter_note_time"],
            ["tags": ["不限"], "type": "filter_note_range"],
            ["tags": ["不限"], "type": "filter_pos_distance"],
        ] as [[String: Any]]
        let payload: [String: Any] = ["keyword": keyword, "page": page, "page_size": 20,
                                      "search_id": searchID, "sort": "general", "note_type": type,
                                      "ext_flags": [], "filters": filters, "geo": "",
                                      "image_formats": ["jpg", "webp", "avif"]]
        let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let body = String(data: raw, encoding: .utf8) else { throw FeedError.invalidResponse }
        let data = try await call(method: "POST", uri: "/api/sns/web/v1/search/notes", body: body)
        return SearchPage(notes: try FeedParser.parseHomeFeed(data, source: "pc_search"), hasMore: data["has_more"] as? Bool ?? false)
    }

    func beginLogin() async throws -> LoginChallenge {
        lastLoggedQRStatus = nil
        log("event=begin_login")
        if !authenticated {
            let exchange = try SessionKeyExchange(serverPublicKey: sessionKeyServerPublicKey)
            let payload = try JSONEncoder().encode(["client_public_key_base64": exchange.publicKeyBase64])
            guard let body = String(data: payload, encoding: .utf8) else { throw LoginRequestError.malformed }
            let guest = try await call(method: "POST", uri: "/api/sns/web/v1/login/activate", body: body)
            applySession(from: guest)
            guard let encrypted = guest["ssk"] as? String, !encrypted.isEmpty else { throw LoginRequestError.malformed }
            let key = try exchange.decrypt(encrypted)
            try signer.setSessionKey(key)
            sessionKey = key
            log("event=guest_session_key_ready")
        }
        let data = try await call(method: "POST", uri: "/api/sns/web/v1/login/qrcode/create", body: "{\"qr_type\":1}")
        guard let id = data["qr_id"] as? String, let code = data["code"] as? String,
              let value = data["url"] as? String, let url = URL(string: value),
              url.scheme == "xhsdiscover" || (url.scheme == "https" && url.host?.hasSuffix(".xiaohongshu.com") == true) else { throw FeedError.invalidResponse }
        log("event=qr_created")
        return LoginChallenge(id: id, code: code, url: url)
    }

    func checkLogin(_ challenge: LoginChallenge) async throws -> LoginProgress {
        let raw = try JSONSerialization.data(withJSONObject: ["qrId": challenge.id, "code": challenge.code], options: [.sortedKeys])
        guard let body = String(data: raw, encoding: .utf8) else { throw LoginRequestError.malformed }
        let data = try await call(method: "POST", uri: "/api/qrcode/userinfo", body: body, extraHeaders: ["service-tag": "webcn"])
        guard let status = data["codeStatus"] as? Int else { throw LoginRequestError.malformed }
        if status != lastLoggedQRStatus {
            log("event=qr_status status=\(status)")
            lastLoggedQRStatus = status
        }
        let loginStatus = try QRLoginStatus(code: status)
        if loginStatus == .expired { throw LoginRequestError.expired }
        if loginStatus == .confirmed {
            guard let confirmedUserID = data["userId"] as? String, !confirmedUserID.isEmpty else {
                log("event=confirmed_missing_user")
                throw LoginRequestError.malformed
            }
            log("event=confirmation_received")
            let previousCookies = cookies
            let previousSessionKey = sessionKey
            do {
                let exchange = try SessionKeyExchange(serverPublicKey: sessionKeyServerPublicKey)
                let uri = try queryURI(path: "/api/sns/web/v1/login/qrcode/status", parameters: [
                    "code": challenge.code, "qr_id": challenge.id,
                    "client_public_key_base64": exchange.publicKeyBase64,
                ])
                let completion: [String: Any]
                do { completion = try await call(method: "GET", uri: uri, body: "") }
                catch is CancellationError { throw CancellationError() }
                catch {
                    log("event=completion_request_failed")
                    throw LoginRequestError.completion
                }
                applySession(from: completion)
                let completionInfo = completion["login_info"] as? [String: Any] ?? [:]
                if let encrypted = (completion["ssk"] as? String) ?? (completionInfo["ssk"] as? String), !encrypted.isEmpty {
                    let key = try exchange.decrypt(encrypted)
                    try signer.setSessionKey(key)
                    sessionKey = key
                    log("event=account_session_key_ready")
                }
                guard cookies["web_session"] != nil else {
                    log("event=completion_missing_session")
                    throw LoginRequestError.completion
                }
                let completionID = userID(in: completion)
                log("event=completion_received identity_matches=\(completionID == confirmedUserID) session_changed=\(cookies["web_session"] != previousCookies["web_session"])")
                if completionID != confirmedUserID || cookies["web_session"] == previousCookies["web_session"] {
                    let profile = try await call(method: "GET", uri: "/api/sns/web/v2/user/me", body: "")
                    guard userID(in: profile) == confirmedUserID else { throw LoginRequestError.identityMismatch }
                }
                try Task.checkCancellation()
                try saveSession(StoredSession(cookies: cookies, sessionKey: sessionKey))
                authenticated = true
                log("event=login_verified")
                return .authenticated
            } catch {
                cookies = previousCookies
                sessionKey = previousSessionKey
                try? signer.setSessionKey(previousSessionKey)
                throw error
            }
        }
        return loginStatus == .scanned ? .scanned : .waiting
    }

    private func applySession(from value: [String: Any]) {
        let info = value["login_info"] as? [String: Any] ?? [:]
        if let session = (value["session"] as? String) ?? (info["session"] as? String), !session.isEmpty {
            cookies["web_session"] = session
        }
        if let secureSession = (value["secure_session"] as? String) ?? (info["secure_session"] as? String), !secureSession.isEmpty {
            cookies["web_session_sec"] = secureSession
        }
    }

    private func userID(in value: [String: Any]) -> String? {
        let info = value["login_info"] as? [String: Any] ?? value["basic_info"] as? [String: Any] ?? value
        return (info["user_id"] as? String) ?? (info["userid"] as? String) ?? (info["userId"] as? String)
    }

    private func queryURI(path: String, parameters: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(parameters)
        guard let json = String(data: data, encoding: .utf8) else { throw LoginRequestError.malformed }
        var error: NSError?
        let uri = SignerQueryURI(path, json, &error)
        if let error { throw error }
        return uri
    }

    private func call(method: String, uri: String, body: String, extraHeaders: [String: String] = [:], allowEmptyData: Bool = false) async throws -> [String: Any] {
        guard let url = URL(string: "https://edith.xiaohongshu.com" + uri) else { throw FeedError.invalidResponse }
        let xrapPaths: Set<String> = ["/api/sns/web/v1/homefeed", "/api/sns/web/v1/feed", "/api/sns/web/v1/search/notes"]
        let signed: SignedWebRequest
        do { signed = try signer.sign(method: method, uri: uri, body: body, cookies: cookies, xrap: xrapPaths.contains(url.path)) }
        catch {
            log("event=signing_failed")
            throw FeedError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "POST" { request.httpBody = Data(signed.body.utf8) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.xiaohongshu.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; "), forHTTPHeaderField: "Cookie")
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let raw: Data
        let response: URLResponse
        do { (raw, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            log("event=network_failure")
            throw LoginRequestError.network
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw LoginRequestError.malformed }
        guard (200..<300).contains(response.statusCode) else {
            log("event=http_error status=\(response.statusCode) endpoint=\(url.path)")
            throw LoginRequestError.http(response.statusCode)
        }
        let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) { output, element in
            if let key = element.key as? String, let value = element.value as? String { output[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url) where cookie.domain.hasSuffix("xiaohongshu.com") {
            cookies[cookie.name] = cookie.value
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            log("event=invalid_json endpoint=\(url.path)")
            throw LoginRequestError.malformed
        }
        guard envelope["success"] as? Bool == true else {
            let code = envelope["code"] as? Int ?? -1
            let category = errorCategory((envelope["msg"] as? String) ?? (envelope["message"] as? String) ?? "")
            log("event=api_error endpoint=\(url.path) code=\(code) category=\(category)")
            throw LoginRequestError.api(code)
        }
        if allowEmptyData, envelope["data"] == nil || envelope["data"] is NSNull { return [:] }
        guard let data = envelope["data"] as? [String: Any] else {
            log("event=missing_data endpoint=\(url.path)")
            throw LoginRequestError.malformed
        }
        return data
    }
}
