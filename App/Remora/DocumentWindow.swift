import RMKit
import SwiftUI

/// A document's window: finds the document in whichever account has it. A link
/// to something no account knows refreshes every account once before saying so.
struct DocumentWindow: View {
    let link: DocumentLink
    @State private var refreshedForMissing = false
    @Environment(\.openWindow) private var openWindow
    private let store = AccountStore.shared

    var body: some View {
        Group {
            if let (account, item) = store.locate(link.docID) {
                VStack(spacing: 0) {
                    if account.library?.isInTrash(item.id) == true {
                        Banner("This document is in the trash.")
                    }
                    switch item.kind {
                    case .notebook:
                        NotebookView(account: account, item: item, firstPage: link.pageID)
                    case .pdf, .epub:
                        PDFDocumentView(account: account, item: item, firstPage: link.pageID)
                    case .folder, .template:
                        ContentUnavailableView("Not a document", systemImage: "folder")
                    }
                }
            } else if store.stillLoading || !refreshedForMissing {
                ProgressView("Loading the library…")
                    .task(id: store.stillLoading) {
                        guard !store.stillLoading, !refreshedForMissing else { return }
                        // unstructured: starting the sync flips stillLoading, which would cancel this task
                        Task {
                            await store.refreshAll()
                            refreshedForMissing = true
                        }
                    }
            } else {
                ContentUnavailableView("Document not found", systemImage: "questionmark.folder",
                                       description: Text("No paired account has this document. It may have been deleted."))
            }
        }
        .frame(minWidth: 480, minHeight: 600)
        // a launch can restore document windows without the Library; links must still open
        .onAppear { Router.shared.attach(openWindow) }
    }
}

struct Banner: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).padding(8).frame(maxWidth: .infinity).background(.yellow.opacity(0.25))
    }
}

/// Pages one under another, fit to the window's width, zoomable.
struct NotebookView: View {
    let account: AccountState
    let item: LibraryItem
    let firstPage: String?

    @State private var document: Document?
    @State private var problem: String?
    @State private var zoom = 1.0
    @State private var currentPageID: String?
    @State private var missingPage = false
    /// The last page off screen whose ink changed while the window was open.
    @State private var latestEdit: String?
    /// Bumped by the toolbar to scroll to `latestEdit`.
    @State private var jumpRequest = 0
    /// Clockwise quarter turns, remembered per document.
    @State private var turns: Int
    @GestureState private var pinch = 1.0
    @AppStorage(DarkPages.key) private var darkPages = false
    @Environment(\.colorScheme) private var colorScheme
    private let router = Router.shared

    init(account: AccountState, item: LibraryItem, firstPage: String?) {
        self.account = account
        self.item = item
        self.firstPage = firstPage
        _turns = State(initialValue: ViewTurns.get(item.id))
    }

