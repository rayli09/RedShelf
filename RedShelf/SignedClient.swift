import Foundation
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
    case malformed

    var errorDescription: String? {
        switch self {
        case let .http(status): return "服务器返回 HTTP \(status)"
        case let .api(code): return "小红书返回错误 \(code)"
        case .malformed: return "服务器返回了无法识别的数据"
        }
    }
}

private enum SecureSession {
    private static let service = "com.rayli.redshelf.session"
    static func load() -> [String: String]? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "active",
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    static func save(_ cookies: [String: String]) throws {
        let data = try JSONEncoder().encode(cookies)
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
    private var cookies: [String: String]
    private var authenticated: Bool

    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: RestrictedRedirects(), delegateQueue: nil)
        if let saved = SecureSession.load(), saved["web_session"] != nil {
            cookies = saved
            authenticated = true
        } else {
            var error: NSError?
            let value = SignerNewSession(&error)
            if let error { throw error }
            let data = Data(value.utf8)
            cookies = try JSONDecoder().decode([String: String].self, from: data)
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
        guard let items = result["items"] as? [[String: Any]] else { throw FeedError.invalidResponse }
        return items.compactMap { item in
            guard let card = item["note_card"] as? [String: Any],
                  let id = (card["note_id"] as? String) ?? (item["id"] as? String), !id.isEmpty else { return nil }
            let user = card["user"] as? [String: Any] ?? [:]
            let cover = card["cover"] as? [String: Any] ?? [:]
            let interaction = card["interact_info"] as? [String: Any] ?? [:]
            return FeedNote(id: id, title: card["display_title"] as? String ?? "无标题",
                            author: user["nickname"] as? String ?? "",
                            cover: (cover["url_default"] as? String).flatMap(URL.init(string:)),
                            avatar: (user["avatar"] as? String).flatMap(URL.init(string:)),
                            likes: interaction["liked_count"] as? String ?? "",
                            isVideo: card["type"] as? String == "video",
                            accessToken: (card["xsec_token"] as? String) ?? (item["xsec_token"] as? String) ?? "")
        }
    }

    func beginLogin() async throws -> LoginChallenge {
        if !authenticated, let guest = try? await call(method: "POST", uri: "/api/sns/web/v1/login/activate", body: "{}") {
            applySession(from: guest)
        }
        let data = try await call(method: "POST", uri: "/api/sns/web/v1/login/qrcode/create", body: "{\"qr_type\":1}")
        guard let id = data["qr_id"] as? String, let code = data["code"] as? String,
              let value = data["url"] as? String, let url = URL(string: value),
              url.scheme == "xhsdiscover" || (url.scheme == "https" && url.host?.hasSuffix(".xiaohongshu.com") == true) else { throw FeedError.invalidResponse }
        return LoginChallenge(id: id, code: code, url: url)
    }

    func checkLogin(_ challenge: LoginChallenge) async throws -> LoginProgress {
        let raw = try JSONSerialization.data(withJSONObject: ["qrId": challenge.id, "code": challenge.code], options: [.sortedKeys])
        guard let body = String(data: raw, encoding: .utf8) else { throw LoginRequestError.malformed }
        let data = try await call(method: "POST", uri: "/api/qrcode/userinfo", body: body, extraHeaders: ["service-tag": "webcn"])
        guard let status = data["codeStatus"] as? Int else { throw LoginRequestError.malformed }
        let loginStatus = try QRLoginStatus(code: status)
        if loginStatus == .expired { throw FeedError.unavailable }
        if loginStatus == .confirmed {
            guard let confirmedUserID = data["userId"] as? String, !confirmedUserID.isEmpty else { throw LoginRequestError.malformed }
            let previousCookies = cookies
            do {
                var parts = URLComponents()
                parts.path = "/api/sns/web/v1/login/qrcode/status"
                parts.queryItems = [URLQueryItem(name: "code", value: challenge.code), URLQueryItem(name: "qr_id", value: challenge.id)]
                guard let uri = parts.string else { throw LoginRequestError.malformed }
                let completion = try await call(method: "GET", uri: uri, body: "")
                applySession(from: completion)
                guard cookies["web_session"] != nil else { throw LoginRequestError.malformed }
                let completionID = userID(in: completion)
                if completionID != confirmedUserID || cookies["web_session"] == previousCookies["web_session"] {
                    let profile = try await call(method: "GET", uri: "/api/sns/web/v2/user/me", body: "")
                    guard userID(in: profile) == confirmedUserID else { throw LoginRequestError.malformed }
                }
                try SecureSession.save(cookies)
                authenticated = true
                return .authenticated
            } catch {
                cookies = previousCookies
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

    private func call(method: String, uri: String, body: String, extraHeaders: [String: String] = [:]) async throws -> [String: Any] {
        guard let url = URL(string: "https://edith.xiaohongshu.com" + uri) else { throw FeedError.invalidResponse }
        let encodedCookies = try JSONEncoder().encode(cookies)
        guard let encodedString = String(data: encodedCookies, encoding: .utf8) else { throw FeedError.invalidResponse }
        var signingError: NSError?
        let signed = SignerHeaders(method, uri, body, encodedString, &signingError)
        if let signingError { throw signingError }
        let headers = try JSONDecoder().decode([String: String].self, from: Data(signed.utf8))
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !body.isEmpty { request.httpBody = Data(body.utf8) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.xiaohongshu.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; "), forHTTPHeaderField: "Cookie")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (raw, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LoginRequestError.malformed }
        guard (200..<300).contains(response.statusCode) else { throw LoginRequestError.http(response.statusCode) }
        let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) { output, element in
            if let key = element.key as? String, let value = element.value as? String { output[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url) where cookie.domain.hasSuffix("xiaohongshu.com") {
            cookies[cookie.name] = cookie.value
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw LoginRequestError.malformed }
        guard envelope["success"] as? Bool == true else { throw LoginRequestError.api(envelope["code"] as? Int ?? -1) }
        guard let data = envelope["data"] as? [String: Any] else { throw LoginRequestError.malformed }
        return data
    }
}
