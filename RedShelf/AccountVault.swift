import Foundation

enum ServiceRegion: String, Codable {
    case xiaohongshu, rednote
}

struct StoredSession: Codable, Equatable {
    let cookies: [String: String]
    let sessionKey: Data?
    let region: ServiceRegion

    init(cookies: [String: String], sessionKey: Data?, region: ServiceRegion = .xiaohongshu) {
        self.cookies = cookies
        self.sessionKey = sessionKey
        self.region = region
    }
}

struct SavedAccount: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var session: StoredSession
}

private func validSession(_ session: StoredSession) -> Bool {
    ["a1", "webId", "web_session"].allSatisfy { session.cookies[$0]?.isEmpty == false }
}

struct AccountVault: Codable, Equatable {
    private(set) var accounts: [SavedAccount] = []
    private(set) var activeID: String?

    var active: SavedAccount? { accounts.first { $0.id == activeID } }

    init() {}

    private enum CodingKeys: String, CodingKey { case accounts, activeID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([SavedAccount].self, forKey: .accounts)
        let active = try container.decodeIfPresent(String.self, forKey: .activeID)
        guard decoded.allSatisfy({ !$0.id.isEmpty && validSession($0.session) }),
              Set(decoded.map(\.id)).count == decoded.count,
              active == nil || decoded.contains(where: { $0.id == active }) else { throw FeedError.invalidResponse }
        accounts = decoded
        activeID = active
    }

    mutating func save(_ account: SavedAccount) throws {
        guard !account.id.isEmpty, validSession(account.session) else { throw FeedError.invalidResponse }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        activeID = account.id
    }

    mutating func activate(id: String) throws -> StoredSession {
        guard let account = accounts.first(where: { $0.id == id }) else { throw FeedError.unavailable }
        activeID = id
        return account.session
    }

    mutating func rename(id: String, to name: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw FeedError.unavailable }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeedError.invalidResponse }
        accounts[index].name = trimmed
    }

    mutating func remove(id: String) {
        accounts.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }
}
