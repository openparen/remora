import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

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
    /// The device token's `device-id`: `listen` skips the notices this device's own syncs send.
    private let deviceID: String?
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
        deviceID = (try? TokenClaims(jwt: deviceToken))?.deviceID
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
        // the fallback lives inside the shared task, so every waiter gets the kept token, not just this caller
        let kept = stillValid
        let fresh = Task { [auth, deviceToken] in
            do {
                let token = try await auth.session(deviceToken: deviceToken)
                return Authorized(token: token, claims: try TokenClaims(jwt: token))
            } catch {
                self.exchangeFailed(error)
                if let kept { return kept }
                throw error
            }
        }
        current = fresh
        do {
            return try await fresh.value
        } catch {
            if current == fresh { current = nil }
            throw error
        }
    }

    private func exchangeFailed(_ error: any Error) {
        lastFailure = (error, ContinuousClock.now + failureCooldown)
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

    /// Hold the notification socket open and call `changed` for every sync
    /// another device completes. Pings every `ping` and drops a socket whose
    /// last ping went unanswered; reopens every `reopen` regardless. Reconnects
    /// after `backoff`, doubling while connections keep failing.
    func listen(
        // under URLSession's 60 s request timeout, so an idle socket is never timed out between pings
        ping: Duration = .seconds(45),
        reopen: Duration = .seconds(3600),
        backoff: Duration = .seconds(1),
        _ changed: @Sendable () -> Void
    ) async {
        var failures = 0
        var stale: String?
        while !Task.isCancelled {
            var token: String?
            var socket: URLSessionWebSocketTask?
            var opened: ContinuousClock.Instant?
            let pongs = Pongs()
            do {
                let auth = try await authorized(replacing: stale)
                token = auth.token
                stale = nil
                let host = syncHostOverride ?? CloudHosts.sync(tectonic: auth.claims.tectonic)
                var parts = URLComponents(url: host.appending(path: "notifications/ws/json/1"), resolvingAgainstBaseURL: false)!
                parts.scheme = host.scheme == "http" ? "ws" : "wss"
                var request = URLRequest(url: parts.url!)
                request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
                let task = http.session.webSocketTask(with: request)
                socket = task
                task.resume()
                let start = ContinuousClock.now
                opened = start
                // an unanswered ping is a half-open socket: cancelling it makes receive() throw
                let pinger = Task {
                    var sent = 0
                    while true {
                        try await Task.sleep(for: ping)
                        guard pongs.count.load(ordering: .relaxed) == sent, .now - start < reopen else {
                            task.cancel(with: .goingAway, reason: nil)
                            return
                        }
                        sent += 1
                        task.sendPing { if $0 == nil { pongs.count.wrappingAdd(1, ordering: .relaxed) } }
                    }
                }
                defer {
                    pinger.cancel()
                    task.cancel(with: .goingAway, reason: nil)
                }
                // receive() ignores task cancellation; closing the socket ends it
                try await withTaskCancellationHandler {
                    while true {
                        if case .string(let text) = try await task.receive(),
                           let notice = Notices.parse(text), notice.sourceDeviceID != deviceID {
                            changed()
                        }
                    }
                } onCancel: {
                    task.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                if Task.isCancelled { return }
                // only a refused handshake says the token is bad, not a close or a drop
                if (socket?.response as? HTTPURLResponse)?.statusCode == 401 { stale = token }
            }
            // a socket that was up a while closing is routine, not a failure to back off from
            let healthy = pongs.count.load(ordering: .relaxed) > 0 || opened.map { .now - $0 >= ping } == true
            failures = healthy ? 1 : min(failures + 1, 7)
            let delay = min(.seconds(60), backoff * (1 << (failures - 1)))
            try? await Task.sleep(for: delay * Double.random(in: 1...1.2))
        }
    }
}

/// Pongs back on one socket, counted from URLSession's callback queue.
private final class Pongs: Sendable {
    let count = Atomic(0)
}
