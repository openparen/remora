import Foundation

/// The claims Remora reads out of reMarkable's JWTs. The device token carries
/// `auth0-userid` and `device-id`; the session token carries `tectonic` (the
/// sync region), `exp` and the account's email.
public struct TokenClaims: Sendable, Equatable {
    public var userID: String?
    public var deviceID: String?
    public var tectonic: String?
    public var email: String?
    public var expiry: Date?

    public init(jwt: String) throws {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw CloudError.malformed("not a JWT") }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CloudError.malformed("unreadable JWT payload") }
        userID = json["auth0-userid"] as? String
        deviceID = json["device-id"] as? String
        tectonic = json["tectonic"] as? String
        email = (json["auth0-profile"] as? [String: Any])?["Email"] as? String
        expiry = (json["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }
}
