import AppKit
import RMKit
import SwiftUI
import UniformTypeIdentifiers

/// How far a document's window is turned, in clockwise quarter turns,
/// remembered per document: for notebooks written with the tablet held sideways.
enum ViewTurns {
    static func get(_ id: String) -> Int { (UserDefaults.standard.integer(forKey: "viewTurns.\(id)") % 4 + 4) % 4 }

    static func set(_ id: String, _ turns: Int) {
        let turns = (turns % 4 + 4) % 4
        if turns == 0 {
            UserDefaults.standard.removeObject(forKey: "viewTurns.\(id)")
        } else {
            UserDefaults.standard.set(turns, forKey: "viewTurns.\(id)")
        }
    }
}

/// A page as a picture, and how many of its pixels make a point, so it's
/// marked with its real resolution and pastes at page size.
struct PageImage {
    let image: CGImage
    let pixelsPerPoint: Double
}

@MainActor extension PageImage {
    static func copy(_ page: PageImage?) {
        guard let page else { return NSSound.beep() }
        let image = page.image
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: page.pointSize)])
    }

    /// Asks where, in a sheet on the key window, then writes a PNG. `name` is the suggestion, without an extension.
    static func save(_ page: PageImage?, name: String) async {
        guard let page else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        // a slash would read as a folder
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".png"
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: page.image)
        rep.size = page.pointSize
        do {
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: url, options: .atomic)
        } catch {
            if let window = NSApp.keyWindow { await NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
        }
    }

    private var pointSize: NSSize {
        NSSize(width: Double(image.width) / pixelsPerPoint, height: Double(image.height) / pixelsPerPoint)
    }
}

/// What a right-click on a page offers, in a notebook window.
struct PageMenu: View {
    let item: LibraryItem
    let page: PageRef
    /// The page as shown, at full size; nil if it can't be drawn.
    let image: () async -> PageImage?

    var body: some View {
        let link = RemoraLink.document(id: item.id, page: page.id)
        Button("Copy Link to This Page") { Clipboard.copy(link.url.absoluteString) }
        Button("Copy as Markdown Link") { Clipboard.copy(link.markdown(title: item.name, pageNumber: page.number)) }
        Button("Copy Link to Document") { Clipboard.copy(RemoraLink.document(id: item.id, page: nil).url.absoluteString) }
        Divider()
        Button("Copy Page as Image") { Task { PageImage.copy(await image()) } }
        Button("Save Page as Image…") { Task { await PageImage.save(await image(), name: "\(item.name) p\(page.number)") } }
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
