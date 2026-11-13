import Foundation

struct FeedNote: Identifiable, Equatable {
    let id: String
    let title: String
    let author: String
    let cover: URL?
    let avatar: URL?
    let likes: String
    let isVideo: Bool
    let accessToken: String
    let source: String
}

struct NoteDetail {
    let title: String
    let description: String
    let author: String
    let images: [URL]
    let video: URL?
    let liked: Bool?
    let collected: Bool?
    let likeCount: String
    let commentCount: String
}

struct NoteComment: Identifiable, Equatable {
    let id: String
    let author: String
    let avatar: URL?
    let content: String
    let likes: String
}

struct CommentPage {
    let comments: [NoteComment]
    let cursor: String
    let hasMore: Bool
}

struct SearchPage {
    let notes: [FeedNote]
    let hasMore: Bool
}

enum QRLoginStatus: Equatable {
    case waiting, scanned, confirmed, expired

    init(code: Int) throws {
        switch code {
        case 0: self = .waiting
        case 1: self = .scanned
        case 2: self = .confirmed
        case 3: self = .expired
        default: throw FeedError.invalidResponse
        }
    }
}

enum FeedError: LocalizedError {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "小红书暂未返回推荐内容，可能需要登录。"
        case .invalidResponse: return "无法读取推荐内容，请稍后重试。"
        }
    }
}

