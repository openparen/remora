import Foundation

/// A place in a reMarkable library as an `rmr://` URL. Links name documents,
/// pages and folders by id, never by name or page number, so renames, moves
/// and inserted pages don't break them. They carry no account: ids are unique.
public enum RemoraLink: Equatable, Sendable {
    case document(id: String, page: String?)
    case folder(id: String)

    /// `rmr://doc/<id>`, `rmr://doc/<id>?page=<id>` or `rmr://folder/<id>`.
    public init?(_ url: URL) {
        guard url.scheme == "rmr" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, Self.isID(parts[0]) else { return nil }
        switch url.host() {
        case "doc":
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value
            if let page, !Self.isID(page) { return nil }
            self = .document(id: parts[0], page: page)
        case "folder":
            self = .folder(id: parts[0])
        default:
            return nil
        }
    }

    /// reMarkable ids are UUIDs; anything else in a link is refused.
    static func isID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public var url: URL {
        switch self {
        case .document(let id, nil): URL(string: "rmr://doc/\(id)")!
        case .document(let id, let page?): URL(string: "rmr://doc/\(id)?page=\(page)")!
        case .folder(let id): URL(string: "rmr://folder/\(id)")!
        }
    }

    /// `[Title p.12](rmr://…)`, for notes apps.
    public func markdown(title: String, pageNumber: Int? = nil) -> String {
        var text = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
        if let pageNumber { text += " p.\(pageNumber)" }
        return "[\(text)](\(url.absoluteString))"
    }
}
