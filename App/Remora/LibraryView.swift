import RMKit
import SwiftUI

/// What the sidebar has selected: a folder ("" is the account's top level) or
/// the account's pinned items.
struct Place: Hashable {
    static let pinned = "\u{0}pinned"
    var account: String
    var folder: String
}

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var place: Place?
    @State private var search = ""
    @State private var pairing = false
    @State private var removing: AccountState?
    @State private var selected: Set<LibraryItem.ID> = []
    /// A folder link waiting for a library that knows the folder.
    @State private var pendingFolder: String?
    @AppStorage("libraryShowsGrid") private var showsGrid = false
    private let store = AccountStore.shared
    private let router = Router.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $place) {
                ForEach(store.accounts) { account in
                    Section {
                        Label("Library", systemImage: "books.vertical").tag(Place(account: account.id, folder: ""))
                        Label("Pinned", systemImage: "pin").tag(Place(account: account.id, folder: Place.pinned))
                        if let library = account.library {
                            OutlineGroup(library.folders(), children: \.children) { folder in
                                Label(folder.name, systemImage: "folder").tag(Place(account: account.id, folder: folder.id))
                            }
                        }
                    } header: {
                        Text(account.label).contextMenu {
                            Button("Remove Account…") { removing = account }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button("Add Account", systemImage: "person.badge.plus") { pairing = true }
            }
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search names, tags, folders")
        .toolbar {
            Picker("View", selection: $showsGrid) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Thumbnails", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Show the library as a list or as thumbnails")
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refreshAll() } }
                .keyboardShortcut("r")
        }
        // Finder's shortcuts for its icon and list views
        .background {
            Button("Thumbnails") { showsGrid = true }.keyboardShortcut("1").hidden()
            Button("List") { showsGrid = false }.keyboardShortcut("2").hidden()
        }
        .sheet(isPresented: $pairing) { PairingSheet() }
        .confirmationDialog("Remove this account?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
            Button("Remove Account", role: .destructive) {
                if place?.account == account.id { place = nil }
                store.remove(account)
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { account in
            Text("Remora forgets \(account.label) and its cached files. The documents stay in your reMarkable cloud.")
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear {
            router.attach(openWindow)
            if store.accounts.isEmpty && store.loaded && store.problem == nil { pairing = true }
        }
        .onChange(of: store.accounts.first?.id) { if place == nil, let id = $1 { place = Place(account: id, folder: "") } }
        .onChange(of: router.folderRequest?.nonce) {
            pendingFolder = router.folderRequest?.folder
            showPendingFolder()
        }
        // a folder link that arrived before the libraries did, or before the sync that brings its folder
        .onChange(of: store.stillLoading) { showPendingFolder() }
        .onChange(of: store.accounts.map(\.lastSynced)) { showPendingFolder() }
        .onChange(of: place) {
            search = ""
            selected = []
        }
    }

    private func showPendingFolder() {
        guard let id = pendingFolder, let (account, _) = store.locate(id) else { return }
        pendingFolder = nil
        place = Place(account: account.id, folder: id)
    }

    @ViewBuilder private var detail: some View {
        if let problem = store.problem, store.accounts.isEmpty {
            ContentUnavailableView("Can't read accounts", systemImage: "lock", description: Text(problem))
        } else if store.accounts.isEmpty {
            ContentUnavailableView {
                Label("No reMarkable account", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Pair Remora with your reMarkable cloud account to see your library.")
            } actions: {
                Button("Add Account…") { pairing = true }
            }
        } else if let place, let account = store.accounts.first(where: { $0.id == place.account }) {
            VStack(spacing: 0) {
                if let problem = store.problem { Banner(problem) }
                if let problem = account.problem { Banner(problem) }
                if let library = account.library {
                    let open = { (item: LibraryItem) in
                        if item.kind == .folder {
                            self.place = Place(account: account.id, folder: item.id)
                        } else {
                            router.open(.document(id: item.id, page: nil))
                        }
                    }
                    if showsGrid {
                        ItemGrid(items: items(in: library, at: place), account: account, selection: $selected, open: open)
                    } else {
                        ItemTable(items: items(in: library, at: place), library: library, selection: $selected, open: open)
                    }
                } else {
                    ProgressView("Loading the library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title(for: place, in: account))
            .navigationSubtitle(account.lastSynced.map { "Synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        } else {
            Text("Choose a folder").foregroundStyle(.secondary)
        }
    }

    private func items(in library: Library, at place: Place) -> [LibraryItem] {
        if !search.isEmpty { return library.search(search) }
        if place.folder == Place.pinned {
            return library.items.values.filter { $0.pinned && !library.isInTrash($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        // folders first, then documents; children(of:) already orders each by name, as Finder does
        let items = library.children(of: place.folder).filter { $0.kind != .template }
        return items.filter { $0.kind == .folder } + items.filter { $0.kind != .folder }
    }

    private func title(for place: Place, in account: AccountState) -> String {
        if !search.isEmpty { return "Search" }
        if place.folder == Place.pinned { return "Pinned" }
        if place.folder.isEmpty { return account.label }
        return account.library?.items[place.folder]?.name ?? "Folder"
    }
}

struct ItemTable: View {
    let items: [LibraryItem]
    let library: Library
    @Binding var selection: Set<LibraryItem.ID>
    let open: (LibraryItem) -> Void

    var body: some View {
        Table(of: LibraryItem.self, selection: $selection) {
            TableColumn("Name") { item in
                Label(item.name, systemImage: item.kind.symbol)
            }
            TableColumn("Modified") { item in
                Text(item.lastModified?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
            .width(min: 120, ideal: 160)
            TableColumn("Kind") { item in Text(item.kind.name) }
                .width(min: 60, ideal: 80)
            TableColumn("Pages") { item in Text(item.pageCount.map(String.init) ?? "") }
                .width(min: 40, ideal: 50)
        } rows: {
            ForEach(items) { item in
                TableRow(item).itemProvider { item.link.itemProvider(title: item.dragTitle) }
            }
        }
        .contextMenu(forSelectionType: LibraryItem.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let item = library.items[id] {
                ItemMenu(item: item, open: open)
            }
        } primaryAction: { ids in
            for id in ids { if let item = library.items[id] { open(item) } }
        }
    }

}

/// What an item's context menu offers, in the list and in the grid.
struct ItemMenu: View {
    let item: LibraryItem
    let open: (LibraryItem) -> Void

    var body: some View {
        Button("Open") { open(item) }
        Divider()
        Button("Copy Link") { Clipboard.copy(item.link.url.absoluteString) }
        Button("Copy as Markdown Link") { Clipboard.copy(item.link.markdown(title: item.name)) }
    }
}

extension LibraryItem {
    var link: RemoraLink { kind == .folder ? .folder(id: id) : .document(id: id, page: nil) }
}

extension LibraryItem.Kind {
    /// As people read it: "Notebook", "PDF", "EPUB".
    var name: String {
        switch self {
        case .notebook: "Notebook"
        case .pdf: "PDF"
        case .epub: "EPUB"
        case .folder: "Folder"
        case .template: "Template"
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder"
        case .notebook: "book.closed"
        case .pdf: "doc.richtext"
        case .epub: "book"
        case .template: "square.dashed"
        }
    }
}

struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a reMarkable account").font(.headline)
            Text("Get a one-time code at my.remarkable.com and enter it here. Remora appears in your account as a desktop app.")
                .fixedSize(horizontal: false, vertical: true)
            Link("Open my.remarkable.com/device/desktop/connect",
                 destination: URL(string: "https://my.remarkable.com/device/desktop/connect")!)
            TextField("8-letter code", text: $code).textFieldStyle(.roundedBorder).disabled(working)
            if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pair") {
                    working = true
                    Task {
                        do {
                            try await AccountStore.shared.pair(code: code)
                            dismiss()
                        } catch {
                            problem = AccountStore.describePairing(error)
                            working = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).count != 8 || working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
