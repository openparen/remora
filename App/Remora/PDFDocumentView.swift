import PDFKit
import RMKit
import SwiftUI

/// A PDF or EPUB: PDFKit draws the pages (scrolling, zoom and text selection
/// come with it) and Remora draws the ink and highlights on top. An EPUB shows
/// the PDF the tablet rendered from it.
struct PDFDocumentView: View {
    let account: AccountState
    let item: LibraryItem
    let firstPage: String?

    @State private var model: PDFModel?
    @State private var problem: String?
    @State private var currentIndex = 0
    @State private var missingPage = false
    private let router = Router.shared

    var body: some View {
        content
            .navigationTitle(item.name)
            .navigationSubtitle(pageLabel)
            .toolbar { toolbar }
            .task(id: item.hash) { await load() }
            .onChange(of: router.pageRequest[item.id]?.nonce) { go(to: router.pageRequest[item.id]?.page) }
    }

    @ViewBuilder private var content: some View {
        if let model {
            VStack(spacing: 0) {
                if missingPage { Banner("The linked page is no longer in this document.") }
                // a new model is a new PDF: give it a new view rather than one still showing the old
                PDFKitView(model: model, currentIndex: $currentIndex)
                    .id(ObjectIdentifier(model))
            }
            .onAppear { go(to: router.pageRequest[item.id]?.page ?? firstPage) }
        } else if let problem {
            ContentUnavailableView("Can't open \(item.name)", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else {
            ProgressView("Downloading \(item.name)…")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { model?.view?.zoomOut(nil) }
                .keyboardShortcut("-")
            Button("Fit Width", systemImage: "arrow.left.and.right") { model?.view?.autoScales = true }
                .keyboardShortcut("0")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { model?.view?.zoomIn(nil) }
                .keyboardShortcut("=")
            Button("Copy Link to Page", systemImage: "link") { Clipboard.copy(currentLink.url.absoluteString) }
                .keyboardShortcut("l")
            Menu("More Links", systemImage: "ellipsis.circle") {
                Button("Copy as Markdown Link") {
                    Clipboard.copy(currentLink.markdown(title: item.name, pageNumber: currentPage?.number))
                }
                Button("Copy Link to Document") { Clipboard.copy(RemoraLink.document(id: item.id, page: nil).url.absoluteString) }
            }
        }
    }

    private var currentPage: PageRef? {
        guard let pages = model?.document.pages, pages.indices.contains(currentIndex) else { return nil }
        return pages[currentIndex]
    }

    private var currentLink: RemoraLink { .document(id: item.id, page: currentPage?.id) }

    private var pageLabel: String {
        guard let model, let page = currentPage else { return "" }
        return "Page \(page.number) of \(model.document.pages.count)"
    }

    private func go(to pageID: String?) {
        guard let pageID, let model else { return }
        guard let index = model.document.pages.firstIndex(where: { $0.id == pageID }) else {
            missingPage = true
            return
        }
        missingPage = false
        model.go(to: index)
    }

    private func load() async {
        do {
            let document = try await Document.load(item, blobs: account.sync.blobs)
            // live: same PDF and the same pages, only ink changed; redraw that, keep the view and its scroll
            if let model, model.canUpdate(to: document) {
                model.update(to: document)
                return
            }
            guard let file = document.pdfFile else {
                problem = item.kind == .epub
                    ? "This EPUB hasn't been opened on the tablet yet, so there's no PDF of it to show."
                    : "This document has no PDF file."
                return
            }
            let data = try await account.sync.blobs.data(hash: file.hash, name: file.id)
            guard let source = PDFKit.PDFDocument(data: data) else {
                problem = "The PDF couldn't be read."
                return
            }
            // pages were added, removed or moved: rebuild, staying on the page that was being read
            let reading = currentPage?.id
            let fresh = PDFModel(document: document, source: source, sourceData: data, blobs: account.sync.blobs)
            model = fresh
            currentIndex = 0
            if let reading, let index = document.pages.firstIndex(where: { $0.id == reading }) { fresh.go(to: index) }
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            problem = AccountState.describe(error)
        }
    }
}

/// The document's pages as one PDF, in the tablet's order: each page is its
/// source PDF page, or a blank page where one was inserted on the tablet.
/// The ink for each page loads on demand and is kept while the window is open.
@MainActor final class PDFModel {
    private(set) var document: Document
    let pdf = PDFKit.PDFDocument()
    let blobs: BlobStore
    /// The size and shape of a page inserted on the tablet.
    let blankGeometry: PageGeometry
    /// The view showing `pdf`, once there is one.
    weak var view: PDFView? {
        didSet { if let pending { self.pending = nil; go(to: pending) } }
    }
    private var pending: Int?
    private let source: PDFKit.PDFDocument
    private let sourceData: Data
    /// Source page number to the first page showing it.
    private var indexOfSource: [Int: Int] = [:]
    private var ink: [Int: NormalizedPage] = [:]
    private var loading: Set<Int> = []
    private var linksPrepared: Set<Int> = []
    /// EPUB chapter links seen so far, by target: the page they're on and their text.
    private var chapterLinks: [String: (index: Int, title: String)] = [:]
    private var pageStarts: Task<[String], Never>?
    /// The overlays on screen, so changed ink can be redrawn in place.
    private var overlays: [Int: WeakOverlay] = [:]
    private struct WeakOverlay { weak var view: InkOverlayView? }

    init(document: Document, source: PDFKit.PDFDocument, sourceData: Data, blobs: BlobStore) {
        self.document = document
        self.source = source
        self.sourceData = sourceData
        self.blobs = blobs
        blankGeometry = PageGeometry(portrait: nil, orientation: document.content.orientation)
        // ponytail: ~0.3 s on the main thread for 2000 pages; skip the copies when the order is the source's if it grows
        for (index, ref) in document.pages.enumerated() {
            let page: PDFPage
            if let number = ref.sourcePage, let original = source.page(at: number - 1), let copy = original.copy() as? PDFPage {
                page = copy
                if indexOfSource[number] == nil { indexOfSource[number] = index }
            } else {
                page = PDFPage()
                page.setBounds(CGRect(origin: .zero, size: PDFPlacement.insertedPageSize(blankGeometry)), for: .mediaBox)
            }
            pdf.insert(page, at: index)
        }
    }

    func go(to index: Int) {
        guard let page = pdf.page(at: index) else { return }
        if let view { view.go(to: page) } else { pending = index }
    }

    func isInserted(_ index: Int) -> Bool { document.pages[index].sourcePage == nil }

    func register(_ overlay: InkOverlayView, at index: Int) { overlays[index] = WeakOverlay(view: overlay) }

    /// Only ink changed: the same PDF file and the same pages in the same order.
    func canUpdate(to fresh: Document) -> Bool {
        fresh.pdfFile?.hash == document.pdfFile?.hash && fresh.pages.map(\.id) == document.pages.map(\.id)
    }

    /// Changed ink stays on screen until its replacement has loaded.
    func update(to fresh: Document) {
        let old = document
        document = fresh
        for (index, page) in fresh.pages.enumerated() where fresh.inkFile(page)?.hash != old.inkFile(page)?.hash {
            loading.remove(index)
            if fresh.inkFile(page) == nil {
                ink[index] = nil
                overlays[index]?.view?.needsDisplay = true
            } else if ink[index] != nil || overlays[index]?.view != nil {
                // only pages that were viewed; the rest load when they come on screen
                load(index)
            }
        }
    }

    /// The page's ink, starting to load it on first use; its overlay redraws once it arrives.
    func ink(for index: Int) -> NormalizedPage? {
        if ink[index] == nil { load(index) }
        return ink[index]
    }

    private func load(_ index: Int) {
        guard document.pages.indices.contains(index), document.inkFile(document.pages[index]) != nil,
              loading.insert(index).inserted else { return }
        let (document, blobs, ref) = (document, blobs, document.pages[index])
        Task {
            let page = try? await document.ink(ref, blobs: blobs)
            // a newer document replaced this ink while it loaded, and loads its own
            guard self.document.inkFile(ref)?.hash == document.inkFile(ref)?.hash else { return }
            loading.remove(index)
            // ponytail: a page whose ink fails to load shows none until something redraws it (zoom, scroll back),
            // which retries; no per-page error yet
            guard let page else { return }
            ink[index] = page
            overlays[index]?.view?.needsDisplay = true
        }
    }

    /// Fix up the links on a page coming on screen. A copied page's jumps lose
    /// their target, so they're pointed again, from the source page's, at the
    /// page showing it here. An EPUB's chapter links are remembered for `follow`.
    func prepareLinks(at index: Int) {
        guard linksPrepared.insert(index).inserted, let page = pdf.page(at: index) else { return }
        let original = document.pages[index].sourcePage.flatMap { source.page(at: $0 - 1) }
        let originals = original?.annotations ?? []
        let copies = page.annotations
        for (offset, annotation) in copies.enumerated() {
            let original = originals.count == copies.count && originals[offset].bounds == annotation.bounds ? originals[offset] : nil
            if let original, original.action is PDFActionGoTo || original.destination != nil {
                // a jump to a page no longer in the document goes nowhere
                annotation.action = retargeted(original).map { PDFActionGoTo(destination: $0) }
            } else if let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url, url.scheme == nil {
                // the first link to a chapter wins (a table of contents comes first); a link that wraps
                // is one annotation per line on the same page, so there keep the longest text
                let title = page.selection(for: annotation.bounds)?.string ?? ""
                let known = chapterLinks[url.absoluteString]
                if known == nil || known?.index == index && title.count > known!.title.count {
                    chapterLinks[url.absoluteString] = (index, title)
                }
            }
        }
    }

    /// An original annotation's jump, pointed at the page showing its target here.
    private func retargeted(_ original: PDFAnnotation) -> PDFDestination? {
        guard let target = (original.action as? PDFActionGoTo)?.destination ?? original.destination,
              let page = target.page, case let number = source.index(for: page), number != NSNotFound,
              let mapped = indexOfSource[number + 1].flatMap({ pdf.page(at: $0) }) else { return nil }
        return PDFDestination(page: mapped, at: target.point)
    }

    /// Follow a link with no scheme: an EPUB chapter, found by its title.
    func follow(_ url: URL) {
        guard let link = chapterLinks[url.absoluteString] else { return }
        let after = document.pages[link.index].sourcePage.map { $0 - 1 } ?? -1
        Task {
            let starts = await sourcePageStarts()
            guard let start = ChapterLinks.chapterStart(title: link.title, pageStarts: starts, after: after),
                  let index = indexOfSource[start + 1] else { return }
            go(to: index)
        }
    }

    /// Each source page's opening letters, read once, off the main thread, from a copy of the PDF.
    private func sourcePageStarts() async -> [String] {
        if pageStarts == nil {
            let data = sourceData
            pageStarts = Task.detached(priority: .userInitiated) {
                guard let copy = PDFKit.PDFDocument(data: data) else { return [] }
                return (0..<copy.pageCount).map { ChapterLinks.letters((copy.page(at: $0)?.string ?? "").prefix(300)) }
            }
        }
        return await pageStarts!.value
    }
}

/// PDFView with an ink overlay on every page.
struct PDFKitView: NSViewRepresentable {
    let model: PDFModel
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model, currentIndex: $currentIndex) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.pageOverlayViewProvider = context.coordinator
        view.delegate = context.coordinator
        // observe first: handing the model its view runs any page jump it was holding
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        view.document = model.pdf
        model.view = view
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    // PDFKit calls both on the main thread; @preconcurrency checks that at run time
    @MainActor final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, @preconcurrency PDFViewDelegate {
        let model: PDFModel
        let currentIndex: Binding<Int>

        init(model: PDFModel, currentIndex: Binding<Int>) {
            self.model = model
            self.currentIndex = currentIndex
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
            let index = model.pdf.index(for: page)
            let overlay = InkOverlayView(model: model, index: index, page: page)
            model.register(overlay, at: index)
            model.prepareLinks(at: index)
            return overlay
        }

        /// Only web, mail and Remora links leave the document; PDFKit would hand anything else to
        /// the system, which fails on an EPUB's chapter file names.
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto": NSWorkspace.shared.open(url)
            case "rmr": Router.shared.handle(url)
            case nil: model.follow(url)
            default: break
            }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let page = view.currentPage else { return }
            let index = model.pdf.index(for: page)
            // a jump made inside a SwiftUI update posts this synchronously; state set then is dropped
            DispatchQueue.main.async { self.currentIndex.wrappedValue = index }
        }
    }
}

