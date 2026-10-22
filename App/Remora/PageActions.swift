import AppKit
import RMKit
import SwiftUI
import UniformTypeIdentifiers

/// How far a document's window is turned, in clockwise quarter turns,
/// remembered per document: for notebooks written with the tablet held sideways.
enum ViewTurns {
    static func get(_ id: String) -> Int { UserDefaults.standard.integer(forKey: "viewTurns.\(id)") }

    static func set(_ id: String, _ turns: Int) {
        let turns = (turns % 4 + 4) % 4
        if turns == 0 {
            UserDefaults.standard.removeObject(forKey: "viewTurns.\(id)")
        } else {
            UserDefaults.standard.set(turns, forKey: "viewTurns.\(id)")
        }
    }
}

/// A page as a picture, to copy or to save.
@MainActor enum PageImage {
    static func copy(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
    }

    /// Asks where, then writes a PNG. `name` is the suggestion, without an extension.
    static func save(_ image: CGImage, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        // a slash would read as a folder
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".png"
        guard panel.runModal() == .OK, let url = panel.url,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// What a right-click on a page offers, in a notebook window.
struct PageMenu: View {
    let item: LibraryItem
    let page: PageRef
    /// The page as shown, at full size; nil if it can't be drawn.
    let image: () async -> CGImage?

    var body: some View {
        let link = RemoraLink.document(id: item.id, page: page.id)
        Button("Copy Link to This Page") { Clipboard.copy(link.url.absoluteString) }
        Button("Copy as Markdown Link") { Clipboard.copy(link.markdown(title: item.name, pageNumber: page.number)) }
        Button("Copy Link to Document") { Clipboard.copy(RemoraLink.document(id: item.id, page: nil).url.absoluteString) }
        Divider()
        Button("Copy Page as Image") { Task { if let image = await image() { PageImage.copy(image) } } }
        Button("Save Page as Image…") {
            Task { if let image = await image() { PageImage.save(image, name: "\(item.name) p\(page.number)") } }
        }
    }
}

/// An AppKit menu item that runs a closure, for PDFView's own context menu.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runAction() { run() }
}
