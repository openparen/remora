import ImageIO
import RMKit
import SwiftUI
import UniformTypeIdentifiers

/// The library as a grid of first-page thumbnails.
struct ItemGrid: View {
    let items: [LibraryItem]
    let library: Library
    let account: AccountState
    @Binding var selection: Set<LibraryItem.ID>
    let open: (LibraryItem) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 16)], spacing: 20) {
                ForEach(items) { item in
                    ItemCell(item: item, account: account, selected: selection.contains(item.id))
                        .onTapGesture(count: 2) { open(item) }
                        .simultaneousGesture(TapGesture().onEnded { selection = [item.id] })
                        .contextMenu { ItemMenu(item: item, open: open) }
                }
            }
            .padding(20)
        }
        // a click on the background clears the selection, as in Finder
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { selection = [] } }
    }
}

struct ItemCell: View {
    let item: LibraryItem
    let account: AccountState
    let selected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if item.kind == .folder {
                    Image(systemName: "folder.fill").font(.system(size: 100)).foregroundStyle(.secondary)
                } else if let thumbnail {
                    Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFit()
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                } else {
                    Color.white.aspectRatio(3 / 4, contentMode: .fit)
                        .overlay { Image(systemName: item.kind.symbol).font(.title).foregroundStyle(.tertiary) }
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                }
            }
            .frame(height: 170)
            .padding(6)
            .background(selected ? Color.secondary.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
            Text(item.name)
                .font(.callout).lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .contentShape(Rectangle())
        .task(id: item.hash) {
            guard item.kind != .folder else { return }
            thumbnail = await Thumbnails.shared.image(for: item, in: account).map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

/// First-page thumbnails: in memory while Remora runs, and as PNGs beside the
/// account's blob cache, named by the item's hash so an edited document gets a new one.
@MainActor final class Thumbnails {
    static let shared = Thumbnails()
    /// Pixels across; cells show them at up to half that on a Retina screen.
    nonisolated static let width = 360.0
    private let memory: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 400
        return cache
    }()
    private var rendering: [String: Task<CGImage?, Never>] = [:]

    func image(for item: LibraryItem, in account: AccountState) async -> CGImage? {
        if let image = memory.object(forKey: item.hash as NSString) { return image }
        if let task = rendering[item.hash] { return await task.value }
        let (file, blobs) = (Self.file(item, account: account.id), account.sync.blobs)
        // ponytail: carries on when its cell scrolls away, so a fast scroll queues every item it passed; downloads are capped at 8
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            if let image = Self.read(file) { return image }
            guard let document = try? await Document.load(item, blobs: blobs),
                  let image = try? await Thumbnail.render(document, width: Self.width, blobs: blobs) else { return nil }
            Self.write(image, to: file)
            return image
        }
        rendering[item.hash] = task
        let image = await task.value
        rendering[item.hash] = nil
        if let image { memory.setObject(image, forKey: item.hash as NSString) }
        return image
    }

    // ponytail: old thumbnails are never trimmed; they go with the account's cache folder
    nonisolated static func file(_ item: LibraryItem, account: String) -> URL {
        BlobCache.directory(account: account).deletingLastPathComponent().appending(path: "thumbnails/\(item.hash).png")
    }

    nonisolated static func read(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Best effort: a thumbnail that can't be saved is just drawn again next time.
    nonisolated static func write(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
