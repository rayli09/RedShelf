import Foundation

struct FeedNote: Identifiable, Equatable {
    let id: String
    let title: String
    let author: String
    let cover: URL?
    let avatar: URL?
    let likes: String
    let isVideo: Bool
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
}

enum FeedParser {
    static func parse(_ html: String) throws -> [FeedNote] {
        guard let start = html.range(of: "window.__INITIAL_STATE__"),
              let equal = html.range(of: "=", range: start.upperBound..<html.endIndex),
              let end = html.range(of: "</script>", range: equal.upperBound..<html.endIndex) else { throw FeedError.invalidResponse }
        var raw = String(html[equal.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasSuffix(";") { raw.removeLast() }
        raw = normalizeUndefined(in: raw)
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = root["feed"] as? [String: Any], let items = feed["feeds"] as? [[String: Any]] else { throw FeedError.invalidResponse }
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
                            isVideo: card["type"] as? String == "video")
        }
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
