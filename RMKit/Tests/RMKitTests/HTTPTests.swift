import Foundation
import Testing
@testable import RMKit

@Suite struct HTTPTests {
    @Test func retriesTransientFailures() async throws {
        let calls = Locked(0)
        let (session, host) = StubProtocol.make { _ in
            let n = calls.update { $0 += 1; return $0 }
            return n < 3 ? (503, Data()) : (200, Data("ok".utf8))
        }
        let data = try await HTTP(session: session, baseDelay: .zero).data(URLRequest(url: host))
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(calls.value == 3)
    }

    @Test func mapsStatusesToErrors() async {
        let (session, host) = StubProtocol.make { _ in (402, Data()) }
        await #expect(throws: CloudError.noSubscription) {
            try await HTTP(session: session).data(URLRequest(url: host))
        }
    }

    @Test func doesNotRetryWhenAskedNotTo() async throws {
        let calls = Locked(0)
        let (session, host) = StubProtocol.make { _ in
            calls.update { $0 += 1 }
            return (429, Data())
        }
        await #expect(throws: CloudError.http(status: 429, body: "")) {
            try await HTTP(session: session, baseDelay: .zero).data(URLRequest(url: host), retryTransient: false)
        }
        #expect(calls.value == 1)
    }

    @Test func regionHostComesFromTheClaim() {
        #expect(CloudHosts.sync(tectonic: "us").absoluteString == "https://us.tectonic.remarkable.com")
        #expect(CloudHosts.sync(tectonic: nil).absoluteString == "https://eu.tectonic.remarkable.com")
        #expect(CloudHosts.sync(tectonic: "evil.com/x").absoluteString == "https://eu.tectonic.remarkable.com")
        #expect(CloudHosts.sync(tectonic: "").absoluteString == "https://eu.tectonic.remarkable.com")
        #expect(CloudHosts.sync(tectonic: "é").absoluteString == "https://eu.tectonic.remarkable.com")
    }
}
