import Foundation
import CoreFoundation

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
    let replyCount: String

    init(id: String, author: String, avatar: URL?, content: String, likes: String, replyCount: String = "") {
        self.id = id; self.author = author; self.avatar = avatar; self.content = content; self.likes = likes; self.replyCount = replyCount
    }
}

struct CommentPage {
    let comments: [NoteComment]
    let cursor: String
    let hasMore: Bool

    func merging(with existing: [NoteComment], previousCursor: String) -> (comments: [NoteComment], hasMore: Bool) {
        var seen = Set(existing.map(\.id))
        let fresh = comments.filter { seen.insert($0.id).inserted }
        return (existing + fresh, hasMore && !cursor.isEmpty && cursor != previousCursor && !fresh.isEmpty)
    }
}

struct SearchPage {
    let notes: [FeedNote]
    let hasMore: Bool
}

struct SearchUser: Identifiable {
    let id: String
    let name: String
    let redID: String
    let avatar: URL?
    let token: String
}

struct UserSearchPage {
    let users: [SearchUser]
    let hasMore: Bool
}

struct RecommendationPage {
    let notes: [FeedNote]
    let cursor: String
}

struct UserProfile {
    let id: String
    let name: String
    let redID: String
    let avatar: URL?
    let biography: String
    let following: String?
    let followers: String?
    let likes: String?

    init(id: String, name: String, redID: String, avatar: URL? = nil, biography: String = "",
         following: String? = nil, followers: String? = nil, likes: String? = nil) {
        self.id = id; self.name = name; self.redID = redID; self.avatar = avatar; self.biography = biography
        self.following = following; self.followers = followers; self.likes = likes
    }
}

struct UserNotePage {
    let notes: [FeedNote]
    let cursor: String
    let hasMore: Bool
}

struct LiveRoom: Identifiable {
    let id: String
    let title: String
    let host: String
    let cover: URL?
    let viewers: String
}

