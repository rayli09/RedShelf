import Foundation
import CoreFoundation
import Security
import Signer

struct LoginChallenge {
    let id: String
    let code: String
    let url: URL
}

enum LoginProgress { case waiting, scanned, authenticated }

private enum LoginRequestError: LocalizedError {
    case http(Int)
    case api(Int)
    case risk(Int)
    case malformed
    case expired
    case completion(String?)
    case identityMismatch
    case network

    var errorDescription: String? {
        switch self {
        case let .http(status): return "服务器返回 HTTP \(status)"
        case let .api(code): return "小红书返回错误 \(code)"
        case let .risk(code): return "小红书提示安全限制（错误 \(code)），请检查官方登录页"
        case .malformed: return "服务器返回了无法识别的数据"
        case .expired: return "二维码已过期，请重新生成"
        case let .completion(reason):
            return reason.map { "手机确认后无法建立登录会话：\($0)" } ?? "手机确认后无法建立登录会话，请重试"
        case .identityMismatch: return "无法验证登录账号，请重试"
        case .network: return "无法连接小红书，请检查网络"
        }
    }
}

struct SecureSession {
    private let service: String

    init(service: String = "com.rayli.redshelf.session") { self.service = service }

    func load() throws -> AccountVault? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "regional-accounts",
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw FeedError.invalidResponse }
        return try JSONDecoder().decode(AccountVault.self, from: data)
    }

    func save(_ vault: AccountVault) throws {
        let data = try JSONEncoder().encode(vault)
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: "regional-accounts"]
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw FeedError.invalidResponse }
        } else if status != errSecSuccess { throw FeedError.invalidResponse }
    }

    #if DEBUG
    func removeForTesting() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "regional-accounts"]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FeedError.invalidResponse }
    }
    #endif
}

