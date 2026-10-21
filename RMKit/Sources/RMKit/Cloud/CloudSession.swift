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
    private let failureCooldown: Duration
    private var lastFailure: (error: any Error, until: ContinuousClock.Instant)?

    /// `failureCooldown`: after a failed token exchange, calls fail with the same
    /// error for this long instead of asking again; the exchange is rate-limited.
    public init(
        deviceToken: String,
        session: URLSession = .shared,
        authHost: URL = CloudHosts.auth,
        syncHost: URL? = nil,
        failureCooldown: Duration = .seconds(30)
    ) {
        self.deviceToken = deviceToken
        http = HTTP(session: session)
        auth = AuthClient(session: session, host: authHost)
        syncHostOverride = syncHost
        self.failureCooldown = failureCooldown
    }

    public func claims() async throws -> TokenClaims {
        try await authorized().claims
    }

    /// Concurrent callers share one exchange, and its failure: the task is
    /// stored before anyone awaits it, and cleared only by the caller that made
    /// it, so the next call after a failure tries again.
    /// `replacing` is the token that just got a 401: a newer one is reused,
    /// that one is refreshed once however many requests saw it fail.
    private func authorized(replacing stale: String? = nil) async throws -> Authorized {
        // a token that is only nearing expiry still works; keep it if the refresh fails
        var stillValid: Authorized?
        if let current {
            let value = try await current.value
            // another caller replaced the task while we waited: use theirs
            if self.current != current { return try await authorized(replacing: stale) }
            if value.token != stale, !value.isExpiring { return value }
            if value.token != stale, (value.claims.expiry ?? .distantFuture) > Date() { stillValid = value }
        }
        if let lastFailure, ContinuousClock.now < lastFailure.until {
            if let stillValid { return stillValid }
            throw lastFailure.error
        }
        let fresh = Task { [auth, deviceToken] in
            let token = try await auth.session(deviceToken: deviceToken)
            return Authorized(token: token, claims: try TokenClaims(jwt: token))
        }
        current = fresh
        do {
            let value = try await fresh.value
            lastFailure = nil
            return value
        } catch {
            if current == fresh {
                lastFailure = (error, ContinuousClock.now + failureCooldown)
                if let stillValid {
                    current = Task { stillValid }
                    return stillValid
                }
                current = nil
            }
            throw error
        }
    }

    private func send(_ build: (URL) -> URLRequest) async throws -> Data {
        var auth = try await authorized()
        for attempt in 0..<2 {
            var request = build(syncHostOverride ?? CloudHosts.sync(tectonic: auth.claims.tectonic))
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            do {
                return try await http.data(request)
            } catch CloudError.unauthorized where attempt == 0 {
                auth = try await authorized(replacing: auth.token)
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
        guard Entries.isHash(root.hash) else {
            throw CloudError.malformed("not a hash: \(root.hash)")
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
