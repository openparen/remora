import RMKit
import SwiftUI

/// A document's window: finds the document in whichever account has it.
struct DocumentWindow: View {
    let link: DocumentLink
    private let store = AccountStore.shared

    var body: some View {
        Group {
            if let (account, item) = store.locate(link.docID) {
                switch item.kind {
                case .notebook:
                    NotebookView(account: account, item: item, firstPage: link.pageID)
                case .pdf, .epub:
                    ContentUnavailableView("\(item.name)", systemImage: "doc.richtext",
                                           description: Text("PDF and EPUB viewing arrives in the next build."))
                case .folder, .template:
                    ContentUnavailableView("Not a document", systemImage: "folder")
                }
            } else if store.stillLoading {
                ProgressView("Loading the library…")
            } else {
                ContentUnavailableView("Document not found", systemImage: "questionmark.folder",
                                       description: Text("No paired account has this document. It may have been deleted."))
            }
        }
        .frame(minWidth: 480, minHeight: 600)
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
    @State private var visiblePage: String?
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
            GeometryReader { geometry in
                let width = max(200, (geometry.size.width - 48) * zoom * pinch)
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(spacing: 16) {
                            ForEach(document.pages, id: \.id) { page in
                                PageView(document: document, page: page, blobs: account.sync.blobs, width: width)
                                    .id(page.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(24)
                        .frame(minWidth: geometry.size.width)
                    }
                    // the topmost page more than a third on screen is "the current page"
                    .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.33) { visible in
                        visiblePage = document.pages.first { visible.contains($0.id) }?.id
                    }
                    .gesture(MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { zoom = clampZoom(zoom * $0.magnification) })
                    .onAppear { if let firstPage { proxy.scrollTo(firstPage, anchor: .top) } }
                    .onChange(of: router.pageRequest[item.id]?.nonce) {
                        if let page = router.pageRequest[item.id]?.page {
                            withAnimation { proxy.scrollTo(page, anchor: .top) }
                        }
                    }
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        } else if let problem {
            ContentUnavailableView("Can't open \(item.name)", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else {
            ProgressView()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = clampZoom(zoom / 1.25) }
                .keyboardShortcut("-")
            Button("Actual Width", systemImage: "arrow.left.and.right") { zoom = 1 }
                .keyboardShortcut("0")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = clampZoom(zoom * 1.25) }
                .keyboardShortcut("+")
            Menu("Share", systemImage: "link") {
                Button("Copy Link to Page") { Clipboard.copy(currentLink.url.absoluteString) }
                    .keyboardShortcut("l")
                Button("Copy as Markdown Link") {
                    Clipboard.copy(currentLink.markdown(title: item.name, pageNumber: currentPage?.number))
                }
                Button("Copy Link to Document") { Clipboard.copy(RemoraLink.document(id: item.id, page: nil).url.absoluteString) }
            }
        }
    }

    private var currentPage: PageRef? {
        document?.pages.first { $0.id == visiblePage } ?? document?.pages.first
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
        } catch {
            problem = AccountState.describe(error)
        }
    }
}

/// One page, rendered off the main thread at the size it's shown.
struct PageView: View {
    let document: Document
    let page: PageRef
    let blobs: BlobStore
    let width: Double

    @Environment(\.displayScale) private var displayScale
    @State private var rendered: (image: CGImage, template: PageTemplate?, drops: PageDrops)?
    @State private var problem: String?

    var body: some View {
        let height = rendered.map { width * Double($0.image.height) / Double($0.image.width) } ?? width * 4 / 3
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
        .frame(width: width, height: height)
        .background(Color.white)
        .shadow(radius: 2)
        // re-render when the shown width changes by a step, not on every pixel of a resize
        .task(id: RenderKey(page: page.id, ink: document.inkFile(page)?.hash, width: Int(width * displayScale / 256))) {
            await render()
        }
    }

    private struct RenderKey: Hashable { let page: String; let ink: String?; let width: Int }

    private func render() async {
        let pixels = (width * displayScale / 256).rounded(.up) * 256
        let pageWidth = document.content.orientation == .landscape ? 1872.0 : 1404.0
        let scale = min(4, pixels / pageWidth)
        let (document, page, blobs) = (document, page, blobs)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await document.render(page, scale: scale, blobs: blobs)
            }.value
            rendered = result
            problem = nil
        } catch {
            problem = AccountState.describe(error)
        }
    }
}
