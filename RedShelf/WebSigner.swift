import Foundation
import JavaScriptCore
import Security

struct SignedWebRequest {
    let headers: [String: String]
    let body: String
}

/// A private JavaScriptCore context, owned and called exclusively by SignedClient.
/// The bundled signer has no network bridge; only secure random bytes are exposed.
final class WebSigner {
    private let context: JSContext

    init(scriptURL: URL? = nil) throws {
        guard let context = JSContext(),
              let url = scriptURL ?? Bundle.main.url(forResource: "WebSigner", withExtension: "js") else { throw FeedError.invalidResponse }
        self.context = context
        let random: @convention(block) (Int) -> [NSNumber]? = { count in
            guard count >= 0, count <= 1_000_000 else { return nil }
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
            return bytes.map { NSNumber(value: $0) }
        }
        context.setObject(random, forKeyedSubscript: "__secureRandom" as NSString)
        context.exceptionHandler = { _, _ in /* Never log signing input or JavaScript exceptions. */ }
        let bootstrap = #"""
        globalThis.window=globalThis;
        globalThis.navigator={userAgent:"Mozilla/5.0",platform:"Win32",language:"en-US",languages:["en-US"],hardwareConcurrency:8};
        globalThis.crypto={getRandomValues:function(a){const b=__secureRandom(a.length);if(!b||b.length!==a.length)throw new Error("Secure random unavailable");for(let i=0;i<a.length;i++)a[i]=b[i];return a;}};
        globalThis.performance={now:()=>Date.now()};
        """#
        context.evaluateScript(bootstrap)
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        guard context.exception == nil, context.objectForKeyedSubscript("signRequest")?.isObject == true else { throw FeedError.invalidResponse }
    }

    func sign(method: String, uri: String, body: String, cookies: [String: String], xrap: Bool) throws -> SignedWebRequest {
        guard let components = URLComponents(string: uri), !components.path.isEmpty else { throw FeedError.invalidResponse }
        let payload: String
        if method == "GET" {
            var values: [String: String] = [:]
            for field in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                guard !name.isEmpty, values[name] == nil else { throw FeedError.invalidResponse }
                values[name] = parts.count == 2 ? String(parts[1]) : ""
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            payload = String(decoding: try encoder.encode(values), as: UTF8.self)
        } else {
            payload = body.isEmpty ? "{}" : body
        }
        let cookieJSON = String(decoding: try JSONEncoder().encode(cookies), as: UTF8.self)
        context.exception = nil
        guard let value = context.objectForKeyedSubscript("signRequest")?.call(withArguments: [method, components.path, payload, cookieJSON, xrap]),
              context.exception == nil, let json = value.toString(), let data = json.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headers = result["headers"] as? [String: String], let signedBody = result["body"] as? String else { throw FeedError.invalidResponse }
        return SignedWebRequest(headers: headers, body: signedBody)
    }

    func setSessionKey(_ value: Data?) throws {
        context.exception = nil
        context.objectForKeyedSubscript("setSessionKey")?.call(withArguments: [value?.base64EncodedString() ?? ""])
        guard context.exception == nil else { throw FeedError.invalidResponse }
    }

    func newSearchID() throws -> String {
        context.exception = nil
        guard let value = context.objectForKeyedSubscript("newSearchID")?.call(withArguments: [])?.toString(),
              context.exception == nil, !value.isEmpty else { throw FeedError.invalidResponse }
        return value
    }
}