struct FeedService {
    func fetch() async throws -> [FeedNote] {
        var request = URLRequest(url: URL(string: "https://www.xiaohongshu.com/explore")!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let html = String(data: data, encoding: .utf8) else { throw FeedError.invalidResponse }
        let notes = try FeedParser.parse(html)
        guard !notes.isEmpty else { throw FeedError.unavailable }
        return notes
    }

    func detail(for note: FeedNote) async throws -> NoteDetail {
        guard !note.accessToken.isEmpty else { throw FeedError.unavailable }
        var components = URLComponents(string: "https://www.xiaohongshu.com/explore/\(note.id)")!
        components.queryItems = [URLQueryItem(name: "xsec_token", value: note.accessToken), URLQueryItem(name: "xsec_source", value: note.source)]
        guard let url = components.url else { throw FeedError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let html = String(data: data, encoding: .utf8) else { throw FeedError.invalidResponse }
        return try FeedParser.parseDetail(html, id: note.id)
    }
}

enum FeedParser {
    static func parseComments(_ result: [String: Any]) throws -> CommentPage {
        guard let comments = result["comments"] as? [[String: Any]] else { throw FeedError.invalidResponse }
        let parsed = comments.compactMap { comment -> NoteComment? in
            guard let id = comment["id"] as? String, !id.isEmpty else { return nil }
            let user = comment["user_info"] as? [String: Any] ?? [:]
            let count = comment["like_count"]
            return NoteComment(id: id, author: user["nickname"] as? String ?? "",
                               avatar: (user["image"] as? String).flatMap(URL.init(string:)),
                               content: comment["content"] as? String ?? "",
                               likes: (count as? String) ?? (count as? NSNumber)?.stringValue ?? "")
        }
        return CommentPage(comments: parsed, cursor: result["cursor"] as? String ?? "",
                           hasMore: result["has_more"] as? Bool ?? false)
    }

    static func parseAPIDetail(_ result: [String: Any]) throws -> NoteDetail {
        guard let items = result["items"] as? [[String: Any]],
              let note = items.first?["note_card"] as? [String: Any] else { throw FeedError.invalidResponse }
        let user = note["user"] as? [String: Any] ?? [:]
        let images = (note["image_list"] as? [[String: Any]] ?? []).compactMap { image in
            ((image["url_default"] as? String) ?? (image["url"] as? String)).flatMap(URL.init(string:))
        }
        let video = note["video"] as? [String: Any]
        let media = video?["media"] as? [String: Any]
        let streams = media?["stream"] as? [String: Any]
        let h264 = streams?["h264"] as? [[String: Any]] ?? []
        let h265 = streams?["h265"] as? [[String: Any]] ?? []
        let videoURL = ((h264.first ?? h265.first)?["master_url"] as? String).flatMap(URL.init(string:))
        let interactions = note["interact_info"] as? [String: Any] ?? [:]
        return NoteDetail(title: note["title"] as? String ?? "", description: note["desc"] as? String ?? "",
                          author: user["nickname"] as? String ?? "", images: images, video: videoURL,
                          liked: interactions["liked"] as? Bool, collected: interactions["collected"] as? Bool,
                          likeCount: countString(interactions["liked_count"]), commentCount: countString(interactions["comment_count"]))
    }

    static func parseHomeFeed(_ result: [String: Any], source: String = "pc_feed") throws -> [FeedNote] {
        guard let items = result["items"] as? [[String: Any]] else { throw FeedError.invalidResponse }
        return items.compactMap { item in
            guard let card = item["note_card"] as? [String: Any],
                  let id = (item["id"] as? String) ?? (card["note_id"] as? String), !id.isEmpty else { return nil }
            let user = card["user"] as? [String: Any] ?? [:]
            let cover = card["cover"] as? [String: Any] ?? [:]
            let interaction = card["interact_info"] as? [String: Any] ?? [:]
            let count = interaction["liked_count"]
            let likes = (count as? String) ?? (count as? NSNumber)?.stringValue ?? ""
            return FeedNote(id: id,
                            title: (card["title"] as? String) ?? (card["display_title"] as? String) ?? "无标题",
                            author: user["nickname"] as? String ?? "",
                            cover: ((cover["url_default"] as? String) ?? (cover["url"] as? String)).flatMap(URL.init(string:)),
                            avatar: (user["avatar"] as? String).flatMap(URL.init(string:)),
                            likes: likes,
                            isVideo: card["type"] as? String == "video",
                            accessToken: (item["xsec_token"] as? String) ?? (card["xsec_token"] as? String) ?? "", source: source)
        }
    }

    static func parse(_ html: String) throws -> [FeedNote] {
        let root = try state(html)
        guard let feed = root["feed"] as? [String: Any], let items = feed["feeds"] as? [[String: Any]] else { throw FeedError.invalidResponse }
        return items.compactMap { item in
            guard let card = item["noteCard"] as? [String: Any],
                  let id = (item["id"] as? String) ?? (card["noteId"] as? String), !id.isEmpty else { return nil }
            let user = card["user"] as? [String: Any] ?? [:]
            let cover = card["cover"] as? [String: Any] ?? [:]
            let interactions = card["interactInfo"] as? [String: Any] ?? [:]
            return FeedNote(id: id, title: card["displayTitle"] as? String ?? "无标题",
                            author: (user["nickname"] as? String) ?? (user["nickName"] as? String) ?? "",
                            cover: ((cover["urlDefault"] as? String) ?? (cover["url"] as? String)).flatMap(URL.init(string:)),
                            avatar: (user["avatar"] as? String).flatMap(URL.init(string:)),
                            likes: interactions["likedCount"] as? String ?? "",
                            isVideo: card["type"] as? String == "video", accessToken: item["xsecToken"] as? String ?? "", source: "pc_feed")
        }
    }

    static func parseDetail(_ html: String, id: String) throws -> NoteDetail {
        let root = try state(html)
        guard let container = root["note"] as? [String: Any],
              let details = container["noteDetailMap"] as? [String: Any],
              let entry = details[id] as? [String: Any], let note = entry["note"] as? [String: Any] else { throw FeedError.unavailable }
        let user = note["user"] as? [String: Any] ?? [:]
        let images = (note["imageList"] as? [[String: Any]] ?? []).compactMap { image in
            ((image["urlDefault"] as? String) ?? (image["url"] as? String)).flatMap(URL.init(string:))
        }
        let video = note["video"] as? [String: Any]
        let media = video?["media"] as? [String: Any]
        let streams = media?["stream"] as? [String: Any]
        let h264 = streams?["h264"] as? [[String: Any]] ?? []
        let videoURL = (h264.first?["masterUrl"] as? String).flatMap(URL.init(string:))
        let interactions = note["interactInfo"] as? [String: Any] ?? [:]
        return NoteDetail(title: note["title"] as? String ?? "", description: note["desc"] as? String ?? "",
                          author: (user["nickname"] as? String) ?? (user["nickName"] as? String) ?? "", images: images, video: videoURL,
                          liked: interactions["liked"] as? Bool, collected: interactions["collected"] as? Bool,
                          likeCount: countString(interactions["likedCount"]), commentCount: countString(interactions["commentCount"]))
    }

    private static func countString(_ value: Any?) -> String {
        (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
    }

    private static func state(_ html: String) throws -> [String: Any] {
        guard let start = html.range(of: "window.__INITIAL_STATE__"),
              let equal = html.range(of: "=", range: start.upperBound..<html.endIndex),
              let end = html.range(of: "</script>", range: equal.upperBound..<html.endIndex) else { throw FeedError.invalidResponse }
        var raw = String(html[equal.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasSuffix(";") { raw.removeLast() }
        raw = normalizeUndefined(in: raw)
        guard let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw FeedError.invalidResponse }
        return root
    }

    private static func normalizeUndefined(in input: String) -> String {
        var output = ""
        var index = input.startIndex
        var inString = false
        var escaped = false
        while index < input.endIndex {
            let character = input[index]
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index = input.index(after: index)
            } else if character == "\"" {
                inString = true
                output.append(character)
                index = input.index(after: index)
            } else if input[index...].hasPrefix("undefined") {
                output += "null"
                index = input.index(index, offsetBy: 9)
            } else {
                output.append(character)
                index = input.index(after: index)
            }
        }
        return output
    }
}
