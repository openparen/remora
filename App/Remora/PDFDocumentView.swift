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
    @State private var command: PDFCommand?
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
                PDFKitView(model: model, command: $command, currentIndex: $currentIndex)
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
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { command = .zoomOut }
                .keyboardShortcut("-")
            Button("Fit Width", systemImage: "arrow.left.and.right") { command = .fit }
                .keyboardShortcut("0")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { command = .zoomIn }
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
        command = .go(index)
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
            model = PDFModel(document: document, source: source, blobs: account.sync.blobs)
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            problem = AccountState.describe(error)
        }
    }
}

enum PDFCommand: Equatable {
    case zoomIn, zoomOut, fit
    case go(Int)
}

/// The document's pages as one PDF, in the tablet's order: each page is its
/// source PDF page, or a blank page where one was inserted on the tablet.
/// The ink for each page loads on demand and is kept while the window is open.
@MainActor final class PDFModel {
    private(set) var document: Document
    let pdf = PDFKit.PDFDocument()
    let blobs: BlobStore
    private(set) var ink: [Int: NormalizedPage] = [:]
    private var loading: Set<Int> = []
    /// The overlays on screen, so changed ink can be redrawn in place.
    private var overlays: [Int: WeakOverlay] = [:]
    private struct WeakOverlay { weak var view: InkOverlayView? }

    init(document: Document, source: PDFKit.PDFDocument, blobs: BlobStore) {
        self.document = document
        self.blobs = blobs
        let geometry = PageGeometry(portrait: nil, orientation: document.content.orientation)
        for (index, ref) in document.pages.enumerated() {
            let page: PDFPage
            if let number = ref.sourcePage, let original = source.page(at: number - 1), let copy = original.copy() as? PDFPage {
                page = copy
            } else {
                page = PDFPage()
                page.setBounds(CGRect(origin: .zero, size: PDFPlacement.insertedPageSize(geometry)), for: .mediaBox)
            }
            pdf.insert(page, at: index)
        }
    }

    func isInserted(_ index: Int) -> Bool { document.pages[index].sourcePage == nil }

    func register(_ overlay: InkOverlayView, at index: Int) { overlays[index] = WeakOverlay(view: overlay) }

    /// Only ink changed: the same PDF file and the same pages in the same order.
    func canUpdate(to fresh: Document) -> Bool {
        fresh.pdfFile?.hash == document.pdfFile?.hash && fresh.pages.map(\.id) == document.pages.map(\.id)
    }

    func update(to fresh: Document) {
        let old = document
        document = fresh
        for (index, page) in fresh.pages.enumerated() where fresh.inkFile(page)?.hash != old.inkFile(page)?.hash {
            ink[index] = nil
            loading.remove(index)
            overlays[index]?.view?.needsDisplay = true
        }
    }

    /// The page's ink, loading it on first use; `ready` runs once it has arrived.
    func ink(for index: Int, ready: @escaping @MainActor () -> Void) -> NormalizedPage? {
        if let page = ink[index] { return page }
        guard document.pages.indices.contains(index), loading.insert(index).inserted else { return nil }
        let (document, blobs, ref) = (document, blobs, document.pages[index])
        Task {
            if let page = try? await document.ink(ref, blobs: blobs) {
                // a newer document may have replaced this ink while it loaded
                guard self.document.inkFile(ref)?.hash == document.inkFile(ref)?.hash else { return }
                ink[index] = page
                ready()
            }
        }
        return nil
    }
}

/// PDFView with an ink overlay on every page.
struct PDFKitView: NSViewRepresentable {
    let model: PDFModel
    @Binding var command: PDFCommand?
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model, currentIndex: $currentIndex) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.pageOverlayViewProvider = context.coordinator
        view.document = model.pdf
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let command else { return }
        switch command {
        case .zoomIn: view.zoomIn(nil)
        case .zoomOut: view.zoomOut(nil)
        case .fit: view.autoScales = true
        case .go(let index): if let page = model.pdf.page(at: index) { view.go(to: page) }
        }
        DispatchQueue.main.async { self.command = nil }
    }

    // PDFKit asks for overlays on the main thread; @preconcurrency checks that at run time
    @MainActor final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider {
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
            return overlay
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
        guard let ink = model.ink(for: index, ready: { [weak self] in self?.needsDisplay = true }),
              let context = NSGraphicsContext.current?.cgContext else { return }
        // the page as displayed: its crop box with any rotation applied
        let crop = page.bounds(for: .cropBox).size
        let displayed = page.rotation % 180 == 0 ? crop : CGSize(width: crop.height, height: crop.width)
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: bounds.width / displayed.width, y: bounds.height / displayed.height)
        context.concatenate(PDFPlacement.transform(for: ink, displayed: displayed))
        if model.isInserted(index), let template = PageTemplate(name: model.document.pages[index].template, page: ink.geometry) {
            template.draw(in: context, page: ink.geometry)
        }
        try? FlatRenderer.draw(ink, in: context)
    }
}
