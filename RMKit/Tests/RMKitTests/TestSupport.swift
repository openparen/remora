import Foundation
import Synchronization

/// Serves canned responses to URLSession. Each test gets its own host, so
/// tests running in parallel never see each other's handlers.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private static let handlers = Mutex<[String: Handler]>([:])

    /// A session and a unique host whose requests `handler` answers.
    static func make(_ handler: @escaping Handler) -> (URLSession, URL) {
        let host = "\(UUID().uuidString.lowercased()).test"
        handlers.withLock { $0[host] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return (URLSession(configuration: config), URL(string: "https://\(host)")!)
    }

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    // websockets go to the real network: NoticeServer serves them
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme?.hasPrefix("http") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host() ?? ""
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// An unsigned JWT with the given claims.
func jwt(_ claims: [String: Any]) -> String {
    func encode(_ object: Any) -> String {
        try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(["alg": "none"])).\(encode(claims)).sig"
}

/// A fake but well-formed blob hash.
func fakeHash(_ n: Int) -> String { String(format: "%064x", n) }

/// A shared, lockable value for counting calls from `@Sendable` handlers.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    @discardableResult
    func update<R: Sendable>(_ body: @Sendable (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "remora-tests-\(UUID().uuidString)")
}

/// rmscene's sample pages (MIT, see Fixtures/rmscene/LICENSE), each with the
/// SVG rm2agent renders for it, made by scripts/rmscene-goldens.mjs.
enum Fixtures {
    static let rmscene = Bundle.module.resourceURL!.appending(path: "Fixtures/rmscene")

    static func rmsceneNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: rmscene.path())) ?? []
        return files.filter { $0.hasSuffix(".rm") }.map { String($0.dropLast(3)) }.sorted()
    }

    static func data(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: rmscene.appending(path: "\(name).\(ext)"))
    }

    /// A synthetic page made with rmscene by the script next to it, which says how.
    static func anchors(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/anchors/\(name).rm"))
    }

    /// A v5 file: one layer, one ballpoint stroke of two points.
    static func v5() -> Data {
        var data = Data("reMarkable .lines file, version=5".padding(toLength: 43, withPad: " ", startingAt: 0).utf8)
        func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func f32(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        i32(1); i32(1) // layers, lines
        i32(2); i32(0); i32(0); f32(2); i32(0) // ballpoint, black, padding, base size, unknown
        i32(2) // points
        for (x, y) in [(10, 20), (30, 40)] as [(Float, Float)] { f32(x); f32(y); f32(0); f32(0); f32(2.5); f32(0.5) }
        return data
    }
}
