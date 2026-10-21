import Foundation
import RMKit

/// Developer tool: pair, list and render from the terminal.
@main
struct RemoraCLI {
    static let usage = """
        usage: remora-cli pair <code>        pair an account (code from my.remarkable.com)
               remora-cli accounts            list paired accounts
               remora-cli ls                  list the library
               remora-cli dump <doc-id> <dir> write the document's raw files
               remora-cli svg <doc-id> <dir>  render inked pages as <page-id>.svg
               remora-cli png <doc-id> <dir>  render inked pages as <page-id>.png
        Set REMORA_ACCOUNT to pick an account when more than one is paired.
        """

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String]) async throws {
        let keychain = Keychain()
        switch (args.first, args.count) {
        case ("pair", 2):
            let deviceToken = try await AuthClient().register(code: args[1])
            guard let user = try TokenClaims(jwt: deviceToken).userID else {
                throw CloudError.malformed("the device token has no auth0-userid")
            }
            try keychain.set(deviceToken, account: user)
            let email = try await CloudSession(deviceToken: deviceToken).claims().email
            print("paired \(email ?? user)")
        case ("accounts", 1):
            for account in try keychain.accounts() { print(account) }
        case ("ls", 1):
            let (_, library) = try await open(keychain)
            let items = library.items.values.filter { $0.parent != "trash" && $0.kind != .template }
            for item in items.sorted(by: { library.path(of: $0.id) < library.path(of: $1.id) }) {
                print("\(item.id)  \(item.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(library.path(of: item.id))")
            }
            for (id, why) in library.failures { FileHandle.standardError.write(Data("unreadable \(id): \(why)\n".utf8)) }
        case ("dump", 3), ("svg", 3), ("png", 3):
            let (blobs, library) = try await open(keychain)
            guard let item = library.items[args[1]] else { throw CloudError.malformed("no document \(args[1])") }
            let out = URL(filePath: args[2], directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let document = try await Document.load(item, blobs: blobs)
            if args[0] == "dump" {
                for file in document.files {
                    // entry ids are server data: never let one climb out of the output directory
                    guard !file.id.hasPrefix("/"), !file.id.split(separator: "/").contains("..") else {
                        throw CloudError.malformed("refusing to write \(file.id)")
                    }
                    let url = out.appending(path: file.id)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await blobs.data(hash: file.hash, name: file.id).write(to: url)
                }
                print("wrote \(document.files.count) files")
                return
            }
            for page in document.pages {
                guard let ink = try await document.ink(page, blobs: blobs) else { continue }
                if ink.drops.isLossy { print("page \(page.number) (\(page.id)) lost ink: \(ink.drops)") }
                if args[0] == "svg" {
                    try SVG.render(ink).write(to: out.appending(path: "\(page.id).svg"), atomically: true, encoding: .utf8)
                } else {
                    try FlatRenderer.png(try FlatRenderer.image(ink, scale: 1)).write(to: out.appending(path: "\(page.id).png"))
                }
            }
        default:
            print(usage)
        }
    }

    static func open(_ keychain: Keychain) async throws -> (BlobStore, Library) {
        let accounts = try keychain.accounts()
        let wanted = ProcessInfo.processInfo.environment["REMORA_ACCOUNT"]
        guard let account = wanted ?? (accounts.count == 1 ? accounts[0] : nil) else {
            throw CloudError.malformed(accounts.isEmpty ? "no account paired" : "set REMORA_ACCOUNT to one of \(accounts)")
        }
        guard let deviceToken = try keychain.get(account: account) else { throw CloudError.malformed("no token for \(account)") }
        let session = CloudSession(deviceToken: deviceToken)
        let blobs = BlobStore(cache: BlobCache(directory: BlobCache.directory(account: account))) { hash, name in
            try await session.file(hash: hash, name: name)
        }
        return (blobs, try await Library.build(root: try await session.root(), blobs: blobs))
    }
}
