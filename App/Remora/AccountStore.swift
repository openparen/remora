import Foundation
import RMKit

/// One paired account and its library, as the views see it.
@MainActor @Observable final class AccountState: Identifiable {
    let id: String
    var label: String
    let sync: AccountSync
    private(set) var library: Library?
    private(set) var syncing = false
    private(set) var problem: String?
    private(set) var lastSynced: Date?

    init(id: String, label: String, sync: AccountSync) {
        self.id = id
        self.label = label
        self.sync = sync
    }

    /// Show the cached library at once, then refresh it from the cloud. An
    /// account paired before labels were kept gets its email looked up once.
    func start() async {
        if library == nil { library = await sync.loadCached() }
        await refresh()
        if label == id, let email = try? await sync.session?.claims().email {
            label = email
            AccountStore.shared.remember(label: email, for: id)
        }
    }

    func refresh() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            library = try await sync.refresh()
            lastSynced = .now
            problem = nil
        } catch {
            problem = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case CloudError.noSubscription: "This account has no Connect subscription, so its cloud can't be read."
        case CloudError.unauthorized: "reMarkable no longer accepts this pairing. Remove the account and pair it again."
        case CloudError.http(429, _): "reMarkable is rate-limiting this account. Remora will try again shortly."
        case is URLError: "Offline. Showing what was last synced."
        default: "Sync failed: \(error)"
        }
    }
}

/// Every paired account. Device tokens live in the Keychain, one per account.
@MainActor @Observable final class AccountStore {
    static let shared = AccountStore()

    private(set) var accounts: [AccountState] = []
    private(set) var loaded = false
    private let keychain = Keychain()

    func load() {
        guard !loaded else { return }
        loaded = true
        for id in (try? keychain.accounts()) ?? [] {
            guard let token = try? keychain.get(account: id) else { continue }
            add(id: id, label: (try? keychain.label(account: id)) ?? id, token: token)
        }
    }

    /// Pair with a one-time code from my.remarkable.com/device/desktop/connect.
    func pair(code: String) async throws {
        let token = try await AuthClient().register(code: code.trimmingCharacters(in: .whitespaces))
        guard let id = try TokenClaims(jwt: token).userID else { throw CloudError.malformed("the device token has no account id") }
        // the code is spent once register succeeds: store the token before anything else can fail
        try keychain.set(token, account: id)
        let email = (try? await CloudSession(deviceToken: token).claims())?.email
        if let email { try? keychain.set(token, account: id, label: email) }
        if !accounts.contains(where: { $0.id == id }) { add(id: id, label: email ?? id, token: token) }
    }

    func remember(label: String, for id: String) {
        guard let token = try? keychain.get(account: id) else { return }
        try? keychain.set(token, account: id, label: label)
    }

    func refreshAll() async {
        for account in accounts { await account.refresh() }
    }

    /// The account and item a document or folder id belongs to.
    func locate(_ id: String) -> (account: AccountState, item: LibraryItem)? {
        for account in accounts { if let item = account.library?.items[id] { return (account, item) } }
        return nil
    }

    /// True while some account still has no library at all, so "not found" can't be said yet.
    var stillLoading: Bool { !loaded || accounts.contains { $0.library == nil && ($0.syncing || $0.problem == nil) } }

    private func add(id: String, label: String, token: String) {
        let state = AccountState(id: id, label: label, sync: AccountSync(account: id, session: CloudSession(deviceToken: token)))
        accounts.append(state)
        Task { await state.start() }
    }
}
