import AppKit
import RMKit
import UniformTypeIdentifiers

extension LibraryItem {
    /// How a dropped link reads in another app, e.g. "Remora: Inbox (Notebook)".
    var dragTitle: String {
        "Remora: \(name) (\(kind.name))"
    }
}

extension RemoraLink {
    /// What a drag to another app carries, best first; each app takes what it
    /// understands. A browser or Finder gets the URL and its name (Finder makes a
    /// named .webloc), Notes or Mail a titled link, a plain text field a Markdown link.
    func itemProvider(title: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = title
        let link = url.absoluteString
        // without a charset AppKit reads the fragment as Latin-1 and garbles "ő"
        let html = "<meta charset=\"utf-8\"><a href=\"\(link)\">\(Self.escapeHTML(title))</a>"
        for (type, text) in [(UTType.url.identifier, link), ("public.url-name", title),
                             (UTType.html.identifier, html), (UTType.utf8PlainText.identifier, markdown(title: title))] {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { done in
                done(Data(text.utf8), nil)
                return nil
            }
        }
        return provider
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
