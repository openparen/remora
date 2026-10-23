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
    /// Clockwise quarter turns, remembered per document.
    @State private var turns: Int
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
            .onChange(of: router.pageRequest[item.id]?.nonce) { go(to: router.pageRequest[item.id]?.page) }
    }

    @ViewBuilder private var content: some View {
        if let model {
            VStack(spacing: 0) {
                if missingPage { Banner("The linked page is no longer in this document.") }
                if model.document.pages.first?.provisional == true {
                    Banner("Links to single pages work once this document has been opened on the tablet.")
                }
                // a new model is a new PDF: give it a new view rather than one still showing the old
                PDFKitView(model: model, item: item, turns: turns, dark: darkPages && colorScheme == .dark, currentIndex: $currentIndex)
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
        DocumentDragHandle(item: item)
        ToolbarItemGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { model?.view?.zoomOut(nil) }
                .keyboardShortcut("-")
            Button("Fit Width", systemImage: "arrow.left.and.right") { model?.view?.autoScales = true }
                .keyboardShortcut("0")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { model?.view?.zoomIn(nil) }
                .keyboardShortcut("=")
            Button("Rotate", systemImage: "rotate.right") {
                turns = (turns + 1) % 4
                ViewTurns.set(item.id, turns)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Turn the pages a quarter clockwise")
            .accessibilityValue("\(turns * 90) degrees")
            Button("Copy Link to Page", systemImage: "link") { Clipboard.copy(currentLink.url.absoluteString) }
                .keyboardShortcut("l")
            Menu("More Links", systemImage: "ellipsis.circle") {
                Button("Copy as Markdown Link") {
                    Clipboard.copy(currentLink.markdown(title: item.name, pageNumber: currentPage?.linkID == nil ? nil : currentPage?.number))
                }
                Button("Copy Link to Document") { Clipboard.copy(RemoraLink.document(id: item.id, page: nil).url.absoluteString) }
            }
        }
    }

    private var currentPage: PageRef? {
        guard let pages = model?.document.pages, pages.indices.contains(currentIndex) else { return nil }
        return pages[currentIndex]
    }

    private var currentLink: RemoraLink { .document(id: item.id, page: currentPage?.linkID) }

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
            if let model, case let covered = document.coveringSource(pageCount: model.sourcePageCount), model.canUpdate(to: covered) {
                model.update(to: covered)
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
            // a fresh upload's placeholder page list only knows the PDF's first page
            let covered = document.coveringSource(pageCount: source.pageCount)
            // pages were added, removed or moved: rebuild, staying on the page that was being read;
            // a provisional page has no id the tablet's page list knows, only its place in the PDF
            let reading = currentPage
            let fresh = PDFModel(document: covered, source: source, sourceData: data, blobs: account.sync.blobs)
            model = fresh
            currentIndex = 0
            let index = covered.pages.firstIndex { $0.id == reading?.id }
                ?? (reading?.provisional == true ? covered.pages.firstIndex { $0.sourcePage == reading?.sourcePage } : nil)
            if let index { fresh.go(to: index) }
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
    /// Each page's own /Rotate, as the tablet shows it; the view's turns come on top.
    private var baseRotation: [Int] = []
    private(set) var turns = 0
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
            baseRotation.append((page.rotation % 360 + 360) % 360)
        }
    }

    var sourcePageCount: Int { source.pageCount }

    /// The page's /Rotate as the tablet shows it, without the view's turns.
    func baseRotation(_ index: Int) -> Int { baseRotation.indices.contains(index) ? baseRotation[index] : 0 }

    /// Turn every page `turns` quarters clockwise past its own rotation, staying on the place being read.
    func turn(to turns: Int) {
        guard turns != self.turns else { return }
        self.turns = turns
        let reading = view?.currentDestination
        for (index, base) in baseRotation.enumerated() { pdf.page(at: index)?.rotation = (base + 90 * turns) % 360 }
        view?.layoutDocumentView()
        if let reading { view?.go(to: reading) }
    }

    /// The page as shown, with its ink and the view's turns, at twice its size in points.
    func image(at index: Int) async -> PageImage? {
        guard document.pages.indices.contains(index) else { return nil }
        let (ref, document, blobs, turns, data) = (document.pages[index], document, blobs, turns, sourceData)
        guard let number = ref.sourcePage else {
            // an inserted page is the screen at the v6 scale, as in the view
            let image = (try? await document.render(ref, scale: 2 * PDFPlacement.pointsPerPixel, blobs: blobs))?.image
            return await Task.detached { image?.turned(turns) }.value.map { PageImage(image: $0, pixelsPerPoint: 2) }
        }
        let ink = try? await document.ink(ref, blobs: blobs)
        return await Task.detached { () -> CGImage? in
            // from a PDF of its own: the view's pages share their CGPDFPage with the source,
            // and turning them turns it, which would count the turns twice
            guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: number) else { return nil }
            let crop = page.getBoxRect(.cropBox).size
            let width = page.rotationAngle % 180 == 0 ? crop.width : crop.height
            return Thumbnail.pdfPage(page, ink: ink, width: width * 2)?.turned(turns)
        }.value.map { PageImage(image: $0, pixelsPerPoint: 2) }
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
    let item: LibraryItem
    let turns: Int
    /// Pages recoloured for Dark Mode; what's around them keeps its own colour.
    let dark: Bool
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model, item: item, currentIndex: $currentIndex) }

    func makeNSView(context: Context) -> PDFView {
        let view = PagePDFView()
        // turned before the first layout, so a held page jump lands where it should
        model.turn(to: turns)
        view.pageMenu = { [coordinator = context.coordinator] index in coordinator.menuItems(for: index) }
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
        Self.recolour(view, dark: dark)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        model.turn(to: turns)
        Self.recolour(view, dark: dark)
    }

    /// The filter goes on the pages' view, not the PDFView: the gaps between pages are
    /// see-through there, so the background shows unfiltered.
    private static func recolour(_ view: PDFView, dark: Bool) {
        guard let pages = view.documentView, dark == pages.contentFilters.isEmpty else { return }
        pages.wantsLayer = true
        pages.layerUsesCoreImageFilters = true
        pages.contentFilters = dark ? [DarkPage.filter()] : []
        // the filter would turn the black shadow into a light halo
        view.pageShadowsEnabled = !dark
    }

    // PDFKit calls both on the main thread; @preconcurrency checks that at run time
    @MainActor final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, @preconcurrency PDFViewDelegate {
        let model: PDFModel
        let item: LibraryItem
        let currentIndex: Binding<Int>

        init(model: PDFModel, item: LibraryItem, currentIndex: Binding<Int>) {
            self.model = model
            self.item = item
            self.currentIndex = currentIndex
        }

        /// What a right-click on page `index` offers, above PDFKit's own items.
        func menuItems(for index: Int) -> [NSMenuItem] {
            guard model.document.pages.indices.contains(index) else { return [] }
            let (page, item, model) = (model.document.pages[index], item, model)
            let link = RemoraLink.document(id: item.id, page: page.linkID)
            return [
                ActionMenuItem("Copy Link to This Page") { Clipboard.copy(link.url.absoluteString) },
                ActionMenuItem("Copy as Markdown Link") {
                    Clipboard.copy(link.markdown(title: item.name, pageNumber: page.linkID == nil ? nil : page.number))
                },
                ActionMenuItem("Copy Link to Document") { Clipboard.copy(RemoraLink.document(id: item.id, page: nil).url.absoluteString) },
                .separator(),
                ActionMenuItem("Copy Page as Image") { Task { PageImage.copy(await model.image(at: index)) } },
                ActionMenuItem("Save Page as Image…") {
                    Task { await PageImage.save(await model.image(at: index), name: "\(item.name) p\(page.number)") }
                },
            ]
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

/// PDFView whose right-click menu starts with the clicked page's own actions.
final class PagePDFView: PDFView {
    var pageMenu: ((Int) -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let document, let page = page(for: convert(event.locationInWindow, from: nil), nearest: true),
              let items = pageMenu?(document.index(for: page)), !items.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
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
        // the page's own rotation: the view's turns rotate the overlay along with the page
        let rotation = model.baseRotation(index)
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

extension PageRef {
    /// The id a link to this page uses: none for a page whose id the tablet hasn't given yet.
    var linkID: String? { provisional ? nil : id }
}
