import AppKit
import RMKit
import SwiftUI

// SwiftUI has a LibraryItem and a Document of its own; in this app the names mean RMKit's
typealias LibraryItem = RMKit.LibraryItem
typealias Document = RMKit.Document

/// The value a document window is opened for. Window identity is the document
/// alone: the page is a scroll target, so a second link into the same document
/// focuses its window instead of opening another.
struct DocumentLink: Codable, Hashable {
    var docID: String
    var pageID: String?

    static func == (a: Self, b: Self) -> Bool { a.docID == b.docID }
    func hash(into h: inout Hasher) { h.combine(docID) }
}

/// Turns `rmr://` links into windows. Links can arrive before any view exists
/// (launch by URL), so they wait until the Library hands over `openWindow`.
@MainActor @Observable final class Router {
    static let shared = Router()

    /// The folder a link asked the Library to show; the nonce makes a repeated link count again.
    var folderRequest: (folder: String, nonce: Int)?
    /// docID → the page its window should scroll to. The nonce makes a repeated
    /// link to the same page scroll again.
    var pageRequest: [String: (page: String, nonce: Int)] = [:]

    /// docID → a counter the toolbar bumps to scroll the window to its latest edit.
    var jumpToLatestEdit: [String: Int] = [:]

    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var pending: [RemoraLink] = []
    @ObservationIgnored private var nonce = 0

    func attach(_ action: OpenWindowAction) {
        guard openWindow == nil else { return }
        openWindow = action
        let queued = pending
        pending = []
        queued.forEach(route)
    }

    func handle(_ url: URL) {
        guard let link = RemoraLink(url) else { return }
        if openWindow == nil { pending.append(link) } else { route(link) }
    }

    func open(_ link: RemoraLink) { route(link) }

    private func route(_ link: RemoraLink) {
        guard let openWindow else { return }
        switch link {
        case .document(let id, let page):
            if let page {
                nonce += 1
                pageRequest[id] = (page, nonce)
            }
            openWindow(value: DocumentLink(docID: id, pageID: page))
        case .folder(let id):
            nonce += 1
            folderRequest = (id, nonce)
            openWindow(id: "library")
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    // The launch URL arrives here, before didFinishLaunching. SwiftUI also handles
    // that event, which is what presents the Library on a launch by URL; keep it.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(Router.shared.handle)
    }

    // Once running, take kAEGetURL from SwiftUI: its handling hides and re-shows
    // the Library for every URL, and reopens it when the user had closed it.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        AccountStore.shared.load()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        Router.shared.handle(url)
    }
}

@main
struct RemoraApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
        }
        WindowGroup("Document", id: "doc", for: DocumentLink.self) { $link in
            if let link { DocumentWindow(link: link) }
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