/// Draws one page's ink and highlights, as vectors, in the page's own frame.
// ponytail: the overlay is the page's size, so v6 ink drawn past the page edge is cut off; outset it if that matters
final class InkOverlayView: NSView {
    private let model: PDFModel
    private let index: Int
    private let page: PDFPage

    init(model: PDFModel, index: Int, page: PDFPage) {
        self.model = model
        self.index = index
        self.page = page
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // ink coordinates run top-left, y down
    override var isFlipped: Bool { true }
    // the overlay is for looking at; clicks and text selection go to the PDF underneath
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let ink = model.ink(for: index)
        let inserted = model.isInserted(index)
        guard ink != nil || inserted, let context = NSGraphicsContext.current?.cgContext else { return }
        // the page as displayed: its crop box with any rotation applied
        let crop = page.bounds(for: .cropBox).size
        let rotation = (page.rotation % 360 + 360) % 360
        let displayed = rotation % 180 == 0 ? crop : CGSize(width: crop.height, height: crop.width)
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: bounds.width / crop.width, y: bounds.height / crop.height)
        // PDFKit lays the overlay on the page before its /Rotate turns it, but ink is drawn on
        // the page as shown: map the shown page back onto the unturned one
        context.concatenate(Self.unturn(rotation, crop))
        // an inserted page is the screen at the v6 scale, with its template as on a notebook page
        if inserted, let template = PageTemplate(name: model.document.pages[index].template, page: model.blankGeometry) {
            context.saveGState()
            context.scaleBy(x: PDFPlacement.pointsPerPixel, y: PDFPlacement.pointsPerPixel)
            template.draw(in: context, page: model.blankGeometry)
            context.restoreGState()
        }
        guard let ink else { return }
        context.concatenate(PDFPlacement.transform(for: ink, displayed: displayed))
        try? FlatRenderer.draw(ink, in: context)
    }

    /// From the page as shown (turned clockwise by `rotation`) to the unturned page, both top-left, y down.
    private static func unturn(_ rotation: Int, _ page: CGSize) -> CGAffineTransform {
        switch rotation {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: page.height)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: page.width, ty: page.height)
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: page.width, ty: 0)
        default: .identity
        }
    }
}
