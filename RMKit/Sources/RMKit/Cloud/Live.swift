import Foundation

/// A SyncComplete notification: a device finished committing to the account.
/// It never says what changed; it's only a reason to re-read the root.
public struct SyncNotice: Sendable, Equatable {
    public let sourceDeviceID: String
}

public enum Notices {
    /// One socket frame, `{"message":{"attributes":{"event":"SyncComplete","sourceDeviceID":…}}}`.
    /// nil for anything else: screen sharing, passcode and other events share the socket.
    public static func parse(_ text: String) -> SyncNotice? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let attributes = message["attributes"] as? [String: Any],
              attributes["event"] as? String == "SyncComplete"
        else { return nil }
        return SyncNotice(sourceDeviceID: attributes["sourceDeviceID"] as? String ?? "")
    }
}

extension CloudSession {
    /// Yields whenever the account may have changed: when another device
    /// finishes a sync, and every `poll` regardless, because a socket can go
    /// quiet without closing. Stops when the consumer stops iterating.
    public nonisolated func changes(poll: Duration = .seconds(30)) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: poll)
                    if !Task.isCancelled { continuation.yield() }
                }
            }
            let listener = Task { await self.listen { continuation.yield() } }
            continuation.onTermination = { _ in
                poller.cancel()
                listener.cancel()
            }
        }
    }

    /// Hold the notification socket open, reconnecting with backoff, and call
    /// `changed` for every sync another device completes.
    func listen(_ changed: @Sendable () -> Void) async {
        var failures = 0
        var stale: String?
        while !Task.isCancelled {
            var token: String?
            do {
                let auth = try await authorized(replacing: stale)
                token = auth.token
                stale = nil
                let host = syncHostOverride ?? CloudHosts.sync(tectonic: auth.claims.tectonic)
                var parts = URLComponents(url: host.appending(path: "notifications/ws/json/1"), resolvingAgainstBaseURL: false)!
                parts.scheme = host.scheme == "http" ? "ws" : "wss"
                var request = URLRequest(url: parts.url!)
                request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
                let socket = http.session.webSocketTask(with: request)
                socket.resume()
                // a ping a minute: a socket that died silently fails it, and receive() then throws
                let pinger = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        socket.sendPing { if $0 != nil { socket.cancel(with: .abnormalClosure, reason: nil) } }
                    }
                }
                defer {
                    pinger.cancel()
                    socket.cancel(with: .goingAway, reason: nil)
                }
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    failures = 0
                    if case .string(let text) = message, let notice = Notices.parse(text), notice.sourceDeviceID != deviceID {
                        changed()
                    }
                }
            } catch {
                if Task.isCancelled { return }
                failures = min(failures + 1, 6)
                // repeated failures to even open may mean the session token was refused
                if failures >= 3 { stale = token }
                try? await Task.sleep(for: .seconds(min(60, 1 << failures)))
            }
        }
    }
}
