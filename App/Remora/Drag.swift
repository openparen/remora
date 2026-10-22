import AppKit
import RMKit
import SwiftUI
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
        for (type, text) in [(UTType.url.identifier, url.absoluteString), ("public.url-name", title),
                             (UTType.html.identifier, html(title: title)), (UTType.utf8PlainText.identifier, markdown(title: title))] {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { done in
                done(Data(text.utf8), nil)
                return nil
            }
        }
        return provider
    }

    /// A titled link for rich text.
    func html(title: String) -> String {
        // without a charset AppKit reads the fragment as Latin-1 and garbles "ő"
        "<meta charset=\"utf-8\"><a href=\"\(url.absoluteString)\">\(Self.escapeHTML(title))</a>"
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The document's icon at the front of its window's title bar: drag it out and
/// it lands like the library item, as a titled link.
// ponytail: a toolbar item, not AppKit's proxy icon, which needs the window delegate SwiftUI owns
struct DocumentDragHandle: ToolbarContent {
    let item: LibraryItem

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onDrag { item.link.itemProvider(title: item.dragTitle) }
                .help("Drag into another app for a link to this document")
                .accessibilityLabel("Link to \(item.name)")
        }
    }
}
