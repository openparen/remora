import Foundation
import Testing
@testable import RMKit

/// Against the real cloud, opt-in: `REMORA_LIVE_TOKEN=<device token> swift test --filter LiveTests`.
/// With `REMORA_LIVE_SVG_DIR` set, the rendered pages are written as
/// `<dir>/<doc-id>/<page-id>.svg` for scripts/golden-live.sh to diff against rm2agent.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REMORA_LIVE_TOKEN"] != nil))
struct LiveTests {
    @Test func readsTheLibraryAndRendersRecentNotebooks() async throws {
        let environment = ProcessInfo.processInfo.environment
        let token = try #require(environment["REMORA_LIVE_TOKEN"])
        let account = try TokenClaims(jwt: token).userID ?? "live"
        let session = CloudSession(deviceToken: token)
        let blobs = BlobStore(cache: BlobCache(directory: BlobCache.directory(account: account))) { hash, name in
            try await session.file(hash: hash, name: name)
        }
        let library = try await Library.build(root: try await session.root(), blobs: blobs)
        #expect(library.failures.isEmpty, "\(library.failures)")
        #expect(!library.items.isEmpty)

        let count = Int(environment["REMORA_LIVE_DOCS"] ?? "") ?? 3
        let notebooks = library.items.values
            .filter { $0.kind == .notebook && $0.parent != "trash" }
            .sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
            .prefix(count)
        for item in notebooks {
            let document = try await Document.load(item, blobs: blobs)
            for page in document.pages {
                guard let ink = try await document.ink(page, blobs: blobs) else { continue }
                #expect(!ink.drops.isLossy, "\(library.path(of: item.id)) page \(page.number): \(ink.drops)")
                let svg = try SVG.render(ink)
                if let dir = environment["REMORA_LIVE_SVG_DIR"] {
                    let folder = URL(filePath: dir).appending(path: item.id)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try svg.write(to: folder.appending(path: "\(page.id).svg"), atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
