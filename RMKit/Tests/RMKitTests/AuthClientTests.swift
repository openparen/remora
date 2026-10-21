import Foundation
import Testing
@testable import RMKit

@Suite struct AuthClientTests {
    @Test func registersAsAMacDesktopClient() async throws {
        let (session, host) = StubProtocol.make { request in
            #expect(request.url?.path() == "/token/json/2/device/new")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer")
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(request)) as? [String: String]
            #expect(body?["code"] == "abcdefgh")
            #expect(body?["deviceDesc"] == "desktop-macos")
            return (200, Data("device-token".utf8))
        }
        let token = try await AuthClient(session: session, host: host).register(code: "abcdefgh")
        #expect(token == "device-token")
    }

    @Test func refusesAShortCode() async {
        await #expect(throws: CloudError.self) { try await AuthClient().register(code: "abc") }
    }
}
