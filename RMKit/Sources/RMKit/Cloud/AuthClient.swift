import Foundation

/// Pairing and session tokens. Never retried on 429: the token exchange is
/// rate-limited, and hammering it is what trips the limit.
public struct AuthClient: Sendable {
    let http: HTTP
    let host: URL

    public init(session: URLSession = .shared, host: URL = CloudHosts.auth) {
        http = HTTP(session: session)
        self.host = host
    }

    /// Exchange the 8-letter code from my.remarkable.com for a device token,
    /// which never expires.
    public func register(code: String, deviceID: UUID = UUID()) async throws -> String {
        guard code.count == 8 else { throw CloudError.malformed("the pairing code has 8 letters") }
        var request = URLRequest(url: host.appending(path: "token/json/2/device/new"))
        request.httpMethod = "POST"
        request.setValue("Bearer", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "deviceDesc": "desktop-macos",
            "deviceID": deviceID.uuidString.lowercased(),
        ])
        return String(decoding: try await http.data(request, retryTransient: false), as: UTF8.self)
    }

    /// Mint a session token (lasts about a day) from a device token.
    public func session(deviceToken: String) async throws -> String {
        var request = URLRequest(url: host.appending(path: "token/json/2/user/new"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        return String(decoding: try await http.data(request, retryTransient: false), as: UTF8.self)
    }
}
