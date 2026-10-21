import Foundation
import Testing
@testable import RMKit

@Suite struct TokensTests {
    @Test func readsTheClaimsRemoraUses() throws {
        let claims = try TokenClaims(jwt: jwt([
            "auth0-userid": "auth0|abc", "device-id": "dev-1", "tectonic": "us",
            "exp": 1_800_000_000, "auth0-profile": ["Email": "me@example.com"],
        ]))
        #expect(claims.userID == "auth0|abc")
        #expect(claims.deviceID == "dev-1")
        #expect(claims.tectonic == "us")
        #expect(claims.email == "me@example.com")
        #expect(claims.expiry == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func rejectsANonJWT() {
        #expect(throws: CloudError.malformed("not a JWT")) { try TokenClaims(jwt: "nope") }
    }
}
