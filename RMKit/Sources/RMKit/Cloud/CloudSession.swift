import Foundation

public struct RootHash: Sendable, Equatable, Codable {
    public let hash: String
    public let generation: Int
    public let schemaVersion: Int
}

/// One account's authorized access to the sync API. Holds one session token
/// at a time, shared by every request, refreshed when it nears expiry or the
/// server answers 401.
public actor CloudSession {
    struct Authorized: Sendable {
        let token: String
        let claims: TokenClaims

        var isExpiring: Bool {
            guard let expiry = claims.expiry else { return false }
            return expiry < Date().addingTimeInterval(300)
        }
    }

    private let deviceToken: String
    private let http: HTTP
    private let auth: AuthClient
    private let syncHostOverride: URL?
    private var current: Task<Authorized, Error>?

    public init(
        deviceToken: String,
        session: URLSession = .shared,
        authHost: URL = CloudHosts.auth,
        syncHost: URL? = nil
    ) {
        self.deviceToken = deviceToken
        http = HTTP(session: session)
        auth = AuthClient(session: session, host: authHost)
        syncHostOverride = syncHost
    }

    public func claims() async throws -> TokenClaims {
        try await authorized(refresh: false).claims
    }

    /// Concurrent first callers share one exchange: the task is stored before
    /// anyone awaits it.
    // ponytail: two callers that both see an expiring token can each refresh; it happens once a day
    private func authorized(refresh: Bool) async throws -> Authorized {
        if !refresh, let current, let value = try? await current.value, !value.isExpiring {
            return value
        }
        let fresh = Task { [auth, deviceToken] in
            let token = try await auth.session(deviceToken: deviceToken)
            return Authorized(token: token, claims: try TokenClaims(jwt: token))
        }
        current = fresh
        return try await fresh.value
    }

    private func send(_ build: (URL) -> URLRequest) async throws -> Data {
        var auth = try await authorized(refresh: false)
        for attempt in 0..<2 {
            var request = build(syncHostOverride ?? CloudHosts.sync(tectonic: auth.claims.tectonic))
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            do {
                return try await http.data(request)
            } catch CloudError.unauthorized where attempt == 0 {
                auth = try await authorized(refresh: true)
            }
        }
        throw CloudError.unauthorized
    }

    /// Always re-read: a client that keeps an old root sees a frozen account.
    public func root() async throws -> RootHash {
        let data = try await send { URLRequest(url: $0.appending(path: "sync/v4/root")) }
        let root = try JSONDecoder().decode(RootHash.self, from: data)
        guard root.schemaVersion == 3 || root.schemaVersion == 4 else {
            throw CloudError.malformed("root schema version \(root.schemaVersion)")
        }
        return root
    }

    /// One immutable blob. `name` is the file's id, e.g. `<doc>.content`.
    public func file(hash: String, name: String) async throws -> Data {
        guard Entries.isHash(hash) else { throw CloudError.malformed("not a hash: \(hash)") }
        return try await send { host in
            var request = URLRequest(url: host.appending(path: "sync/v3/files/\(hash)"))
            request.setValue(name, forHTTPHeaderField: "rm-filename")
            return request
        }
    }
}
