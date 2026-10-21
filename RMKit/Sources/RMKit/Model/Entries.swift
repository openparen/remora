import Foundation

/// One line of an entry list: a file of a document, or a document of the root.
public struct Entry: Sendable, Hashable {
    public let hash: String
    public let id: String
    public let subfiles: Int
    public let size: Int
}

/// The `.docSchema` entry-list format. Schema 3 is a version line then
/// `hash:type:id:subfiles:size` lines; schema 4 adds a `0:<id>:<count>:<size>`
/// info line after the version.
public enum Entries {
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { throw CloudError.malformed("empty entry list") }
        let version = lines.removeFirst()
        var expected: Int?
        switch version {
        case "3":
            break
        case "4":
            guard !lines.isEmpty else { throw CloudError.malformed("schema 4 entry list has no info line") }
            let info = lines.removeFirst().split(separator: ":", omittingEmptySubsequences: false)
            guard info.count == 4, info[0] == "0", let count = Int(info[2]) else {
                throw CloudError.malformed("bad schema 4 info line")
            }
            expected = count
        default:
            throw CloudError.malformed("entry list schema \(version)")
        }
        let entries = try lines.map(parseLine)
        if let expected, expected != entries.count {
            throw CloudError.malformed("entry list declares \(expected) entries but has \(entries.count)")
        }
        return entries
    }

    private static func parseLine(_ line: String) throws -> Entry {
        let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, isHash(fields[0]), fields[1] == "0" || fields[1] == "80000000",
              !fields[2].isEmpty, let subfiles = Int(fields[3]), let size = Int(fields[4])
        else { throw CloudError.malformed("bad entry line: \(line)") }
        return Entry(hash: fields[0], id: fields[2], subfiles: subfiles, size: size)
    }
}