    var body: some View {
        content
            .navigationTitle(item.name)
            .navigationSubtitle(pageLabel)
            .toolbar { toolbar }
            .task(id: item.hash) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let document {
            VStack(spacing: 0) {
                if missingPage { Banner("The linked page is no longer in this document.") }
                pages(document)
            }
        } else if let problem {
            ContentUnavailableView("Can't open \(item.name)", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else {
            ProgressView()
        }
    }

    private func pages(_ document: Document) -> some View {
        GeometryReader { geometry in
            // pages render at the settled zoom; a pinch only scales what's already drawn
            let renderWidth = max(200, (geometry.size.width - 48) * zoom)
            let shownWidth = max(200, (geometry.size.width - 48) * clampZoom(zoom * pinch))
            // the current page is the one crossing a line a third of the way down the window
            let readingLine = geometry.size.height / 3
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 16) {
                        ForEach(document.pages, id: \.id) { page in
                            PageView(document: document, page: page, blobs: account.sync.blobs,
                                     renderWidth: renderWidth, shownWidth: shownWidth, turns: turns,
                                     dark: darkPages && colorScheme == .dark)
                                .id(page.id)
                                .contextMenu { PageMenu(item: item, page: page) { await image(of: page, in: document) } }
                                .onGeometryChange(for: Bool.self) { frame in
                                    let box = frame.frame(in: .named("viewport"))
                                    return box.minY <= readingLine && box.maxY > readingLine
                                } action: { crossing in
                                    if crossing { currentPageID = page.id }
                                }
                        }
                    }
                    .padding(24)
                    .frame(minWidth: geometry.size.width)
                }
                .coordinateSpace(name: "viewport")
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { zoom = clampZoom(zoom * $0.magnification) })
                .onAppear { scroll(proxy, to: router.pageRequest[item.id]?.page ?? firstPage, in: document) }
                .onChange(of: router.pageRequest[item.id]?.nonce) {
                    withAnimation { scroll(proxy, to: router.pageRequest[item.id]?.page, in: document) }
                }
                // keep the reading position when the pages change size
                .onChange(of: zoom) { if let currentPageID { proxy.scrollTo(currentPageID, anchor: .top) } }
                .onChange(of: turns) { if let currentPageID { proxy.scrollTo(currentPageID, anchor: .top) } }
                .onChange(of: jumpRequest) {
                    if let latestEdit {
                        withAnimation { proxy.scrollTo(latestEdit, anchor: .top) }
                        self.latestEdit = nil
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func scroll(_ proxy: ScrollViewProxy, to page: String?, in document: Document) {
        guard let page else { return }
        missingPage = !document.pages.contains { $0.id == page }
        if !missingPage { proxy.scrollTo(page, anchor: .top) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        DocumentDragHandle(item: item)
        ToolbarItemGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = clampZoom(zoom / 1.25) }
                .keyboardShortcut("-")
            Button("Fit Width", systemImage: "arrow.left.and.right") { zoom = 1 }
                .keyboardShortcut("0")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = clampZoom(zoom * 1.25) }
                .keyboardShortcut("=")
            Button("Rotate", systemImage: "rotate.right") {
                turns = (turns + 1) % 4
                ViewTurns.set(item.id, turns)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Turn the pages a quarter clockwise, for a notebook written sideways")
            .accessibilityValue("\(turns * 90) degrees")
            Button("Copy Link to Page", systemImage: "link") { Clipboard.copy(currentLink.url.absoluteString) }
                .keyboardShortcut("l")
            Menu("More Links", systemImage: "ellipsis.circle") {
                Button("Copy as Markdown Link") {
                    Clipboard.copy(currentLink.markdown(title: item.name, pageNumber: currentPage?.number))
                }
                Button("Copy Link to Document") { Clipboard.copy(RemoraLink.document(id: item.id, page: nil).url.absoluteString) }
            }
            // last, so the other buttons don't shift when it comes and goes
            if let number = document?.pages.first(where: { $0.id == latestEdit })?.number {
                Button("Jump to Latest Edit (p. \(number))", systemImage: "pencil.and.scribble") { jumpRequest += 1 }
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var currentPage: PageRef? {
        document?.pages.first { $0.id == currentPageID } ?? document?.pages.first
    }

    private var currentLink: RemoraLink { .document(id: item.id, page: currentPage?.id) }

    private var pageLabel: String {
        guard let document, let page = currentPage else { return "" }
        return "Page \(page.number) of \(document.pages.count)"
    }

    private func clampZoom(_ value: Double) -> Double { min(4, max(0.25, value)) }

    /// The page as shown, at twice the tablet's resolution, halved while that's too large.
    private func image(of page: PageRef, in document: Document) async -> PageImage? {
        let (blobs, turns) = (account.sync.blobs, turns)
        var scale = 2.0
        for _ in 0..<4 {
            do {
                let image = try await document.render(page, scale: scale, blobs: blobs).image
                // a tablet pixel is a point, as in the window at its fitted size
                return await Task.detached { image.turned(turns) }.value.map { PageImage(image: $0, pixelsPerPoint: scale) }
            } catch FlatRenderer.RenderError.tooLarge {
                scale /= 2
            } catch {
                return nil
            }
        }
        return nil
    }

    private func load() async {
        do {
            let fresh = try await Document.load(item, blobs: account.sync.blobs)
            // live: which pages' ink changed since the window last loaded
            if let old = document {
                // the page being read redraws in place; only an edit elsewhere is worth a jump
                let changed = fresh.pages.filter { fresh.inkFile($0)?.hash != old.inkFile($0)?.hash && $0.id != currentPageID }
                if let last = changed.last { latestEdit = last.id }
            }
            document = fresh
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            problem = AccountState.describe(error)
        }
    }
}

/// One page, rendered off the main thread at the size it's shown and dropped
/// again when it scrolls away.
struct PageView: View {
    let document: Document
    let page: PageRef
    let blobs: BlobStore
    let renderWidth: Double
    let shownWidth: Double
    /// Clockwise quarter turns.
    let turns: Int
    /// Recoloured for Dark Mode.
    let dark: Bool

    @Environment(\.displayScale) private var displayScale
    /// The page as last drawn, and the turns and colours it was drawn at.
    @State private var rendered: (image: CGImage, template: PageTemplate?, drops: PageDrops, turns: Int, dark: Bool)?
    @State private var problem: String?

    var body: some View {
        let upright = document.content.orientation == .landscape ? 3.0 / 4 : 4.0 / 3
        // a drawing made at other turns has the wrong shape, or in the other colours: use the placeholder's until the new one arrives
        let current = rendered.flatMap { $0.turns == turns && $0.dark == dark ? $0 : nil }
        let aspect = current.map { Double($0.image.height) / Double($0.image.width) }
            ?? (turns % 2 == 0 ? upright : 1 / upright)
        ZStack(alignment: .topTrailing) {
            if let rendered = current {
                Image(decorative: rendered.image, scale: 1).resizable().interpolation(.high)
            } else if let problem {
                Text(problem).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                paper
            }
            if rendered != nil, rendered?.template == nil, let name = page.template {
                Text("template: \(name)").font(.caption).padding(4).background(.thinMaterial).padding(8)
            }
            if rendered?.drops.isLossy == true {
                Label("Some ink on this page couldn't be read", systemImage: "exclamationmark.triangle")
                    .font(.caption).padding(4).background(.yellow.opacity(0.8)).padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(width: shownWidth, height: shownWidth * aspect)
        .background(paper)
        .shadow(radius: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(page.number)")
        // re-render when the settled width moves a step, not on every pixel of a resize
        .task(id: RenderKey(page: page.id, ink: document.inkFile(page)?.hash, template: page.template,
                            width: Int(renderWidth * displayScale / 256), turns: turns, dark: dark)) {
            await render()
        }
        .onDisappear { rendered = nil }
    }

    private struct RenderKey: Hashable {
        let page: String
        let ink: String?
        let template: String?
        let width: Int
        let turns: Int
        let dark: Bool
    }

    private var paper: Color { dark ? Color(cgColor: DarkPage.paperColor) : .white }

    private func render() async {
        let pixels = (renderWidth * displayScale / 256).rounded(.up) * 256
        // the side that's across the window: the page's height once it's turned a quarter
        let across = (document.content.orientation == .landscape) != (turns % 2 == 1) ? 1872.0 : 1404.0
        var scale = min(4, pixels / across)
        // ponytail: one bitmap per page, so ink dragged far off the page halves the scale until it fits; tile for deep zoom
        for _ in 0..<4 {
            do {
                let result = try await document.render(page, scale: scale, blobs: blobs)
                // ponytail: turning makes a second bitmap, off the main thread; draw turned in FlatRenderer if memory bites
                let (turns, dark, image) = (turns, dark, result.image)
                let shown = await Task.detached { () -> CGImage in
                    let turned = image.turned(turns) ?? image
                    return dark ? DarkPage.darken(turned) ?? turned : turned
                }.value
                guard !Task.isCancelled else { return }
                rendered = (shown, result.template, result.drops, turns, dark)
                problem = nil
                return
            } catch FlatRenderer.RenderError.tooLarge {
                if Task.isCancelled { return }
                scale /= 2
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                problem = AccountState.describe(error)
                return
            }
        }
        if !Task.isCancelled { problem = "This page is too large to draw." }
    }
}
