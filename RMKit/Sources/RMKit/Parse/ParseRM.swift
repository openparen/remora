import Foundation

private let rmHeaderPrefix = "reMarkable .lines file, version="

/// Parse a `.rm` page file of version 3, 5 or 6.
public func parseRM(_ data: Data) throws -> RMPage {
    guard data.count >= rmHeaderLength else { throw RMParseError.notAnRMFile }
    let header = String(decoding: data.prefix(rmHeaderLength), as: UTF8.self)
    guard header.hasPrefix(rmHeaderPrefix) else { throw RMParseError.notAnRMFile }
    let version = header.dropFirst(rmHeaderPrefix.count).prefix(1)
    switch version {
    case "6": return try RMV6.parse(data)
    case "3": return try RMV5.parse(data, version: 3)
    case "5": return try RMV5.parse(data, version: 5)
    default: throw RMParseError.unsupportedVersion(String(version))
    }
}