private final class RestrictedRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", let host = request.url?.host,
              host == task.originalRequest?.url?.host,
              ["edith.xiaohongshu.com", "www.xiaohongshu.com", "live-room.xiaohongshu.com", "webapi.rednote.com"].contains(host) else {
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
    private let saveVault: (AccountVault) throws -> Void
    private var vault: AccountVault
    private let sessionKeyServerPublicKey: Data?
    private var cookies: [String: String]
    private var sessionKey: Data?
    private var region: ServiceRegion = .xiaohongshu
    private var authenticated: Bool
    private var lastLoggedQRStatus: Int?
    private var sessionGeneration = 0

    // These diagnostics intentionally contain no request bodies, URLs with
    // query strings, account identifiers, cookies, signatures, or QR values.
    private func log(_ event: String) {
        print("[RedShelf.Auth] \(event)")
    }

    private func errorCategory(_ message: String) -> String {
        let text = message.lowercased()
        if text.contains("sign") || text.contains("签名") { return "signature" }
        if text.contains("expired") || text.contains("过期") { return "expired" }
        if text.contains("risk") || text.contains("风控") || text.contains("安全限制") { return "risk" }
        if text.contains("验证") || text.contains("verification") { return "verification" }
        if text.contains("login") || text.contains("登录") { return "login" }
        return "other"
    }

    init(session suppliedSession: URLSession? = nil,
         initialCookies: [String: String]? = nil,
         initialVault: AccountVault? = nil,
         saveVault: ((AccountVault) throws -> Void)? = nil,
         signerScriptURL: URL? = nil,
         sessionKeyServerPublicKey: Data? = nil) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = suppliedSession ?? URLSession(configuration: configuration, delegate: RestrictedRedirects(), delegateQueue: nil)
        signer = try WebSigner(scriptURL: signerScriptURL)
        let secureSession = SecureSession()
        self.saveVault = saveVault ?? secureSession.save
        if let initialVault { vault = initialVault }
        else if initialCookies == nil { vault = try secureSession.load() ?? AccountVault() }
        else { vault = AccountVault() }
        self.sessionKeyServerPublicKey = sessionKeyServerPublicKey
        if let initialCookies {
            cookies = initialCookies
            sessionKey = nil
            authenticated = false
        } else if let saved = vault.active?.session {
            cookies = saved.cookies
            sessionKey = saved.sessionKey
            region = saved.region
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

    var accounts: [(id: String, name: String, isActive: Bool)] {
        vault.accounts.map { ($0.id, $0.name, authenticated && $0.id == vault.activeID) }
    }

    func beginAddingAccount() throws {
        var error: NSError?
        let raw = SignerNewSession(&error)
        if let error { throw error }
        let fresh = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        try signer.setSessionKey(nil)
        sessionGeneration += 1
        cookies = fresh
        sessionKey = nil
        region = .xiaohongshu
        authenticated = false
        lastLoggedQRStatus = nil
    }

    func switchAccount(id: String) throws {
        var next = vault
        let stored = try next.activate(id: id)
        try signer.setSessionKey(stored.sessionKey)
        do { try saveVault(next) }
        catch { try? signer.setSessionKey(sessionKey); throw error }
        sessionGeneration += 1
        vault = next
        cookies = stored.cookies
        sessionKey = stored.sessionKey
        region = stored.region
        authenticated = true
    }

    func profile() async throws -> UserProfile {
        guard authenticated else { throw FeedError.unavailable }
        let profile = try FeedParser.parseUserProfile(await call(method: "GET", uri: "/api/sns/web/v2/user/me", body: ""))
        guard profile.id == vault.activeID else { throw LoginRequestError.identityMismatch }
        if let active = vault.active, !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           active.name != profile.name {
            var next = vault
            try next.rename(id: profile.id, to: profile.name)
            do { try saveVault(next); vault = next }
            catch { log("event=account_name_save_failed") }
        }
        return profile
    }

    func profileDetails(_ base: UserProfile) async throws -> UserProfile {
        guard authenticated, base.id == vault.activeID else { throw FeedError.unavailable }
        let uri = try queryURI(path: "/api/sns/web/v1/user/otherinfo", parameters: ["target_user_id": base.id])
        let result = try await call(method: "GET", uri: uri, body: "")
        guard authenticated, base.id == vault.activeID else { throw CancellationError() }
        return try FeedParser.parseProfileDetails(result, base: base)
    }

    func userNotes(_ collection: UserNoteCollection, userID: String, cursor: String = "") async throws -> UserNotePage {
        guard authenticated, !userID.isEmpty, userID == vault.activeID else { throw FeedError.unavailable }
        var parameters = ["user_id": userID, "num": "30", "cursor": cursor]
        if collection == .posted { parameters["image_formats"] = "jpg,webp,avif" }
        let uri = try queryURI(path: collection.path, parameters: parameters)
        return try FeedParser.parseUserNotes(await call(method: "GET", uri: uri, body: ""))
    }

    func publicUserNotes(user: SearchUser, cursor: String = "") async throws -> UserNotePage {
        guard authenticated, !user.id.isEmpty else { throw FeedError.unavailable }
        var parameters = ["user_id": user.id, "num": "30", "cursor": cursor, "image_formats": "jpg,webp,avif"]
        if !user.token.isEmpty { parameters["xsec_token"] = user.token; parameters["xsec_source"] = "pc_search" }
        let uri = try queryURI(path: "/api/sns/web/v1/user_posted", parameters: parameters)
        return try FeedParser.parseUserNotes(await call(method: "GET", uri: uri, body: ""))
    }

    func signOut() throws {
        guard authenticated else { throw FeedError.unavailable }
        var error: NSError?
        let value = SignerNewSession(&error)
        if let error { throw error }
        let freshCookies = try JSONDecoder().decode([String: String].self, from: Data(value.utf8))
        var next = vault
        if let id = next.activeID { next.remove(id: id) }
        try signer.setSessionKey(nil)
        do { try saveVault(next) }
        catch {
            try? signer.setSessionKey(sessionKey)
            throw error
        }
        sessionGeneration += 1
        vault = next
        cookies = freshCookies
        sessionKey = nil
        region = .xiaohongshu
        authenticated = false
        lastLoggedQRStatus = nil
        log("event=local_session_cleared")
    }

    func homeFeed(cursor: String = "", noteIndex: Int = 0) async throws -> RecommendationPage {
        guard authenticated, noteIndex >= 0 else { throw FeedError.unavailable }
        let payload: [String: Any] = ["cursor_score": cursor, "num": 40, "refresh_type": cursor.isEmpty ? 1 : 3,
                                      "note_index": noteIndex, "unread_begin_note_id": "", "unread_end_note_id": "",
                                      "unread_note_count": 0, "category": "homefeed_recommend", "search_key": "",
                                      "need_num": 40, "image_scenes": ["FD_PRV_WEBP", "FD_WM_WEBP"]]
        let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let body = String(data: raw, encoding: .utf8) else { throw FeedError.invalidResponse }
        let result = try await call(method: "POST", uri: "/api/sns/web/v1/homefeed", body: body)
        return RecommendationPage(notes: try FeedParser.parseHomeFeed(result), cursor: result["cursor_score"] as? String ?? "")
    }

    func liveRooms() async throws -> [LiveRoom] {
        guard authenticated, region == .xiaohongshu else { throw FeedError.unavailable }
        let uri = try queryURI(path: "/api/sns/red/live/web/feed/v1/squarefeed", parameters: [
            "source": "13", "category": "", "pre_source": "", "extra_info": "{\"image_formats\":[\"jpg\",\"webp\",\"avif\"]}", "size": "27"
        ])
        return try FeedParser.parseLiveList(await call(method: "GET", uri: uri, body: "", extraHeaders: ["xy-common-params": "platform=web"], liveOrigin: true))
    }

    func liveStream(roomID: String) async throws -> URL {
        guard authenticated, region == .xiaohongshu, !roomID.isEmpty, roomID.allSatisfy(\.isNumber),
              let url = URL(string: "https://www.xiaohongshu.com/livestream/\(roomID)") else { throw FeedError.unavailable }
        let current = sessionGeneration
        var request = URLRequest(url: url)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard current == sessionGeneration else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url?.host == "www.xiaohongshu.com", data.count <= 4_000_000,
              let html = String(data: data, encoding: .utf8) else { throw FeedError.invalidResponse }
        return try FeedParser.parseLiveStream(html, roomID: roomID)
    }

    func noteDetail(for note: FeedNote) async throws -> NoteDetail {
        guard authenticated else { throw FeedError.unavailable }
        guard !note.accessToken.isEmpty else { throw FeedError.noteUnavailable }
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

    func replies(for note: FeedNote, rootID: String, cursor: String = "") async throws -> CommentPage {
        guard authenticated, !note.accessToken.isEmpty, !rootID.isEmpty else { throw FeedError.unavailable }
        let uri = try queryURI(path: "/api/sns/web/v2/comment/sub/page", parameters: [
            "note_id": note.id, "root_comment_id": rootID, "num": "10", "cursor": cursor,
            "image_formats": "jpg,webp,avif", "top_comment_id": "", "xsec_token": note.accessToken,
        ])
        return try FeedParser.parseComments(await call(method: "GET", uri: uri, body: ""))
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

    func searchUsers(keyword: String, page: Int, searchID: String) async throws -> UserSearchPage {
        guard authenticated, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              page > 0, !searchID.isEmpty else { throw FeedError.invalidResponse }
        let requestID = "\(Int.random(in: 1...2_147_483_646))-\(Int64(Date().timeIntervalSince1970 * 1000))"
        let payload: [String: Any] = ["search_user_request": ["keyword": keyword, "search_id": searchID,
            "page": page, "page_size": 15, "biz_type": "web_search_user", "request_id": requestID]]
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let body = String(data: bytes, encoding: .utf8) else { throw FeedError.invalidResponse }
        return try FeedParser.parseUserSearch(await call(method: "POST", uri: "/api/sns/web/v1/search/usersearch", body: body))
    }

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
            try await activateGuest()
        }
        let data = try await call(method: "POST", uri: "/api/sns/web/v1/login/qrcode/create", body: "{\"qr_type\":1}")
        guard let id = data["qr_id"] as? String, let code = data["code"] as? String,
              let value = data["url"] as? String, let url = URL(string: value),
              url.scheme == "xhsdiscover" || (url.scheme == "https" && url.host?.hasSuffix(".xiaohongshu.com") == true) else { throw FeedError.invalidResponse }
        log("event=qr_created")
        return LoginChallenge(id: id, code: code, url: url)
    }

    private func activateGuest() async throws {
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

    func checkLogin(_ challenge: LoginChallenge) async throws -> LoginProgress {
        let previousCookies = cookies
        let previousSessionKey = sessionKey
        let previousRegion = region
        var currentGeneration = sessionGeneration
        let raw = try JSONSerialization.data(withJSONObject: ["qrId": challenge.id, "code": challenge.code], options: [.sortedKeys])
        guard let body = String(data: raw, encoding: .utf8) else { throw LoginRequestError.malformed }
        let data = try await call(method: "POST", uri: "/api/qrcode/userinfo", body: body, extraHeaders: ["service-tag": "webcn"])
        guard let status = data["codeStatus"] as? Int else {
            cookies = previousCookies
            throw LoginRequestError.malformed
        }
        if status != lastLoggedQRStatus {
            log("event=qr_status status=\(status)")
            lastLoggedQRStatus = status
        }
        let loginStatus: QRLoginStatus
        do { loginStatus = try QRLoginStatus(code: status) }
        catch { cookies = previousCookies; throw error }
        if loginStatus == .expired { cookies = previousCookies; throw LoginRequestError.expired }
        if loginStatus == .confirmed {
            do {
                guard let confirmedUserID = data["userId"] as? String, !confirmedUserID.isEmpty else {
                    log("event=confirmed_missing_user")
                    throw LoginRequestError.malformed
                }
                log("event=confirmation_received")
                let geoZone: Int?
                if let rawRegion = data["geoZone"], !(rawRegion is NSNull) {
                    guard let number = rawRegion as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue == Double(number.intValue) else { throw LoginRequestError.malformed }
                    geoZone = number.intValue
                } else { geoZone = nil }
                if geoZone == 1 || geoZone == 2 {
                    log("event=confirmation_region category=overseas")
                    let webID = cookies["webId"]
                    var error: NSError?
                    let raw = SignerNewSession(&error)
                    if let error { throw error }
                    var fresh = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
                    if let webID, !webID.isEmpty { fresh["webId"] = webID }
                    try signer.setSessionKey(nil)
                    sessionGeneration += 1
                    currentGeneration = sessionGeneration
                    cookies = fresh
                    sessionKey = nil
                    region = .rednote
                    try await activateGuest()
                } else {
                    log("event=confirmation_region category=\(geoZone == 0 ? "domestic" : "unspecified")")
                    applySession(from: data)
                }
                if cookies["web_session"]?.isEmpty == false &&
                    geoZone != 1 && geoZone != 2 &&
                    (geoZone == nil || cookies["web_session"] != previousCookies["web_session"]) {
                    var verified = false
                    do {
                        let profile = try await call(method: "GET", uri: "/api/sns/web/v2/user/me", body: "")
                        let profileID = userID(in: profile)
                        verified = profileID == confirmedUserID
                        log("event=poll_identity_check result=\(verified ? "matched" : profileID == nil ? "guest_or_missing" : "different_account")")
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as LoginRequestError {
                        if case .risk = error { throw error }
                        log("event=poll_identity_check result=request_failed")
                    } catch { log("event=poll_identity_check result=request_failed") }
                    if verified {
                        try Task.checkCancellation()
                        try persistVerifiedSession(userID: confirmedUserID)
                        log("event=login_verified_from_poll")
                        return .authenticated
                    }
                }
                let exchange = try SessionKeyExchange(serverPublicKey: sessionKeyServerPublicKey)
                let sessionBeforeCompletion = cookies["web_session"]
                let uri = try queryURI(path: "/api/sns/web/v1/login/qrcode/status", parameters: [
                    "code": challenge.code, "qr_id": challenge.id,
                    "client_public_key_base64": exchange.publicKeyBase64,
                ])
                let completion: [String: Any]
                var headers: [String: String] = [:]
                if region == .rednote {
                    for (keys, header) in [(["accountGeographicZone", "account_geographic_zone"], "x-rednote-datactry"), (["accountHolderCountry", "account_holder_country"], "x-rednote-holderctry")] {
                        if let value = keys.compactMap({ data[$0] as? String }).first, !value.isEmpty,
                           value.utf8.count <= 32, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) {
                            headers[header] = value
                        }
                    }
                } else { headers["x-login-mode"] = "" }
                do { completion = try await call(method: "GET", uri: uri, body: "", extraHeaders: headers) }
                catch is CancellationError { throw CancellationError() }
                catch let error as LoginRequestError {
                    log("event=completion_request_failed")
                    if case .risk = error { throw error }
                    // The web client checks the resulting login state even when
                    // the completion request fails. Never accept a guest or a
                    // different account as proof of this QR confirmation.
                    var verified = false
                    do {
                        let profile = try await call(method: "GET", uri: "/api/sns/web/v2/user/me", body: "")
                        let profileID = userID(in: profile)
                        verified = profileID == confirmedUserID
                        log("event=completion_identity_check result=\(verified ? "matched" : profileID == nil ? "guest_or_missing" : "different_account")")
                    } catch is CancellationError { throw CancellationError() }
                    catch let verificationError as LoginRequestError {
                        if case .risk = verificationError { throw verificationError }
                        log("event=completion_identity_check result=request_failed")
                    } catch { log("event=completion_identity_check result=request_failed") }
                    if verified {
                        try Task.checkCancellation()
                        try persistVerifiedSession(userID: confirmedUserID)
                        log("event=login_verified_after_completion_error")
                        return .authenticated
                    }
                    throw LoginRequestError.completion(error.errorDescription)
                }
                catch {
                    log("event=completion_request_failed")
                    throw LoginRequestError.completion(nil)
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
                    throw LoginRequestError.completion(nil)
                }
                let completionID = userID(in: completion)
                log("event=completion_received identity_matches=\(completionID == confirmedUserID) session_changed=\(cookies["web_session"] != sessionBeforeCompletion)")
                if completionID != confirmedUserID || cookies["web_session"] == sessionBeforeCompletion {
                    let profile = try await call(method: "GET", uri: "/api/sns/web/v2/user/me", body: "")
                    guard userID(in: profile) == confirmedUserID else { throw LoginRequestError.identityMismatch }
                }
                try Task.checkCancellation()
                try persistVerifiedSession(userID: confirmedUserID)
                log("event=login_verified")
                return .authenticated
            } catch {
                if sessionGeneration == currentGeneration {
                    cookies = previousCookies
                    sessionKey = previousSessionKey
                    region = previousRegion
                    try? signer.setSessionKey(previousSessionKey)
                }
                throw error
            }
        }
        return loginStatus == .scanned ? .scanned : .waiting
    }

    private func persistVerifiedSession(userID: String) throws {
        var next = vault
        let existingName = next.accounts.first { $0.id == userID }?.name
        try next.save(SavedAccount(id: userID, name: existingName ?? "小红书账号 \(next.accounts.count + 1)",
                                   session: StoredSession(cookies: cookies, sessionKey: sessionKey, region: region)))
        try saveVault(next)
        vault = next
        authenticated = true
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
        if value["guest"] as? Bool == true || info["guest"] as? Bool == true { return nil }
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

    private func call(method: String, uri: String, body: String, extraHeaders: [String: String] = [:], allowEmptyData: Bool = false, liveOrigin: Bool = false) async throws -> [String: Any] {
        let currentGeneration = sessionGeneration
        let apiOrigin = liveOrigin ? "https://live-room.xiaohongshu.com" : (region == .rednote ? "https://webapi.rednote.com" : "https://edith.xiaohongshu.com")
        let webOrigin = region == .rednote ? "https://www.rednote.com" : "https://www.xiaohongshu.com"
        guard let url = URL(string: apiOrigin + uri) else { throw FeedError.invalidResponse }
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
        request.setValue(webOrigin, forHTTPHeaderField: "Origin")
        request.setValue(webOrigin + "/", forHTTPHeaderField: "Referer")
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
        guard currentGeneration == sessionGeneration else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw LoginRequestError.malformed }
        guard (200..<300).contains(response.statusCode) else {
            log("event=http_error status=\(response.statusCode) endpoint=\(url.path)")
            if [461, 471].contains(response.statusCode) { throw LoginRequestError.risk(response.statusCode) }
            throw LoginRequestError.http(response.statusCode)
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            log("event=invalid_json endpoint=\(url.path)")
            throw LoginRequestError.malformed
        }
        guard envelope["success"] as? Bool == true else {
            let code = envelope["code"] as? Int ?? -1
            let category = errorCategory((envelope["msg"] as? String) ?? (envelope["message"] as? String) ?? "")
            log("event=api_error endpoint=\(url.path) code=\(code) category=\(category)")
            if [300011, 300012, 300013, 300015, 461, 471].contains(code) || category == "risk" {
                throw LoginRequestError.risk(code)
            }
            throw LoginRequestError.api(code)
        }
        let data: [String: Any]
        if allowEmptyData, envelope["data"] == nil || envelope["data"] is NSNull { data = [:] }
        else if let value = envelope["data"] as? [String: Any] { data = value }
        else {
            log("event=missing_data endpoint=\(url.path)")
            throw LoginRequestError.malformed
        }
        let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) { output, element in
            if let key = element.key as? String, let value = element.value as? String { output[key] = value }
        }
        let cookieDomain = region == .rednote ? "rednote.com" : "xiaohongshu.com"
        let previousCookies = cookies
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url) where cookie.domain == cookieDomain || cookie.domain.hasSuffix("." + cookieDomain) {
            cookies[cookie.name] = cookie.value
        }
        if authenticated, cookies != previousCookies, var account = vault.active {
            account.session = StoredSession(cookies: cookies, sessionKey: sessionKey, region: region)
            var next = vault
            do {
                try next.save(account)
                vault = next
                do { try saveVault(next) }
                catch { log("event=account_session_save_failed") }
            } catch { log("event=account_session_invalid") }
        }
        return data
    }
}