enum UserNoteCollection: String, CaseIterable {
    case posted = "我的笔记", liked = "我的点赞", collected = "我的收藏"
    var path: String {
        switch self {
        case .posted: return "/api/sns/web/v1/user_posted"
        case .liked: return "/api/sns/web/v1/note/like/page"
        case .collected: return "/api/sns/web/v2/note/collect/page"
        }
    }
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
    case liveUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "小红书暂未返回推荐内容，可能需要登录。"
        case .invalidResponse: return "无法读取推荐内容，请稍后重试。"
        case .liveUnavailable: return "直播已结束、受限或没有可播放的 HLS 视频。"
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
                               likes: (count as? String) ?? (count as? NSNumber)?.stringValue ?? "",
                               replyCount: countString(comment["sub_comment_count"]))
        }
        return CommentPage(comments: parsed, cursor: result["cursor"] as? String ?? "",
                           hasMore: result["has_more"] as? Bool ?? false)
    }

    static func parseAPIDetail(_ result: [String: Any]) throws -> NoteDetail {
        guard let items = result["items"] as? [[String: Any]],
              let note = items.first?["note_card"] as? [String: Any] else { throw FeedError.invalidResponse }
        let user = note["user"] as? [String: Any] ?? [:]
        let images = (note["image_list"] as? [[String: Any]] ?? []).compactMap(imageURL)
        let video = note["video"] as? [String: Any]
        let media = video?["media"] as? [String: Any]
        let streams = media?["stream"] as? [String: Any]
        let videoURL = ["h264", "EF4", "h265", "EF5"].lazy.flatMap { streams?[$0] as? [[String: Any]] ?? [] }
            .compactMap { stream -> URL? in
                let candidates = [stream["master_url"] as? String, stream["url"] as? String] + (stream["backup_urls"] as? [String] ?? []).map(Optional.some)
                return candidates.compactMap(usableMediaURL).first
            }.first
        let interactions = note["interact_info"] as? [String: Any] ?? [:]
        return NoteDetail(title: note["title"] as? String ?? "", description: note["desc"] as? String ?? "",
                          author: user["nickname"] as? String ?? "", images: images, video: videoURL,
                          liked: interactions["liked"] as? Bool, collected: interactions["collected"] as? Bool,
                          likeCount: countString(interactions["liked_count"]), commentCount: countString(interactions["comment_count"]))
    }

    static func parseHomeFeed(_ result: [String: Any], source: String = "pc_feed") throws -> [FeedNote] {
        guard let items = result["items"] as? [[String: Any]] else { throw FeedError.invalidResponse }
        return items.compactMap { item in
            guard let card = item["note_card"] as? [String: Any] else { return nil }
            let id = [item["id"] as? String, card["note_id"] as? String].compactMap { $0 }.first { !$0.isEmpty }
            guard let id else { return nil }
            let user = card["user"] as? [String: Any] ?? [:]
            let cover = card["cover"] as? [String: Any] ?? [:]
            let interaction = card["interact_info"] as? [String: Any] ?? [:]
            let count = interaction["liked_count"]
            let likes = (count as? String) ?? (count as? NSNumber)?.stringValue ?? ""
            let title = [card["title"] as? String, card["display_title"] as? String].compactMap { $0 }.first { !$0.isEmpty } ?? "无标题"
            let token = [item["xsec_token"] as? String, card["xsec_token"] as? String].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            return FeedNote(id: id,
                            title: title,
                            author: user["nickname"] as? String ?? "",
                            cover: imageURL(cover),
                            avatar: (user["avatar"] as? String).flatMap(URL.init(string:)),
                            likes: likes,
                            isVideo: card["type"] as? String == "video",
                            accessToken: token, source: source)
        }
    }

    private static func usableMediaURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private static func imageURL(_ image: [String: Any]) -> URL? {
        let list = image["info_list"] as? [[String: Any]] ?? []
        let preferred = list.filter { $0["image_scene"] as? String == "WB_DFT" }
        let candidates = (preferred + list).compactMap { $0["url"] as? String } +
            [image["url_default"] as? String, image["url"] as? String].compactMap { $0 }
        return candidates.compactMap { usableMediaURL($0) }.first
    }

    static func parseUserProfile(_ value: [String: Any]) throws -> UserProfile {
        guard value["guest"] as? Bool != true, let id = value["user_id"] as? String, !id.isEmpty else { throw FeedError.unavailable }
        let image = (value["images"] as? String) ?? (value["imageb"] as? String)
        return UserProfile(id: id, name: value["nickname"] as? String ?? "小红书用户", redID: value["red_id"] as? String ?? "",
                           avatar: image.flatMap(URL.init(string:)), biography: value["desc"] as? String ?? "")
    }

    static func parseProfileDetails(_ value: [String: Any], base: UserProfile) throws -> UserProfile {
        guard let basic = value["basic_info"] as? [String: Any] else { throw FeedError.invalidResponse }
        if let id = basic["user_id"] as? String, !id.isEmpty, id != base.id { throw FeedError.invalidResponse }
        let interactions = value["interactions"] as? [[String: Any]] ?? []
        func count(_ type: String) -> String? {
            guard let value = interactions.first(where: { $0["type"] as? String == type })?["count"] else { return nil }
            let result = countString(value)
            return result.isEmpty ? nil : result
        }
        let image = ((basic["imageb"] as? String) ?? (basic["images"] as? String)).flatMap(URL.init(string:))
        return UserProfile(id: base.id, name: (basic["nickname"] as? String) ?? base.name,
                           redID: (basic["red_id"] as? String) ?? base.redID, avatar: image ?? base.avatar,
                           biography: (basic["desc"] as? String) ?? base.biography,
                           following: count("follows"), followers: count("fans"), likes: count("interaction"))
    }

    static func parseUserSearch(_ value: [String: Any]) throws -> UserSearchPage {
        guard let items = value["users"] as? [[String: Any]] else { throw FeedError.invalidResponse }
        let users: [SearchUser] = items.compactMap { item in
            guard let id = [item["id"] as? String, item["user_id"] as? String].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
            return SearchUser(id: id, name: (item["name"] as? String) ?? (item["nickname"] as? String) ?? "小红书用户",
                              redID: item["red_id"] as? String ?? "", avatar: ((item["image"] as? String) ?? (item["avatar"] as? String)).flatMap(URL.init(string:)),
                              token: item["xsec_token"] as? String ?? "")
        }
        return UserSearchPage(users: users, hasMore: value["has_more"] as? Bool ?? false)
    }

    static func parseLiveList(_ value: [String: Any]) throws -> [LiveRoom] {
        guard let feeds = value["feeds"] as? [[String: Any]] else { throw FeedError.invalidResponse }
        return feeds.compactMap { item in
            guard let live = item["live"] as? [String: Any], let room = live["t_room_info"] as? [String: Any] else { return nil }
            let id = (room["room_id_str"] as? String) ?? (room["room_id"] as? NSNumber)?.stringValue ?? ""
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            let host = live["t_live_host_info"] as? [String: Any] ?? [:]
            let coverInfo = room["cover_info"] as? [String: Any] ?? [:]
            let cover = (room["cover"] as? String) ?? (coverInfo["cover_image"] as? String)
            return LiveRoom(id: id, title: room["name"] as? String ?? "直播", host: host["nickname"] as? String ?? "",
                            cover: cover.flatMap(URL.init(string:)), viewers: countString(room["display_count"] ?? room["member_count"]))
        }
    }

    static func parseLiveStream(_ html: String, roomID: String) throws -> URL {
        guard !roomID.isEmpty, roomID.allSatisfy(\.isNumber) else { throw FeedError.invalidResponse }
        let root = try state(html)
        func integer(_ value: Any?) -> Int? {
            if let string = value as? String { return Int(string) }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue) else { return nil }
            return number.intValue
        }
        guard let live = root["liveStream"] as? [String: Any], live["pageStatus"] as? String == "success",
              live["liveStatus"] as? String == "success", let data = live["roomData"] as? [String: Any],
              let room = data["roomInfo"] as? [String: Any], room["roomId"] as? String == roomID,
              integer(room["status"]) == 2, integer(room["monetizeType"]) == 0 else { throw FeedError.liveUnavailable }
        let limits: [Int]?
        if let values = room["joinLimitTypes"] as? [Any] {
            let parsed = values.compactMap { integer($0) }
            limits = parsed.count == values.count ? parsed : nil
        }
        else if let string = room["joinLimitTypes"] as? String, let data = string.data(using: .utf8) { limits = try? JSONDecoder().decode([Int].self, from: data) }
        else { limits = nil }
        guard let limits, limits.allSatisfy({ $0 == 0 }) else { throw FeedError.liveUnavailable }
        let config: [String: Any]?
        if let object = room["pullConfig"] as? [String: Any] { config = object }
        else if let string = room["pullConfig"] as? String, let data = string.data(using: .utf8) { config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        else { config = nil }
        for codec in ["h264", "h265"] {
            for stream in config?[codec] as? [[String: Any]] ?? [] {
                guard let raw = stream["master_url"] as? String, let url = URL(string: raw),
                      let host = url.host?.lowercased(), host.hasSuffix(".xhscdn.com"),
                      url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.fragment == nil,
                      url.port == nil || url.port == 443, url.path == "/live/\(roomID).m3u8" else { continue }
                return url
            }
        }
        throw FeedError.liveUnavailable
    }

    static func parseUserNotes(_ value: [String: Any]) throws -> UserNotePage {
        guard let notes = value["notes"] as? [[String: Any]] else { throw FeedError.invalidResponse }
        let items: [[String: Any]] = notes.map { note in
            if note["note_card"] != nil { return note }
            return ["id": (note["note_id"] as? String) ?? (note["id"] as? String) ?? "", "note_card": note]
        }
        return UserNotePage(notes: try parseHomeFeed(["items": items], source: "pc_user"),
                            cursor: value["cursor"] as? String ?? "", hasMore: value["has_more"] as? Bool ?? false)
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
