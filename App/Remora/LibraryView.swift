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
    @State private var selected: Set<LibraryItem.ID> = []
    private let store = AccountStore.shared
    private let router = Router.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $place) {
                ForEach(store.accounts) { account in
                    Section(account.label) {
                        Label("Library", systemImage: "books.vertical").tag(Place(account: account.id, folder: ""))
                        Label("Pinned", systemImage: "pin").tag(Place(account: account.id, folder: Place.pinned))
                        if let library = account.library {
                            OutlineGroup(library.folders(), children: \.children) { folder in
                                Label(folder.name, systemImage: "folder").tag(Place(account: account.id, folder: folder.id))
                            }
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
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refreshAll() } }
                .keyboardShortcut("r")
        }
        .sheet(isPresented: $pairing) { PairingSheet() }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear {
            router.attach(openWindow)
            if store.accounts.isEmpty && store.loaded { pairing = true }
        }
        .onChange(of: store.accounts.first?.id) { if place == nil, let id = $1 { place = Place(account: id, folder: "") } }
        .onChange(of: router.folderRequest) { _, id in
            guard let id, let (account, _) = store.locate(id) else { return }
            search = ""
            place = Place(account: account.id, folder: id)
        }
    }

    @ViewBuilder private var detail: some View {
        if store.accounts.isEmpty {
            ContentUnavailableView {
                Label("No reMarkable account", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Pair Remora with your reMarkable cloud account to see your library.")
            } actions: {
                Button("Add Account…") { pairing = true }
            }
        } else if let place, let account = store.accounts.first(where: { $0.id == place.account }) {
            VStack(spacing: 0) {
                if let problem = account.problem {
                    Text(problem).font(.callout).padding(8).frame(maxWidth: .infinity).background(.yellow.opacity(0.25))
                }
                if let library = account.library {
                    ItemTable(items: items(in: library, at: place), library: library, selection: $selected) { item in
                        if item.kind == .folder {
                            search = ""
                            self.place = Place(account: account.id, folder: item.id)
                        } else {
                            router.open(.document(id: item.id, page: nil))
                        }
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
        // folders first, then documents, each by name
        return library.children(of: place.folder).filter { $0.kind != .template }
            .sorted { ($0.kind == .folder ? 0 : 1, $0.name) < ($1.kind == .folder ? 0 : 1, $1.name) }
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
        Table(items, selection: $selection) {
            TableColumn("Name") { item in
                Label(item.name, systemImage: icon(item.kind))
            }
            TableColumn("Modified") { item in
                Text(item.lastModified?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
            .width(min: 120, ideal: 160)
            TableColumn("Kind") { item in Text(item.kind.rawValue.capitalized) }
                .width(min: 60, ideal: 80)
            TableColumn("Pages") { item in Text(item.pageCount.map(String.init) ?? "") }
                .width(min: 40, ideal: 50)
        }
        .contextMenu(forSelectionType: LibraryItem.ID.self) { ids in
            if let id = ids.first, let item = library.items[id] {
                Button("Open") { open(item) }
                Divider()
                Button("Copy Link") { Clipboard.copy(link(item).url.absoluteString) }
                Button("Copy as Markdown Link") { Clipboard.copy(link(item).markdown(title: item.name)) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = library.items[id] { open(item) }
        }
    }

    private func link(_ item: LibraryItem) -> RemoraLink {
        item.kind == .folder ? .folder(id: item.id) : .document(id: item.id, page: nil)
    }

    private func icon(_ kind: LibraryItem.Kind) -> String {
        switch kind {
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
                            problem = AccountState.describe(error)
                            working = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespaces).count != 8 || working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
