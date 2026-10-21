import RMKit
import SwiftUI

/// A document's window: finds the document in whichever account has it. A link
/// to something no account knows refreshes every account once before saying so.
struct DocumentWindow: View {
    let link: DocumentLink
    @State private var refreshedForMissing = false
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
                        ContentUnavailableView("\(item.name)", systemImage: "doc.richtext",
                                               description: Text("PDF and EPUB viewing arrives in the next build."))
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
    @GestureState private var pinch = 1.0
    private let router = Router.shared

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
                                     renderWidth: renderWidth, shownWidth: shownWidth)
                                .id(page.id)
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
        ToolbarItemGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = clampZoom(zoom / 1.25) }
                .keyboardShortcut("-")
            Button("Fit Width", systemImage: "arrow.left.and.right") { zoom = 1 }
                .keyboardShortcut("0")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = clampZoom(zoom * 1.25) }
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
        document?.pages.first { $0.id == currentPageID } ?? document?.pages.first
    }

    private var currentLink: RemoraLink { .document(id: item.id, page: currentPage?.id) }

    private var pageLabel: String {
        guard let document, let page = currentPage else { return "" }
        return "Page \(page.number) of \(document.pages.count)"
    }

    private func clampZoom(_ value: Double) -> Double { min(4, max(0.25, value)) }

    private func load() async {
        do {
            document = try await Document.load(item, blobs: account.sync.blobs)
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

    @Environment(\.displayScale) private var displayScale
    @State private var rendered: (image: CGImage, template: PageTemplate?, drops: PageDrops)?
    @State private var problem: String?

    var body: some View {
        let aspect = rendered.map { Double($0.image.height) / Double($0.image.width) }
            ?? (document.content.orientation == .landscape ? 3.0 / 4 : 4.0 / 3)
        ZStack(alignment: .topTrailing) {
            if let rendered {
                Image(decorative: rendered.image, scale: 1).resizable().interpolation(.high)
            } else if let problem {
                Text(problem).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.white
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
        .background(Color.white)
        .shadow(radius: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(page.number)")
        // re-render when the settled width moves a step, not on every pixel of a resize
        .task(id: RenderKey(page: page.id, ink: document.inkFile(page)?.hash, template: page.template,
                            width: Int(renderWidth * displayScale / 256))) {
            await render()
        }
        .onDisappear { rendered = nil }
    }

    private struct RenderKey: Hashable {
        let page: String
        let ink: String?
        let template: String?
        let width: Int
    }

    private func render() async {
        let pixels = (renderWidth * displayScale / 256).rounded(.up) * 256
        let pageWidth = document.content.orientation == .landscape ? 1872.0 : 1404.0
        var scale = min(4, pixels / pageWidth)
        // ponytail: one bitmap per page, so ink dragged far off the page halves the scale until it fits; tile for deep zoom
        for _ in 0..<4 {
            do {
                let result = try await document.render(page, scale: scale, blobs: blobs)
                guard !Task.isCancelled else { return }
                rendered = result
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
