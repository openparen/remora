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
        // one pending change is enough: a burst during a refresh means one more refresh, not one each
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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
}
