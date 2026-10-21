import Foundation

public enum CloudError: Error, Equatable {
    case unauthorized
    /// 402/403: the account has no Connect subscription.
    case noSubscription
    case http(status: Int, body: String)
    case malformed(String)

    init(status: Int, body: String) {
        switch status {
        case 401: self = .unauthorized
        case 402, 403: self = .noSubscription
        default: self = .http(status: status, body: body)
        }
    }
}

public enum CloudHosts {
    public static let auth = URL(string: "https://webapp-prod.cloud.remarkable.engineering")!

    /// The session token's `tectonic` claim names the region; rmapi-js hardcodes "eu".
    public static func sync(tectonic: String?) -> URL {
        let region = tectonic.flatMap {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } ? $0 : nil
        }
        return URL(string: "https://\(region ?? "eu").tectonic.remarkable.com")!
    }
}

/// URLSession with rmapi-js's transient-retry policy: network errors, 429 and
/// 5xx are retried with exponential backoff.
struct HTTP: Sendable {
    let session: URLSession
    var maxTransientRetries = 3
    var baseDelay: Duration = .milliseconds(200)

    func data(_ request: URLRequest, retryTransient: Bool = true) async throws -> Data {
        var attempt = 0
        while true {
            let retriesLeft = retryTransient && attempt < maxTransientRetries
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                guard retriesLeft, status == 429 || status >= 500 else {
                    throw CloudError(status: status, body: String(decoding: data, as: UTF8.self))
                }
            } catch let error as URLError {
                guard retriesLeft else { throw error }
            }
            attempt += 1
            try await Task.sleep(for: baseDelay * (1 << attempt))
        }
    }
}
