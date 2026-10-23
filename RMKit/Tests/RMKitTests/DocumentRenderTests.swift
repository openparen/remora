#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Testing
@testable import RMKit

@Suite struct DocumentRenderTests {
    @Test func aBlankPageIsItsTemplate() async throws {
        let page = PageRef(id: "p1", number: 1, sourcePage: nil, template: "P Lines medium")
        let document = Document(id: "d", files: [], content: DocumentContent(), pages: [page])
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory())) { _, _ in throw CloudError.offline }
        let (image, template, _) = try await document.render(page, scale: 0.5, blobs: store)
        #expect(template == .lines(spacing: 78.7, top: 177.8))
        #expect(image.width == 702)
        let unknown = PageRef(id: "p2", number: 2, sourcePage: nil, template: "P Checklist")
        #expect(try await document.render(unknown, scale: 0.5, blobs: store).template == nil)
    }

    @Test func findsItsOwnPDF() {
        let files = ["other.pdf", "d.content", "d.pdf", "d/p1.rm"].map { Entry(hash: fakeHash(1), id: $0, subfiles: 0, size: 1) }
        #expect(Document(id: "d", files: files, content: DocumentContent(), pages: []).pdfFile?.id == "d.pdf")
        #expect(Document(id: "d", files: [files[0]], content: DocumentContent(), pages: []).pdfFile == nil)
    }
}
#endif
