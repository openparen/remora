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
    /// Called with the email once an unlabelled account's label is looked up.
    @ObservationIgnored private let rememberLabel: (String) -> Void
    /// Loading, then following the account's changes; cancelled when it's removed or re-paired.
    @ObservationIgnored var starting: Task<Void, Never>?

    init(id: String, label: String, sync: AccountSync, rememberLabel: @escaping (String) -> Void) {
        self.id = id
        self.label = label
        self.sync = sync
        self.rememberLabel = rememberLabel
    }

    /// Show the cached library at once, then refresh it from the cloud. An
    /// account paired before labels were kept gets its email looked up once.
    func start() async {
        if library == nil { library = await sync.loadCached() }
        await refresh()
        if label == id, let email = try? await sync.session?.claims().email {
            label = email
            rememberLabel(email)
        }
        // live: refresh whenever the tablet (or anything else) syncs, and on a 30 s poll
        guard let session = sync.session else { return }
        for await _ in session.changes() {
            await refresh()
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
        case CloudError.unauthorized: "reMarkable no longer accepts this pairing. Remove the account and add it again."
        case CloudError.http(429, _): "reMarkable is rate-limiting this account. Try again in a minute."
        case is URLError: "Offline. Showing what was last synced."
        default: "Something went wrong: \(error)"
        }
    }
}

/// Every paired account. Device tokens live in the Keychain, one per account.
@MainActor @Observable final class AccountStore {
    static let shared = AccountStore()

    private(set) var accounts: [AccountState] = []
    private(set) var loaded = false
    /// Set when the Keychain couldn't be read, e.g. access was denied; then
    /// "no accounts" would be a lie.
    private(set) var problem: String?
    private let keychain = Keychain()

    func load() {
        guard !loaded else { return }
        defer { loaded = true }
        let denied = "Remora couldn't read its accounts from the Keychain. Relaunch Remora and allow access when macOS asks."
        guard let ids = try? keychain.accounts() else {
            problem = denied
            return
        }
        for id in ids {
            // one unreadable item mustn't hide the other accounts
            guard let token = try? keychain.get(account: id) else {
                problem = denied
                continue
            }
            add(id: id, label: (try? keychain.label(account: id)) ?? id, session: CloudSession(deviceToken: token))
        }
    }

    /// Pair with a one-time code from my.remarkable.com/device/desktop/connect.
    /// Pairing an account that's already here replaces its token.
    func pair(code: String) async throws {
        let token = try await AuthClient().register(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let id = try TokenClaims(jwt: token).userID else { throw CloudError.malformed("the device token has no account id") }
        // the code is spent once register succeeds: store the token before anything else can fail
        try keychain.set(token, account: id)
        let session = CloudSession(deviceToken: token)
        let email = (try? await session.claims())?.email
        if let email { try? keychain.set(token, account: id, label: email) }
        accounts.first { $0.id == id }?.starting?.cancel()
        accounts.removeAll { $0.id == id }
        add(id: id, label: email ?? id, session: session)
        problem = nil
    }

    /// Forget an account: its token, and its cached files.
    func remove(_ account: AccountState) {
        account.starting?.cancel()
        try? keychain.delete(account: account.id)
        try? FileManager.default.removeItem(at: BlobCache.directory(account: account.id).deletingLastPathComponent())
        accounts.removeAll { $0.id == account.id }
    }

    func refreshAll() async {
        for account in accounts { await account.refresh() }
    }

    /// The account and item a document or folder id belongs to.
    func locate(_ id: String) -> (account: AccountState, item: LibraryItem)? {
        for account in accounts { if let item = account.library?.items[id] { return (account, item) } }
        return nil
    }

    /// True while a library may still arrive or change, so "not found" can't be said yet.
    var stillLoading: Bool {
        !loaded || accounts.contains { $0.syncing || ($0.library == nil && $0.problem == nil) }
    }

    static func describePairing(_ error: Error) -> String {
        switch error {
        case CloudError.http(400, _), CloudError.http(404, _), CloudError.unauthorized:
            "reMarkable didn't accept that code. Codes are single-use and expire quickly; get a new one."
        case CloudError.http(429, _): "reMarkable is rate-limiting pairing. Wait a minute and try again."
        case is URLError: "Couldn't reach reMarkable. Check the connection and try again."
        case is Keychain.Failure: "Paired, but the token couldn't be saved to the Keychain."
        default: "Pairing failed: \(error)"
        }
    }

    private func add(id: String, label: String, session: CloudSession) {
        let keychain = keychain
        let state = AccountState(id: id, label: label, sync: AccountSync(account: id, session: session)) { email in
            guard let token = try? keychain.get(account: id) else { return }
            try? keychain.set(token, account: id, label: email)
        }
        accounts.append(state)
        state.starting = Task { await state.start() }
    }
}
