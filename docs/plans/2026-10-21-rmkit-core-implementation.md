# RMKit core: implementation plan (Remora plan 1 of 3)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** `RMKit`, the headless core of Remora: pairing, Keychain, the read-only cloud client, the content-addressed cache, the library index, the page map, the `.rm` v3/v5/v6 parser and flat ink rendering (SVG and Core Graphics). It also includes a `remora-cli` for checking all of it against the real account.

**Architecture:** One Swift package, `RMKit/`, at the repo root, with a library target, a `remora-cli` executable and a Swift Testing target. It is a straight port of what rm2agent proved:
- the cloud client follows rmapi-js's protocol;
- the parser follows rmapi-js's `rm6.js`/`rm5.js` (themselves from rmscene);
- normalization and SVG follow rm2agent's `src/render/*`.

rm2agent's SVG output is the oracle: the golden test requires byte-identical SVG.

**Tech stack:** Swift 6.2 tools (Swift 6.4 / Xcode 27 installed), macOS 26, Foundation, Security, CoreGraphics, ImageIO, Swift Testing. No third-party dependencies.

**Design:** `docs/plans/2026-10-21-remora-design.md`. This plan covers M0's scaffolding and M1 build steps 1–2 ("cloud read path" and "parser and flat renderer, plus the golden check"). Plan 2 covers the app (library window, document window, links, live view, offline mode); plan 3 covers writes, sharing and PDF export. Each is written once the previous one has landed, against the real API it produced.

**Proven:** every file below was compiled, and every test run, in a scratch package before this plan was written. A script built the package task by task, in this order, and ran the tests at each step. The live test and the live golden diff ran against the user's account.

---

## Before you start

- Work in `/Users/gve/workbee/codez/Projects/remora` on a branch: `git checkout -b feat/rmkit-core`.
- You need the rm2agent checkout at `/Users/gve/workbee/codez/Projects/rm2agent`, built (`npm run build` there), for Task 1's golden SVGs. You also need `node`, `jq` and `git`.
- All test commands run from the repo root: `swift test --package-path RMKit [--filter <Suite>]`.
- The user's own fixtures notebook (M0 in the design: every pen and colour, a landscape page, a large-format PDF, an EPUB) **does not block this plan**. rmscene's MIT-licensed samples cover v6 here, and the live test covers the rest. Ask the user to start making it anyway; plan 2 needs it.
- Commit after every task with the message given. End each message with the `Co-Authored-By` line from your session's instructions.

---

### Task 1: Scaffold the repo and the package

**Files:**
- Create: `RMKit/Package.swift`
- Create: `RMKit/Sources/RMKit/Parse/Codes.swift`
- Create: `RMKit/Sources/remora-cli/RemoraCLI.swift (stub)`
- Create: `RMKit/Tests/RMKitTests/TestSupport.swift`
- Create: `RMKit/Tests/RMKitTests/Fixtures/rmscene/*`
- Create: `scripts/rmscene-goldens.mjs`
- Create: `.gitignore`
- Create: `LICENSE`
- Create: `README.md`
- Test: `RMKit/Tests/RMKitTests/CodesTests.swift`

**Step 1: Create the repo files**

`.gitignore`:
```gitignore
.DS_Store
.build/
.swiftpm/
*.xcodeproj/
golden-out/
```

`LICENSE`: the standard MIT text, `Copyright (c) 2026 Gabor Veres`.

`README.md`:
```markdown
# Remora

A native macOS viewer for the reMarkable cloud. Work in progress; see `docs/plans/`.

`RMKit/` is the core: `swift test --package-path RMKit`.
```

`RMKit/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RMKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RMKit", targets: ["RMKit"]),
        .executable(name: "remora-cli", targets: ["remora-cli"]),
    ],
    targets: [
        .target(name: "RMKit"),
        .executableTarget(name: "remora-cli", dependencies: ["RMKit"]),
        .testTarget(name: "RMKitTests", dependencies: ["RMKit"], resources: [.copy("Fixtures")]),
    ]
)
```

**Step 2: Pen and colour codes, test first**

`RMKit/Tests/RMKitTests/CodesTests.swift`:

```swift
import Testing
@testable import RMKit

@Suite struct CodesTests {
    @Test func bothNumberingsNameTheSamePen() {
        #expect(Pen(code: 0) == .brush)
        #expect(Pen(code: 12) == .brush)
        #expect(Pen(code: 21) == .calligraphy)
        #expect(Pen(code: 9) == nil)
    }

    @Test func colourCodes() {
        #expect(InkColor(code: 9) == .highlight)
        #expect(InkColor(code: 13) == .yellow)
        #expect(InkColor(code: 14) == nil)
    }
}
```

`RMKit/Sources/RMKit/Parse/Codes.swift`:

```swift
/// A pen as `.rm` files store it. Firmware renumbered the pens once, so two
/// codes can name the same pen.
public enum Pen: String, Sendable, CaseIterable {
    case brush, pencil, ballpoint, marker, fineliner, highlighter, eraser
    case mechanicalPencil, eraseArea, calligraphy, shader

    public init?(code: Int) {
        switch code {
        case 0, 12: self = .brush
        case 1, 14: self = .pencil
        case 2, 15: self = .ballpoint
        case 3, 16: self = .marker
        case 4, 17: self = .fineliner
        case 5, 18: self = .highlighter
        case 6: self = .eraser
        case 7, 13: self = .mechanicalPencil
        case 8: self = .eraseArea
        case 21: self = .calligraphy
        case 23: self = .shader
        default: return nil
        }
    }
}

/// A colour code as `.rm` files store it. `highlight` means "use the stroke's
/// own `colorRgba`".
public enum InkColor: String, Sendable, CaseIterable {
    case black, gray, white, yellow, green, pink, blue, red, grayOverlap, highlight, cyan, magenta

    public init?(code: Int) {
        switch code {
        case 0: self = .black
        case 1: self = .gray
        case 2: self = .white
        case 3, 13: self = .yellow
        case 4, 10: self = .green
        case 5: self = .pink
        case 6: self = .blue
        case 7: self = .red
        case 8: self = .grayOverlap
        case 9: self = .highlight
        case 11: self = .cyan
        case 12: self = .magenta
        default: return nil
        }
    }
}
```

`RMKit/Sources/remora-cli/RemoraCLI.swift` (a stub; Task 20 replaces it):

```swift
import Foundation

@main
struct RemoraCLI {
    static func main() {
        print("remora-cli: nothing here yet")
    }
}
```

**Step 3: Test support**

`RMKit/Tests/RMKitTests/TestSupport.swift` holds the HTTP stub and the fixture helpers that later tests use. Each test gets its own fake host, so parallel tests never share handlers. `Locked` exists because `Mutex` is noncopyable and can't be captured by the `@Sendable` stub handlers:

```swift
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

    override class func canInit(with request: URLRequest) -> Bool { true }
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
```

**Step 4: rmscene fixtures and their rm2agent goldens**

`scripts/rmscene-goldens.mjs`:

```js
// Render .rm files with rm2agent and write <name>.svg beside each, as goldens
// for RMKit's port. usage: node scripts/rmscene-goldens.mjs <rm2agent checkout> <file.rm>...
// The rm2agent checkout must be built (npm run build).
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const [rm2agent, ...files] = process.argv.slice(2);
const { parseRm } = await import(join(rm2agent, "node_modules/rmapi-js/dist/raw.js"));
const { normalizePage } = await import(join(rm2agent, "dist/render/strokes.js"));
const { pageGeometry, portraitSize } = await import(join(rm2agent, "dist/render/geometry.js"));
const { renderSvg } = await import(join(rm2agent, "dist/render/svg.js"));

for (const file of files) {
  const page = parseRm(new Uint8Array(await readFile(file)));
  const size = portraitSize(page.version === 6 ? page.paperSize : undefined);
  const geometry = pageGeometry(size, "portrait");
  const { strokes } = normalizePage(page, geometry);
  await writeFile(file.replace(/\.rm$/, ".svg"), renderSvg(strokes, geometry));
  console.log(`${file}: ${strokes.length} strokes`);
}
```

Then:
```bash
git clone --depth 1 https://github.com/ricklupton/rmscene /tmp/rmscene
mkdir -p RMKit/Tests/RMKitTests/Fixtures/rmscene
cp /tmp/rmscene/tests/data/*.rm /tmp/rmscene/LICENSE RMKit/Tests/RMKitTests/Fixtures/rmscene/
node scripts/rmscene-goldens.mjs /Users/gve/workbee/codez/Projects/rm2agent RMKit/Tests/RMKitTests/Fixtures/rmscene/*.rm
ls RMKit/Tests/RMKitTests/Fixtures/rmscene | wc -l
```
Expected: 13 lines of `…: N strokes`, then `27` (13 `.rm` files, 13 `.svg` files, `LICENSE`). The text-only samples report 0 strokes, which is correct.

**Step 5: Run the tests**

Run: `swift test --package-path RMKit`
Expected: `Test run with 2 tests in 1 suite passed`.

**Step 6: Commit**
```bash
git add .gitignore LICENSE README.md RMKit scripts
git commit -m "feat(rmkit): scaffold the package, pen and colour codes, rmscene fixtures"
```

---

### Task 2: HTTP with transient retries

**Files:**
- Create: `RMKit/Sources/RMKit/Cloud/HTTP.swift`
- Test: `RMKit/Tests/RMKitTests/HTTPTests.swift`

`CloudError` and `CloudHosts` live here because everything after this task throws or builds URLs with them. The retry policy is rmapi-js's: network errors, 429 and 5xx are retried with exponential backoff. `baseDelay` is a parameter only so the test doesn't sleep. The sync region comes from the session token's `tectonic` claim (Task 3); anything that isn't a plain hostname label falls back to `eu`, because the value ends up in a URL.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/HTTPTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct HTTPTests {
    @Test func retriesTransientFailures() async throws {
        let calls = Locked(0)
        let (session, host) = StubProtocol.make { _ in
            let n = calls.update { $0 += 1; return $0 }
            return n < 3 ? (503, Data()) : (200, Data("ok".utf8))
        }
        let data = try await HTTP(session: session, baseDelay: .zero).data(URLRequest(url: host))
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(calls.value == 3)
    }

    @Test func mapsStatusesToErrors() async {
        let (session, host) = StubProtocol.make { _ in (402, Data()) }
        await #expect(throws: CloudError.noSubscription) {
            try await HTTP(session: session).data(URLRequest(url: host))
        }
    }

    @Test func regionHostComesFromTheClaim() {
        #expect(CloudHosts.sync(tectonic: "us").absoluteString == "https://us.tectonic.remarkable.com")
        #expect(CloudHosts.sync(tectonic: nil).absoluteString == "https://eu.tectonic.remarkable.com")
        #expect(CloudHosts.sync(tectonic: "evil.com/x").absoluteString == "https://eu.tectonic.remarkable.com")
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter HTTPTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `HTTP.swift`**

`RMKit/Sources/RMKit/Cloud/HTTP.swift`:

```swift
import Foundation

public enum CloudError: Error, Equatable {
    case unauthorized
    /// 402/403: the account has no Connect subscription.
    case noSubscription
    case http(status: Int, body: String)
    case malformed(String)

    init(status: Int, body: String) {
        switch status {
        case 401: self = .unauthorized
        case 402, 403: self = .noSubscription
        default: self = .http(status: status, body: body)
        }
    }
}

public enum CloudHosts {
    public static let auth = URL(string: "https://webapp-prod.cloud.remarkable.engineering")!

    /// The session token's `tectonic` claim names the region; rmapi-js hardcodes "eu".
    public static func sync(tectonic: String?) -> URL {
        let region = tectonic.flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } ? $0 : nil }
        return URL(string: "https://\(region ?? "eu").tectonic.remarkable.com")!
    }
}

/// URLSession with rmapi-js's transient-retry policy: network errors, 429 and
/// 5xx are retried with exponential backoff.
struct HTTP: Sendable {
    let session: URLSession
    var maxTransientRetries = 3
    var baseDelay: Duration = .milliseconds(200)

    func data(_ request: URLRequest, retryTransient: Bool = true) async throws -> Data {
        var attempt = 0
        while true {
            let retriesLeft = retryTransient && attempt < maxTransientRetries
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                guard retriesLeft, status == 429 || status >= 500 else {
                    throw CloudError(status: status, body: String(decoding: data, as: UTF8.self))
                }
            } catch let error as URLError {
                guard retriesLeft else { throw error }
            }
            attempt += 1
            try await Task.sleep(for: baseDelay * (1 << attempt))
        }
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter HTTPTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): http client with transient retries"
```

---

### Task 3: Token claims

**Files:**
- Create: `RMKit/Sources/RMKit/Cloud/Tokens.swift`
- Test: `RMKit/Tests/RMKitTests/TokensTests.swift`

reMarkable's tokens are JWTs. Remora never checks the signature: it reads claims from tokens it just received over TLS from reMarkable. The device token (from pairing) carries `auth0-userid`, which is the account key everywhere (Keychain, cache directory). The session token carries `tectonic` (the region), `exp` and `auth0-profile.Email`, which is the account label.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/TokensTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct TokensTests {
    @Test func readsTheClaimsRemoraUses() throws {
        let claims = try TokenClaims(jwt: jwt([
            "auth0-userid": "auth0|abc", "device-id": "dev-1", "tectonic": "us",
            "exp": 1_800_000_000, "auth0-profile": ["Email": "me@example.com"],
        ]))
        #expect(claims.userID == "auth0|abc")
        #expect(claims.deviceID == "dev-1")
        #expect(claims.tectonic == "us")
        #expect(claims.email == "me@example.com")
        #expect(claims.expiry == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func rejectsANonJWT() {
        #expect(throws: CloudError.malformed("not a JWT")) { try TokenClaims(jwt: "nope") }
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter TokensTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `Tokens.swift`**

`RMKit/Sources/RMKit/Cloud/Tokens.swift`:

```swift
import Foundation

/// The claims Remora reads out of reMarkable's JWTs. The device token carries
/// `auth0-userid` and `device-id`; the session token carries `tectonic` (the
/// sync region), `exp` and the account's email.
public struct TokenClaims: Sendable, Equatable {
    public var userID: String?
    public var deviceID: String?
    public var tectonic: String?
    public var email: String?
    public var expiry: Date?

    public init(jwt: String) throws {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw CloudError.malformed("not a JWT") }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CloudError.malformed("unreadable JWT payload") }
        userID = json["auth0-userid"] as? String
        deviceID = json["device-id"] as? String
        tectonic = json["tectonic"] as? String
        email = (json["auth0-profile"] as? [String: Any])?["Email"] as? String
        expiry = (json["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter TokensTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): read token claims"
```

---

### Task 4: Pairing and session tokens

**Files:**
- Create: `RMKit/Sources/RMKit/Cloud/AuthClient.swift`
- Test: `RMKit/Tests/RMKitTests/AuthClientTests.swift`

**Never retry the token exchange on 429.** It is rate-limited, and rm2agent hit the limit just by restarting a script repeatedly. Remora registers as `desktop-macos` (one of rmapi-js's fixed `deviceDesc` values). That's unverified against the real server; Task 20 checks it.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/AuthClientTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct AuthClientTests {
    @Test func registersAsAMacDesktopClient() async throws {
        let (session, host) = StubProtocol.make { request in
            #expect(request.url?.path() == "/token/json/2/device/new")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer")
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(request)) as? [String: String]
            #expect(body?["code"] == "abcdefgh")
            #expect(body?["deviceDesc"] == "desktop-macos")
            return (200, Data("device-token".utf8))
        }
        let token = try await AuthClient(session: session, host: host).register(code: "abcdefgh")
        #expect(token == "device-token")
    }

    @Test func refusesAShortCode() async {
        await #expect(throws: CloudError.self) { try await AuthClient().register(code: "abc") }
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter AuthClientTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `AuthClient.swift`**

`RMKit/Sources/RMKit/Cloud/AuthClient.swift`:

```swift
import Foundation

/// Pairing and session tokens. Never retried on 429: the token exchange is
/// rate-limited, and hammering it is what trips the limit.
public struct AuthClient: Sendable {
    let http: HTTP
    let host: URL

    public init(session: URLSession = .shared, host: URL = CloudHosts.auth) {
        http = HTTP(session: session)
        self.host = host
    }

    /// Exchange the 8-letter code from my.remarkable.com for a device token,
    /// which never expires.
    public func register(code: String, deviceID: UUID = UUID()) async throws -> String {
        guard code.count == 8 else { throw CloudError.malformed("the pairing code has 8 letters") }
        var request = URLRequest(url: host.appending(path: "token/json/2/device/new"))
        request.httpMethod = "POST"
        request.setValue("Bearer", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "deviceDesc": "desktop-macos",
            "deviceID": deviceID.uuidString.lowercased(),
        ])
        return String(decoding: try await http.data(request, retryTransient: false), as: UTF8.self)
    }

    /// Mint a session token (lasts about a day) from a device token.
    public func session(deviceToken: String) async throws -> String {
        var request = URLRequest(url: host.appending(path: "token/json/2/user/new"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        return String(decoding: try await http.data(request, retryTransient: false), as: UTF8.self)
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter AuthClientTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): pairing and session tokens"
```

---

### Task 5: Entry lists

**Files:**
- Create: `RMKit/Sources/RMKit/Model/Entries.swift`
- Test: `RMKit/Tests/RMKitTests/EntriesTests.swift`

An entry list (`.docSchema` file) lists either the documents of the root or the files of one document. Schema 3 is a version line, then `hash:type:id:subfiles:size` lines. Schema 4 adds an info line `0:<id>:<count>:<size>` after the version. The root uses schema 4 and documents use schema 3 (measured on the account). Hashes are validated because they go into URL paths.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/EntriesTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct EntriesTests {
    @Test func parsesSchema3() throws {
        let text = "3\n\(fakeHash(1)):0:doc.content:0:12\n\(fakeHash(2)):0:doc/p1.rm:0:400\n"
        let entries = try Entries.parse(Data(text.utf8))
        #expect(entries.map(\.id) == ["doc.content", "doc/p1.rm"])
        #expect(entries[1].size == 400)
    }

    @Test func parsesSchema4AndChecksTheCount() throws {
        let good = "4\n0:.:1:5\n\(fakeHash(3)):0:doc-id:4:5\n"
        #expect(try Entries.parse(Data(good.utf8)).map(\.id) == ["doc-id"])
        let bad = "4\n0:.:2:5\n\(fakeHash(3)):0:doc-id:4:5\n"
        #expect(throws: CloudError.self) { try Entries.parse(Data(bad.utf8)) }
    }

    @Test func rejectsABadHash() {
        #expect(throws: CloudError.self) { try Entries.parse(Data("3\nnothex:0:a:0:1\n".utf8)) }
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter EntriesTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `Entries.swift`**

`RMKit/Sources/RMKit/Model/Entries.swift`:

```swift
import Foundation

/// One line of an entry list: a file of a document, or a document of the root.
public struct Entry: Sendable, Hashable {
    public let hash: String
    public let id: String
    public let subfiles: Int
    public let size: Int
}

/// The `.docSchema` entry-list format. Schema 3 is a version line then
/// `hash:type:id:subfiles:size` lines; schema 4 adds a `0:<id>:<count>:<size>`
/// info line after the version.
public enum Entries {
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { throw CloudError.malformed("empty entry list") }
        let version = lines.removeFirst()
        var expected: Int?
        switch version {
        case "3":
            break
        case "4":
            guard !lines.isEmpty else { throw CloudError.malformed("schema 4 entry list has no info line") }
            let info = lines.removeFirst().split(separator: ":", omittingEmptySubsequences: false)
            guard info.count == 4, info[0] == "0", let count = Int(info[2]) else {
                throw CloudError.malformed("bad schema 4 info line")
            }
            expected = count
        default:
            throw CloudError.malformed("entry list schema \(version)")
        }
        let entries = try lines.map(parseLine)
        if let expected, expected != entries.count {
            throw CloudError.malformed("entry list declares \(expected) entries but has \(entries.count)")
        }
        return entries
    }

    private static func parseLine(_ line: String) throws -> Entry {
        let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, isHash(fields[0]), fields[1] == "0" || fields[1] == "80000000",
              !fields[2].isEmpty, let subfiles = Int(fields[3]), let size = Int(fields[4])
        else { throw CloudError.malformed("bad entry line: \(line)") }
        return Entry(hash: fields[0], id: fields[2], subfiles: subfiles, size: size)
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter EntriesTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): parse entry lists"
```

---

### Task 6: Cloud session

**Files:**
- Create: `RMKit/Sources/RMKit/Cloud/CloudSession.swift`
- Test: `RMKit/Tests/RMKitTests/CloudSessionTests.swift`

One actor per account. The session token is stored as a `Task` *before* anyone awaits it, so the five concurrent first requests in the test share one exchange. On 401 it refreshes once and retries. **`root()` always hits the network:** a client that caches the root sees a frozen account (rm2agent learned this the hard way). Every blob GET sends `rm-filename`, as the official clients do.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/CloudSessionTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct CloudSessionTests {
    /// A fake cloud on one host: the token exchange, the root and one file.
    static func fakeCloud(rootStatuses: [Int] = [200]) -> (CloudSession, Locked<Int>) {
        let tokens = Locked(0)
        let roots = Locked(rootStatuses)
        let (session, host) = StubProtocol.make { request in
            switch request.url?.path() {
            case "/token/json/2/user/new":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
                let n = tokens.update { $0 += 1; return $0 }
                return (200, Data(jwt(["n": n, "exp": Date().timeIntervalSince1970 + 3600]).utf8))
            case "/sync/v4/root":
                let status = roots.update { $0.count > 1 ? $0.removeFirst() : $0[0] }
                return (status, Data(#"{"hash":"\#(fakeHash(1))","generation":7,"schemaVersion":4}"#.utf8))
            case "/sync/v3/files/\(fakeHash(2))":
                #expect(request.value(forHTTPHeaderField: "rm-filename") == "doc.content")
                #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
                return (200, Data("{}".utf8))
            default:
                return (404, Data())
            }
        }
        let cloud = CloudSession(deviceToken: "device-token", session: session, authHost: host, syncHost: host)
        return (cloud, tokens)
    }

    @Test func readsTheRoot() async throws {
        let (cloud, _) = Self.fakeCloud()
        #expect(try await cloud.root() == RootHash(hash: fakeHash(1), generation: 7, schemaVersion: 4))
    }

    @Test func refreshesTheSessionOnceOn401() async throws {
        let (cloud, tokens) = Self.fakeCloud(rootStatuses: [401, 200])
        _ = try await cloud.root()
        #expect(tokens.value == 2)
    }

    @Test func concurrentFirstRequestsShareOneTokenExchange() async throws {
        let (cloud, tokens) = Self.fakeCloud()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await cloud.file(hash: fakeHash(2), name: "doc.content") } }
            try await group.waitForAll()
        }
        #expect(tokens.value == 1)
    }

    @Test func refusesAMalformedHash() async {
        let (cloud, _) = Self.fakeCloud()
        await #expect(throws: CloudError.self) { try await cloud.file(hash: "../etc", name: "x") }
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter CloudSessionTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `CloudSession.swift`**

`RMKit/Sources/RMKit/Cloud/CloudSession.swift`:

```swift
import Foundation

public struct RootHash: Sendable, Equatable, Codable {
    public let hash: String
    public let generation: Int
    public let schemaVersion: Int
}

/// One account's authorized access to the sync API. Holds one session token
/// at a time, shared by every request, refreshed when it nears expiry or the
/// server answers 401.
public actor CloudSession {
    struct Authorized: Sendable {
        let token: String
        let claims: TokenClaims

        var isExpiring: Bool {
            guard let expiry = claims.expiry else { return false }
            return expiry < Date().addingTimeInterval(300)
        }
    }

    private let deviceToken: String
    private let http: HTTP
    private let auth: AuthClient
    private let syncHostOverride: URL?
    private var current: Task<Authorized, Error>?

    public init(
        deviceToken: String,
        session: URLSession = .shared,
        authHost: URL = CloudHosts.auth,
        syncHost: URL? = nil
    ) {
        self.deviceToken = deviceToken
        http = HTTP(session: session)
        auth = AuthClient(session: session, host: authHost)
        syncHostOverride = syncHost
    }

    public func claims() async throws -> TokenClaims {
        try await authorized(refresh: false).claims
    }

    /// Concurrent first callers share one exchange: the task is stored before
    /// anyone awaits it.
    // ponytail: two callers that both see an expiring token can each refresh; it happens once a day
    private func authorized(refresh: Bool) async throws -> Authorized {
        if !refresh, let current, let value = try? await current.value, !value.isExpiring {
            return value
        }
        let fresh = Task { [auth, deviceToken] in
            let token = try await auth.session(deviceToken: deviceToken)
            return Authorized(token: token, claims: try TokenClaims(jwt: token))
        }
        current = fresh
        return try await fresh.value
    }

    private func send(_ build: (URL) -> URLRequest) async throws -> Data {
        var auth = try await authorized(refresh: false)
        for attempt in 0..<2 {
            var request = build(syncHostOverride ?? CloudHosts.sync(tectonic: auth.claims.tectonic))
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            do {
                return try await http.data(request)
            } catch CloudError.unauthorized where attempt == 0 {
                auth = try await authorized(refresh: true)
            }
        }
        throw CloudError.unauthorized
    }

    /// Always re-read: a client that keeps an old root sees a frozen account.
    public func root() async throws -> RootHash {
        let data = try await send { URLRequest(url: $0.appending(path: "sync/v4/root")) }
        let root = try JSONDecoder().decode(RootHash.self, from: data)
        guard root.schemaVersion == 3 || root.schemaVersion == 4 else {
            throw CloudError.malformed("root schema version \(root.schemaVersion)")
        }
        return root
    }

    /// One immutable blob. `name` is the file's id, e.g. `<doc>.content`.
    public func file(hash: String, name: String) async throws -> Data {
        guard Entries.isHash(hash) else { throw CloudError.malformed("not a hash: \(hash)") }
        return try await send { host in
            var request = URLRequest(url: host.appending(path: "sync/v3/files/\(hash)"))
            request.setValue(name, forHTTPHeaderField: "rm-filename")
            return request
        }
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter CloudSessionTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): cloud session with shared token refresh"
```

---

### Task 7: Keychain

**Files:**
- Create: `RMKit/Sources/RMKit/Cloud/Keychain.swift`
- Test: `RMKit/Tests/RMKitTests/KeychainTests.swift`

Generic passwords in the login keychain, service `io.github.gveres.remora`, account = `auth0-userid`. It doesn't use the data-protection keychain, because that needs entitlements that a plain `swift test` binary and the CLI don't have. Each binary that creates an item owns it, so the app (later plan) will show a one-time "allow" prompt for items the CLI made. The test is skipped when `CI` is set.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/KeychainTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
struct KeychainTests {
    @Test func storesListsAndDeletesTokens() throws {
        let keychain = Keychain(service: "io.github.gveres.remora.tests.\(UUID().uuidString)")
        defer { try? keychain.delete(account: "a") }
        #expect(try keychain.get(account: "a") == nil)
        try keychain.set("one", account: "a")
        try keychain.set("two", account: "a")
        #expect(try keychain.get(account: "a") == "two")
        #expect(try keychain.accounts() == ["a"])
        try keychain.delete(account: "a")
        #expect(try keychain.accounts() == [])
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter KeychainTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `Keychain.swift`**

`RMKit/Sources/RMKit/Cloud/Keychain.swift`:

```swift
import Foundation
import Security

/// Device tokens in the login keychain, one generic password per account.
/// The account key is the token's `auth0-userid`.
public struct Keychain: Sendable {
    public struct Failure: Error, Equatable { public let status: OSStatus }

    public let service: String

    public init(service: String = "io.github.gveres.remora") {
        self.service = service
    }

    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func set(_ secret: String, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var add = query(account)
        add[kSecValueData as String] = Data(secret.utf8)
        try check(SecItemAdd(add as CFDictionary, nil))
    }

    public func get(account: String) throws -> String? {
        var find = query(account)
        find[kSecReturnData as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (out as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    public func accounts() throws -> [String] {
        var find = query()
        find[kSecReturnAttributes as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        try check(status)
        let items = out as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter KeychainTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): keychain token store"
```

---

### Task 8: Blob cache

**Files:**
- Create: `RMKit/Sources/RMKit/Cache/BlobCache.swift`
- Test: `RMKit/Tests/RMKitTests/BlobCacheTests.swift`

Blobs are immutable and named by their hash, so the cache never invalidates anything. Two tiers: `keep/` (entry lists, `.metadata`, `.content`, `.pagedata`: small, needed to browse offline, never evicted) and `lru/` (`.rm`, `.pdf`, `.epub`). The file modification date is the LRU clock: reads touch it, `evict()` deletes the oldest until `lru/` is under the limit. `BlobStore` puts the cache in front of a fetch closure, so tests and offline mode can stand in for the cloud.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/BlobCacheTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct BlobCacheTests {
    @Test func roundTripsAndEvictsOldestInkFirst() throws {
        let cache = BlobCache(directory: temporaryDirectory(), limit: 10)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        try cache.store(Data("keep-me-forever".utf8), hash: fakeHash(1), name: "doc.content")
        for n in 2...4 { try cache.store(Data("123456".utf8), hash: fakeHash(n), name: "doc/p\(n).rm") }
        // make p2 the oldest and p4 the newest
        for n in 2...4 {
            let url = cache.directory.appending(path: "lru/00/\(fakeHash(n))")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(n))], ofItemAtPath: url.path())
        }
        try cache.evict()
        #expect(cache.data(hash: fakeHash(1), name: "doc.content") != nil)
        #expect(cache.data(hash: fakeHash(2), name: "doc/p2.rm") == nil)
        #expect(cache.data(hash: fakeHash(3), name: "doc/p3.rm") == nil)
        #expect(cache.data(hash: fakeHash(4), name: "doc/p4.rm") != nil)
    }

    @Test func storeFetchesOnceThenServesFromDisk() async throws {
        let fetches = Locked(0)
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory())) { _, _ in
            fetches.update { $0 += 1 }
            return Data("x".utf8)
        }
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        _ = try await store.data(hash: fakeHash(1), name: "a.content")
        _ = try await store.data(hash: fakeHash(1), name: "a.content")
        #expect(fetches.value == 1)
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter BlobCacheTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `BlobCache.swift`**

`RMKit/Sources/RMKit/Cache/BlobCache.swift`:

```swift
import Foundation

/// Content-addressed blobs on disk. A hash names its bytes forever, so nothing
/// is ever invalidated. Entry lists, metadata and content live in `keep/` and
/// are never evicted; page ink and documents live in `lru/` and are trimmed,
/// least recently read first, once they pass the limit.
public struct BlobCache: Sendable {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 2 << 30) {
        self.directory = directory
        self.limit = limit
    }

    /// `~/Library/Caches/Remora/<account>/blobs`
    public static func directory(account: String) -> URL {
        let safe = String(account.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return URL.cachesDirectory.appending(path: "Remora/\(safe)/blobs")
    }

    static func isEvictable(name: String) -> Bool {
        name.hasSuffix(".rm") || name.hasSuffix(".pdf") || name.hasSuffix(".epub")
    }

    private func url(hash: String, name: String) -> URL {
        directory
            .appending(path: Self.isEvictable(name: name) ? "lru" : "keep")
            .appending(path: String(hash.prefix(2)))
            .appending(path: hash)
    }

    public func data(hash: String, name: String) -> Data? {
        let url = url(hash: hash, name: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if Self.isEvictable(name: name) {
            // the modification date is the LRU clock
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path())
        }
        return data
    }

    public func store(_ data: Data, hash: String, name: String) throws {
        let url = url(hash: hash, name: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Trim `lru/` to the limit, oldest first.
    public func evict() throws {
        let root = directory.appending(path: "lru")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, date: Date, size: Int)] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            try FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}

/// Cache in front of a fetch. The fetch is a closure so tests and offline mode
/// can stand in for the cloud.
public struct BlobStore: Sendable {
    public typealias Fetch = @Sendable (_ hash: String, _ name: String) async throws -> Data

    public let cache: BlobCache
    let fetch: Fetch

    public init(cache: BlobCache, fetch: @escaping Fetch) {
        self.cache = cache
        self.fetch = fetch
    }

    public func data(hash: String, name: String) async throws -> Data {
        if let data = cache.data(hash: hash, name: name) { return data }
        let data = try await fetch(hash, name)
        try cache.store(data, hash: hash, name: name)
        return data
    }

    public func entries(hash: String, id: String) async throws -> [Entry] {
        try Entries.parse(try await data(hash: hash, name: "\(id).docSchema"))
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter BlobCacheTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): content-addressed blob cache"
```

---

### Task 9: Metadata and content

**Files:**
- Create: `RMKit/Sources/RMKit/Model/ItemFiles.swift`
- Test: `RMKit/Tests/RMKitTests/ContentTests.swift`

Read `.content` leniently: every field is `try?`, so one odd field costs that field, not the document. Tags are plain strings in legacy content and `{name, timestamp}` objects in newer content. `cPages` fields are `{timestamp, value}` wrappers, and `deleted` can be a number or a bool. `Orientation` lives here: it's a document-level fact, and no page carries it.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/ContentTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct ContentTests {
    @Test func decodesBothSchemasAndBothTagShapes() throws {
        let json = """
            {"fileType":"pdf","orientation":"landscape","pageCount":2,"pages":null,
             "cPages":{"pages":[{"id":"p1","idx":{"timestamp":"1:1","value":"ba"},"redir":{"timestamp":"1:1","value":0},
                                 "template":{"timestamp":"1:1","value":"P Grid medium"}},
                                {"id":"p2","idx":{"timestamp":"1:1","value":"bb"},"deleted":{"timestamp":"1:1","value":1}}]},
             "tags":[{"name":"work","timestamp":1},"legacy"]}
            """
        let content = try JSONDecoder().decode(DocumentContent.self, from: Data(json.utf8))
        #expect(content.fileType == "pdf")
        #expect(content.orientation == .landscape)
        #expect(content.pages == nil)
        #expect(content.cPages.map(\.id) == ["p1", "p2"])
        #expect(content.cPages[0].template == "P Grid medium")
        #expect(content.cPages[0].redir == 0)
        #expect(content.cPages[1].deleted)
        #expect(content.tags == ["work", "legacy"])
    }

    @Test func aBadFieldCostsOnlyThatField() throws {
        let content = try JSONDecoder().decode(DocumentContent.self, from: Data(#"{"pageCount":"many","orientation":"portrait"}"#.utf8))
        #expect(content.pageCount == nil)
        #expect(content.orientation == .portrait)
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter ContentTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `ItemFiles.swift`**

`RMKit/Sources/RMKit/Model/ItemFiles.swift`:

```swift
import Foundation

/// From `.content`: orientation is per document, never per page.
public enum Orientation: String, Sendable {
    case portrait, landscape
}

/// `<id>.metadata`
public struct ItemMetadata: Decodable, Sendable {
    public var visibleName: String
    public var parent: String
    /// DocumentType, CollectionType or TemplateType
    public var type: String
    public var pinned: Bool
    /// Milliseconds since 1970, as a string.
    public var lastModified: String?
}

/// `<id>.content`, read leniently: a field of an unexpected shape is dropped,
/// not allowed to cost the whole document.
public struct DocumentContent: Decodable, Sendable {
    public var fileType: String?
    public var orientation: Orientation
    public var pageCount: Int?
    /// The legacy page list: page ids in order. `null` on a never-opened document.
    public var pages: [String]?
    /// Legacy: the zero-based source PDF page of each page, -1 for an inserted page.
    public var redirectionPageMap: [Int]?
    /// The newer page list, ordered by `idx`.
    public var cPages: [CPage]
    public var tags: [String]

    private enum Keys: String, CodingKey {
        case fileType, orientation, pageCount, pages, redirectionPageMap, cPages, tags
    }

    private struct CPagesBox: Decodable { var pages: [CPage] }

    /// A tag is a string in legacy content and `{name, timestamp}` in newer content.
    private struct Tag: Decodable {
        var name: String
        private enum Keys: String, CodingKey { case name }
        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
            } else {
                name = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .name)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        fileType = try? c.decodeIfPresent(String.self, forKey: .fileType)
        orientation = (try? c.decodeIfPresent(String.self, forKey: .orientation)) == "landscape" ? .landscape : .portrait
        pageCount = try? c.decodeIfPresent(Int.self, forKey: .pageCount)
        pages = try? c.decodeIfPresent([String].self, forKey: .pages)
        redirectionPageMap = try? c.decodeIfPresent([Int].self, forKey: .redirectionPageMap)
        cPages = (try? c.decodeIfPresent(CPagesBox.self, forKey: .cPages))?.pages ?? []
        tags = ((try? c.decodeIfPresent([Tag].self, forKey: .tags)) ?? []).map(\.name)
    }

    public init(orientation: Orientation = .portrait, pages: [String]? = nil, redirectionPageMap: [Int]? = nil, cPages: [CPage] = []) {
        self.orientation = orientation
        self.pages = pages
        self.redirectionPageMap = redirectionPageMap
        self.cPages = cPages
        tags = []
    }
}

/// One entry of `cPages.pages`. Each field is `{timestamp, value}` on disk.
public struct CPage: Decodable, Sendable {
    public var id: String?
    public var idx: String?
    public var template: String?
    /// The zero-based source PDF page.
    public var redir: Int?
    public var deleted: Bool

    private enum Keys: String, CodingKey { case id, idx, template, redir, deleted }
    private struct Wrapped<T: Decodable>: Decodable { var value: T }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try? c.decode(String.self, forKey: .id)
        idx = (try? c.decode(Wrapped<String>.self, forKey: .idx))?.value
        template = (try? c.decode(Wrapped<String>.self, forKey: .template))?.value
        redir = (try? c.decode(Wrapped<Int>.self, forKey: .redir))?.value
        let deletedNumber = (try? c.decode(Wrapped<Int>.self, forKey: .deleted))?.value
        let deletedFlag = (try? c.decode(Wrapped<Bool>.self, forKey: .deleted))?.value
        deleted = (deletedNumber ?? 0) != 0 || deletedFlag == true
    }

    public init(id: String?, idx: String?, template: String? = nil, redir: Int? = nil, deleted: Bool = false) {
        self.id = id
        self.idx = idx
        self.template = template
        self.redir = redir
        self.deleted = deleted
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter ContentTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): lenient metadata and content decoding"
```

---

### Task 10: Page map

**Files:**
- Create: `RMKit/Sources/RMKit/Model/PageMap.swift`
- Test: `RMKit/Tests/RMKitTests/PageMapTests.swift`

Port of rm2agent `src/model/page-map.ts`. Choose by shape: `cPages.pages` if non-empty, else the legacy `pages` list, else the order of the `.rm` files.
- **Filter `deleted` pages before numbering**, or every later page number shifts.
- **Compare `idx` byte-wise** (`Array(utf8).lexicographicallyPrecedes`), never with Swift's Unicode-aware `<`.
- `redir` and `redirectionPageMap` are zero-based; `-1` marks an inserted page with no source.
- With no redirection map, page *n* sits on source page *n*.
- The template name comes from `cPages[].template.value`, else from line *n* of `.pagedata`.

Deliberate difference: rm2agent refuses to number a document with a missing `idx`; we fall back to array order (`ponytail:` comment).

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/PageMapTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct PageMapTests {
    @Test func cPagesSortByIdxBytewiseAndSkipDeleted() {
        let content = DocumentContent(cPages: [
            CPage(id: "c", idx: "bc", redir: 4),
            CPage(id: "gone", idx: "ba", deleted: true),
            CPage(id: "a", idx: "Ba"), // uppercase sorts before lowercase, byte-wise
            CPage(id: "b", idx: "bb", template: "P Lines small"),
        ])
        let pages = PageMap.pages(content: content, rmPageIDs: [])
        #expect(pages.map(\.id) == ["a", "b", "c"])
        #expect(pages.map(\.number) == [1, 2, 3])
        #expect(pages[2].sourcePage == 5)
        #expect(pages[0].sourcePage == nil)
        #expect(pages[1].template == "P Lines small")
    }

    @Test func legacyPagesUseTheRedirectionMap() {
        let mapped = PageMap.pages(content: DocumentContent(pages: ["x", "y", "z"], redirectionPageMap: [0, -1, 1]), rmPageIDs: [])
        #expect(mapped.map(\.sourcePage) == [1, nil, 2])
        let identity = PageMap.pages(content: DocumentContent(pages: ["x", "y"]), rmPageIDs: [])
        #expect(identity.map(\.sourcePage) == [1, 2])
    }

    @Test func noPageListFallsBackToTheInkFilesAndPagedata() {
        let pages = PageMap.pages(content: DocumentContent(pages: []), rmPageIDs: ["p1", "p2"], pagedata: ["Blank", "P Dots large"])
        #expect(pages.map(\.id) == ["p1", "p2"])
        #expect(pages.map(\.template) == ["Blank", "P Dots large"])
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter PageMapTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `PageMap.swift`**

`RMKit/Sources/RMKit/Model/PageMap.swift`:

```swift
import Foundation

/// A page of a document: its stable id, the number the tablet shows it at,
/// and the source PDF page under it, if any.
public struct PageRef: Sendable, Equatable {
    public let id: String
    /// One-based, derived from the order. Links key on `id`, never on this.
    public let number: Int
    /// One-based source PDF page; nil for notebook pages and pages inserted into a PDF.
    public let sourcePage: Int?
    public let template: String?
}

/// Page order from `.content`, ported from rm2agent `page-map.ts`. The schema
/// is chosen by shape, not `formatVersion`: `cPages` if it has pages, else the
/// legacy `pages` list, else the order of the `.rm` files.
public enum PageMap {
    public static func pages(content: DocumentContent, rmPageIDs: [String], pagedata: [String] = []) -> [PageRef] {
        func template(_ declared: String?, _ number: Int) -> String? {
            if let declared, !declared.isEmpty { return declared }
            let line = pagedata.indices.contains(number - 1) ? pagedata[number - 1] : ""
            return line.isEmpty ? nil : line
        }

        if !content.cPages.isEmpty {
            // deleted pages stay in the list; numbering them would shift every later page
            let live = content.cPages.filter { !$0.deleted }.enumerated()
            // idx is compared byte-wise, as the device does; missing idx sorts first
            // ponytail: rm2agent refuses to number a document with a missing idx; we fall back to array order
            let ordered = live.sorted { a, b in
                let ai = Array((a.element.idx ?? "").utf8), bi = Array((b.element.idx ?? "").utf8)
                return ai == bi ? a.offset < b.offset : ai.lexicographicallyPrecedes(bi)
            }
            return ordered.enumerated().compactMap { offset, page in
                guard let id = page.element.id else { return nil } // keeps its number, has no entry
                let number = offset + 1
                let source = page.element.redir.flatMap { $0 >= 0 ? $0 + 1 : nil }
                return PageRef(id: id, number: number, sourcePage: source, template: template(page.element.template, number))
            }
        }

        if let pages = content.pages, !pages.isEmpty {
            let map = content.redirectionPageMap ?? []
            return pages.enumerated().map { offset, id in
                let number = offset + 1
                // no map means each page sits on the source page of the same number
                let source: Int? = map.isEmpty ? number : map.indices.contains(offset) && map[offset] >= 0 ? map[offset] + 1 : nil
                return PageRef(id: id, number: number, sourcePage: source, template: template(nil, number))
            }
        }

        return rmPageIDs.enumerated().map { offset, id in
            PageRef(id: id, number: offset + 1, sourcePage: nil, template: template(nil, offset + 1))
        }
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter PageMapTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): page map ported from rm2agent"
```

---

### Task 11: Library index

**Files:**
- Create: `RMKit/Sources/RMKit/Model/Library.swift`
- Test: `RMKit/Tests/RMKitTests/LibraryTests.swift`

`build` reads the root entry list, reuses every item whose hash is unchanged, and reads the rest with at most `concurrency` requests in flight. An item that can't be read goes into `failures`; it's never silently dropped. On the user's account (545 items), a cold build took 37 s at concurrency 8, and warm it's local-only. `concurrency` is the knob if that needs to come down.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/LibraryTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct LibraryTests {
    /// An in-memory account: a root with one folder and one notebook inside it.
    static func account() -> [String: Data] {
        func json(_ s: String) -> Data { Data(s.utf8) }
        return [
            fakeHash(1): json("4\n0:.:2:0\n\(fakeHash(10)):0:folder:2:0\n\(fakeHash(20)):0:note:2:0\n"),
            fakeHash(10): json("3\n\(fakeHash(11)):0:folder.metadata:0:0\n\(fakeHash(12)):0:folder.content:0:0\n"),
            fakeHash(11): json(#"{"visibleName":"Work","parent":"","type":"CollectionType","pinned":false}"#),
            fakeHash(12): json(#"{"tags":[]}"#),
            fakeHash(20): json("3\n\(fakeHash(21)):0:note.metadata:0:0\n\(fakeHash(22)):0:note.content:0:0\n"),
            fakeHash(21): json(#"{"visibleName":"Ideas","parent":"folder","type":"DocumentType","pinned":true,"lastModified":"1700000000000"}"#),
            fakeHash(22): json(#"{"fileType":"notebook","pageCount":3,"tags":["t"]}"#),
        ]
    }

    static func store(_ blobs: [String: Data], fetched: Locked<[String]> = Locked([])) -> BlobStore {
        BlobStore(cache: BlobCache(directory: temporaryDirectory())) { hash, name in
            fetched.update { $0.append(name) }
            guard let data = blobs[hash] else { throw CloudError.http(status: 404, body: name) }
            return data
        }
    }

    @Test func buildsTheTree() async throws {
        let root = RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4)
        let library = try await Library.build(root: root, blobs: Self.store(Self.account()))
        #expect(library.failures.isEmpty)
        #expect(library.items["folder"]?.kind == .folder)
        let note = try #require(library.items["note"])
        #expect(note.kind == .notebook)
        #expect(note.pinned)
        #expect(note.pageCount == 3)
        #expect(note.tags == ["t"])
        #expect(note.lastModified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(library.path(of: "note") == "Work/Ideas")
        #expect(library.children(of: "").map(\.id) == ["folder"])
    }

    @Test func reusesUnchangedItemsAndRecordsFailures() async throws {
        var blobs = Self.account()
        let first = try await Library.build(
            root: RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4), blobs: Self.store(blobs))
        // a new root where "note" is unchanged and a third item is unreadable
        blobs[fakeHash(2)] = Data("4\n0:.:3:0\n\(fakeHash(10)):0:folder:2:0\n\(fakeHash(20)):0:note:2:0\n\(fakeHash(30)):0:broken:2:0\n".utf8)
        let fetched = Locked<[String]>([])
        let second = try await Library.build(
            root: RootHash(hash: fakeHash(2), generation: 2, schemaVersion: 4),
            previous: first, blobs: Self.store(blobs, fetched: fetched))
        #expect(fetched.value == ["root.docSchema", "broken.docSchema"])
        #expect(second.items["note"] == first.items["note"])
        #expect(second.failures.keys.sorted() == ["broken"])
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter LibraryTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `Library.swift`**

`RMKit/Sources/RMKit/Model/Library.swift`:

```swift
import Foundation

public struct LibraryItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case folder, notebook, pdf, epub, template }

    public let id: String
    /// The hash of the item's entry list; it changes whenever any file of the item does.
    public let hash: String
    public let name: String
    /// "" is the root, "trash" the trash.
    public let parent: String
    public let kind: Kind
    public let pinned: Bool
    public let tags: [String]
    public let lastModified: Date?
    public let pageCount: Int?
}

/// The account's whole tree at one root hash.
public struct Library: Sendable {
    public let root: RootHash
    public let items: [String: LibraryItem]
    /// Items that could not be read, with why. Never silently dropped.
    public let failures: [String: String]

    public func children(of parent: String) -> [LibraryItem] {
        items.values.filter { $0.parent == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Folder/Sub/Name"
    public func path(of id: String) -> String {
        var names: [String] = []
        var seen: Set<String> = []
        var current = items[id]
        while let item = current, seen.insert(item.id).inserted {
            names.append(item.name)
            current = items[item.parent]
        }
        return names.reversed().joined(separator: "/")
    }

    /// Read every item of `root`, reusing `previous` for items whose hash is unchanged.
    public static func build(
        root: RootHash,
        previous: Library? = nil,
        blobs: BlobStore,
        concurrency: Int = 8
    ) async throws -> Library {
        let entries = try await blobs.entries(hash: root.hash, id: "root")
        var items: [String: LibraryItem] = [:]
        var failures: [String: String] = [:]
        var pending: [Entry] = []
        for entry in entries {
            if let old = previous?.items[entry.id], old.hash == entry.hash {
                items[entry.id] = old
            } else {
                pending.append(entry)
            }
        }

        try await withThrowingTaskGroup(of: (String, Result<LibraryItem, Error>).self) { group in
            var queue = pending.makeIterator()
            func next() {
                guard let entry = queue.next() else { return }
                group.addTask {
                    do { return (entry.id, .success(try await item(entry, blobs: blobs))) }
                    catch { return (entry.id, .failure(error)) }
                }
            }
            for _ in 0..<concurrency { next() }
            while let (id, result) = try await group.next() {
                switch result {
                case .success(let item): items[id] = item
                case .failure(let error): failures[id] = "\(error)"
                }
                next()
            }
        }
        return Library(root: root, items: items, failures: failures)
    }

    private static func item(_ entry: Entry, blobs: BlobStore) async throws -> LibraryItem {
        let files = try await blobs.entries(hash: entry.hash, id: entry.id)
        guard let metaFile = files.first(where: { $0.id.hasSuffix(".metadata") }) else {
            throw CloudError.malformed("no .metadata")
        }
        let meta = try JSONDecoder().decode(ItemMetadata.self, from: try await blobs.data(hash: metaFile.hash, name: metaFile.id))
        var content: DocumentContent?
        if let contentFile = files.first(where: { $0.id.hasSuffix(".content") }) {
            content = try? JSONDecoder().decode(DocumentContent.self, from: try await blobs.data(hash: contentFile.hash, name: contentFile.id))
        }
        let kind: LibraryItem.Kind = switch meta.type {
        case "CollectionType": .folder
        case "TemplateType": .template
        default: LibraryItem.Kind(rawValue: content?.fileType ?? "") ?? .notebook
        }
        return LibraryItem(
            id: entry.id,
            hash: entry.hash,
            name: meta.visibleName,
            parent: meta.parent,
            kind: kind,
            pinned: meta.pinned,
            tags: content?.tags ?? [],
            lastModified: meta.lastModified.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) },
            pageCount: content?.pageCount)
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter LibraryTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): library index with hash reuse"
```

---

### Task 12: Parsed page model and the byte reader

**Files:**
- Create: `RMKit/Sources/RMKit/Parse/RMPage.swift`
- Create: `RMKit/Sources/RMKit/Parse/ByteReader.swift`
- Test: `RMKit/Tests/RMKitTests/ByteReaderTests.swift`

`RMPage` is what every parser produces: strokes back to front, with v6 values left on v6's integer scales (normalization in Task 17 converts them).

`ByteReader` ports rmapi-js's `Reader`: little-endian reads, varuints, and v6's tagged fields. A tag is a varuint `index << 4 | type`, with types byte1 `0x1`, byte4 `0x4`, byte8 `0x8`, length4 `0xc` and id `0xf`. It also handles length-prefixed subblocks that must be consumed exactly.

**Gotcha found while proving this plan:** write `let length = Int(try u32()); let end = offset + length`. The one-liner `offset + Int(try u32())` reads `offset` *before* `u32()` advances it, so every subblock ends 4 bytes early and every block fails to parse. The third test catches it.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/ByteReaderTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct ByteReaderTests {
    @Test func readsVaruintsAndTags() throws {
        // 150 as a varuint, then tag 2/byte4 (0x24) holding 7
        let r = ByteReader(Data([0x96, 0x01, 0x24, 7, 0, 0, 0]))
        #expect(try r.varuint() == 150)
        #expect(r.hasTag(2, .byte4))
        #expect(!r.hasTag(3, .byte4))
        #expect(try r.int(2) == 7)
        #expect(r.atEnd)
    }

    @Test func subblockMustBeConsumed() {
        // tag 1/length4 (0x1c), length 2, then two bytes
        let r = ByteReader(Data([0x1c, 2, 0, 0, 0, 0xaa, 0xbb]))
        #expect(throws: RMParseError.subblockNotConsumed(index: 1)) { try r.subblock(1) { try r.u8() } }
    }

    @Test func subblockEndsWhereItsLengthSays() throws {
        let r = ByteReader(Data([0x1c, 2, 0, 0, 0, 0xaa, 0xbb, 0xcc]))
        #expect(try r.subblock(1) { [try r.u8(), try r.u8()] } == [0xaa, 0xbb])
        #expect(try r.u8() == 0xcc)
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter ByteReaderTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `RMPage.swift`**

`RMKit/Sources/RMKit/Parse/RMPage.swift`:

```swift
import Foundation

/// A CRDT identifier: the author's slot and that author's running counter.
public struct CrdtID: Hashable, Sendable {
    public let author: UInt8
    public let counter: UInt64

    public init(author: UInt8, counter: UInt64) {
        self.author = author
        self.counter = counter
    }

    static let root = CrdtID(author: 0, counter: 1)
    static let end = CrdtID(author: 0, counter: 0)
}

/// One sample as the file stores it. v6 values are on v6's integer scales
/// (width in quarter pixels, pressure 0...255); v3/v5 values are as stored.
public struct RawPoint: Sendable, Equatable {
    public var x, y, speed, direction, width, pressure: Double
}

public struct RawStroke: Sendable {
    public var pen: Pen
    public var color: InkColor
    public var colorRgba: UInt32?
    public var thicknessScale: Double
    public var points: [RawPoint]
    /// The scene item's id; v3/v5 strokes have none.
    public var id: CrdtID?
    /// On a layer the user hid.
    public var hidden: Bool
}

public struct PaperSize: Sendable, Equatable {
    public var width: Int
    public var height: Int
}

/// A parsed `.rm` page, every version flattened to strokes back to front.
public struct RMPage: Sendable {
    public var version: Int
    public var strokes: [RawStroke]
    /// Only v6 pages made on a device that knew its screen carry one.
    public var paperSize: PaperSize?
    /// Blocks of a kind we read that failed to parse. Non-zero means ink may be missing.
    public var unreadableBlocks: Int
}

public enum RMParseError: Error, Equatable {
    case notAnRMFile
    case unsupportedVersion(String)
    case truncated
    case unexpectedTag(raw: UInt64, wanted: UInt64)
    case subblockNotConsumed(index: UInt64)
    case unknownPen(Int)
    case unknownColor(Int)
}

let rmHeaderLength = 43
```

**Step 4: Implement `ByteReader.swift`**

`RMKit/Sources/RMKit/Parse/ByteReader.swift`:

```swift
import Foundation

/// Little-endian reader for `.rm` files, with v6's tagged fields and nested
/// length-prefixed subblocks. Ported from rmapi-js's `Reader` (MIT).
final class ByteReader {
    enum TagType: UInt64 {
        case byte1 = 0x1, byte4 = 0x4, byte8 = 0x8, length4 = 0xc, id = 0xf
    }

    private let bytes: [UInt8]
    private(set) var offset: Int
    private var bounds: [Int] = []

    init(_ data: Data, offset: Int = 0) {
        bytes = [UInt8](data)
        self.offset = offset
    }

    var boundary: Int { bounds.last ?? bytes.count }
    var remaining: Int { boundary - offset }
    var atEnd: Bool { offset >= bytes.count }

    func seek(_ to: Int) { offset = to }

    private func take(_ count: Int) throws -> Int {
        guard count >= 0, offset + count <= boundary else { throw RMParseError.truncated }
        defer { offset += count }
        return offset
    }

    func u8() throws -> UInt8 { bytes[try take(1)] }

    func u16() throws -> UInt16 {
        let o = try take(2)
        return UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
    }

    func u32() throws -> UInt32 {
        let o = try take(4)
        let b0 = UInt32(bytes[o]), b1 = UInt32(bytes[o + 1])
        let b2 = UInt32(bytes[o + 2]), b3 = UInt32(bytes[o + 3])
        return b0 | b1 << 8 | b2 << 16 | b3 << 24
    }

    func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    func f32() throws -> Float { Float(bitPattern: try u32()) }

    func f64() throws -> Double {
        let low = UInt64(try u32())
        let high = UInt64(try u32())
        return Double(bitPattern: low | high << 32)
    }

    func varuint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            guard shift < 64 else { throw RMParseError.truncated }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    func crdtID() throws -> CrdtID {
        let author = try u8()
        return CrdtID(author: author, counter: try varuint())
    }

    func raw(_ count: Int) throws -> ArraySlice<UInt8> {
        let o = try take(count)
        return bytes[o..<o + count]
    }

    // MARK: tagged fields

    func hasTag(_ index: UInt64, _ type: TagType) -> Bool {
        guard offset < boundary else { return false }
        let save = offset
        defer { offset = save }
        guard let raw = try? varuint() else { return false }
        return raw >> 4 == index && raw & 0xf == type.rawValue
    }

    private func expect(_ index: UInt64, _ type: TagType) throws {
        let raw = try varuint()
        guard raw >> 4 == index, raw & 0xf == type.rawValue else {
            throw RMParseError.unexpectedTag(raw: raw, wanted: index << 4 | type.rawValue)
        }
    }

    func int(_ index: UInt64) throws -> UInt32 { try expect(index, .byte4); return try u32() }
    func float(_ index: UInt64) throws -> Float { try expect(index, .byte4); return try f32() }
    func double(_ index: UInt64) throws -> Double { try expect(index, .byte8); return try f64() }
    func id(_ index: UInt64) throws -> CrdtID { try expect(index, .id); return try crdtID() }
    func bool(_ index: UInt64) throws -> Bool { try expect(index, .byte1); return try u8() != 0 }

    /// Read a length-prefixed subblock. The body must consume it exactly,
    /// unless `allowTrailing` lets newer firmware's extra fields be skipped.
    func subblock<T>(_ index: UInt64, allowTrailing: Bool = false, _ body: () throws -> T) throws -> T {
        try expect(index, .length4)
        let length = Int(try u32())
        let end = offset + length
        guard end <= boundary else { throw RMParseError.truncated }
        bounds.append(end)
        defer {
            bounds.removeLast()
            offset = end
        }
        let value = try body()
        if !allowTrailing, offset != end { throw RMParseError.subblockNotConsumed(index: index) }
        return value
    }

    /// Run `body` with reads limited to `end`, then continue from `end`.
    func bounded<T>(to end: Int, _ body: () throws -> T) rethrows -> T {
        bounds.append(end)
        defer {
            bounds.removeLast()
            offset = end
        }
        return try body()
    }

    /// A last-writer-wins value: a timestamp id, then the value.
    func lww<T>(_ index: UInt64, _ value: () throws -> T) throws -> T {
        try subblock(index) {
            _ = try id(1)
            return try value()
        }
    }

    func string(_ index: UInt64) throws -> String {
        try subblock(index) {
            let length = Int(try varuint())
            _ = try u8() // is-ascii flag
            return String(decoding: try raw(length), as: UTF8.self)
        }
    }
}
```

**Step 5: Run the tests**

Run: `swift test --package-path RMKit --filter ByteReaderTests`
Expected: PASS.

**Step 6: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): parsed page model and byte reader"
```

---

### Task 13: CRDT ordering

**Files:**
- Create: `RMKit/Sources/RMKit/Parse/Toposort.swift`
- Test: `RMKit/Tests/RMKitTests/ToposortTests.swift`

v6 scene children form a CRDT sequence: each item names its left and right neighbours. This is rmapi-js's topological sort: ties go to the higher author, then the lower counter, and anything a cycle strands is appended in input order. It's generic over the item type, so typed text (a later plan) can reuse it.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/ToposortTests.swift`:

```swift
import Testing
@testable import RMKit

@Suite struct ToposortTests {
    struct Item { let id, left, right: CrdtID }
    func c(_ n: UInt64, author: UInt8 = 1) -> CrdtID { CrdtID(author: author, counter: n) }

    @Test func followsNeighbourLinks() {
        let items = [
            Item(id: c(3), left: c(2), right: .end),
            Item(id: c(1), left: .end, right: c(2)),
            Item(id: c(2), left: c(1), right: c(3)),
        ]
        let order = Toposort.order(items, id: \.id, left: \.left, right: \.right)
        #expect(order.map(\.id.counter) == [1, 2, 3])
    }

    @Test func concurrentInsertsPutTheHigherAuthorFirst() {
        let items = [
            Item(id: c(5, author: 1), left: .end, right: .end),
            Item(id: c(5, author: 2), left: .end, right: .end),
        ]
        let order = Toposort.order(items, id: \.id, left: \.left, right: \.right)
        #expect(order.map(\.id.author) == [2, 1])
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter ToposortTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `Toposort.swift`**

`RMKit/Sources/RMKit/Parse/Toposort.swift`:

```swift
/// Order CRDT sequence items by their left/right neighbour links, breaking
/// ties the way rmapi-js does: higher author first, then lower counter.
/// Items a cycle keeps from being placed are appended in input order.
enum Toposort {
    static func order<T>(
        _ items: [T],
        id: (T) -> CrdtID,
        left: (T) -> CrdtID,
        right: (T) -> CrdtID
    ) -> [T] {
        guard items.count > 1 else { return items }
        let count = items.count
        let start = count
        let end = count + 1

        var index: [CrdtID: Int] = [:]
        for (i, item) in items.enumerated() { index[id(item)] = i }
        func resolve(_ ref: CrdtID, _ fallback: Int) -> Int {
            ref == .end ? fallback : index[ref] ?? fallback
        }

        var successors = Array(repeating: [Int](), count: count + 2)
        var inDegree = Array(repeating: 0, count: count + 2)
        for (i, item) in items.enumerated() {
            let from = resolve(left(item), start)
            successors[from].append(i)
            inDegree[i] += 1
            let to = resolve(right(item), end)
            successors[i].append(to)
            inDegree[to] += 1
        }

        func rank(_ node: Int) -> (Int, UInt64) {
            if node == start { return (Int.min, 0) }
            if node == end { return (Int.max, UInt64.max) }
            let crdt = id(items[node])
            return (-Int(crdt.author), crdt.counter)
        }

        // ponytail: linear scan of the ready set; it holds one or two nodes on real pages
        var ready = Set((0..<count + 2).filter { inDegree[$0] == 0 })
        var placed = Array(repeating: false, count: count + 2)
        var order: [T] = []
        order.reserveCapacity(count)
        while let best = ready.min(by: { rank($0) < rank($1) }) {
            ready.remove(best)
            placed[best] = true
            if best < count { order.append(items[best]) }
            for next in successors[best] {
                inDegree[next] -= 1
                if inDegree[next] == 0 { ready.insert(next) }
            }
        }
        if order.count < count {
            for i in 0..<count where !placed[i] { order.append(items[i]) }
        }
        return order
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter ToposortTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): crdt sequence ordering"
```

---

### Task 14: v3/v5 parser

**Files:**
- Create: `RMKit/Sources/RMKit/Parse/RMV5.swift`
- Test: `RMKit/Tests/RMKitTests/RMV5Tests.swift`

The flat pre-v6 format: a 43-byte header, then layer count, then per layer the line count, then per line pen, colour, padding, base size, (v5 only) an unknown int, the point count, and points of six float32s. An unknown pen or colour code throws, as rmapi-js's zod schema does. That makes the whole page unreadable, which is loud, which is the point.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/RMV5Tests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct RMV5Tests {
    @Test func readsLayersOfStrokes() throws {
        let page = try RMV5.parse(Fixtures.v5(), version: 5)
        #expect(page.version == 5)
        #expect(page.strokes.count == 1)
        #expect(page.strokes[0].pen == .ballpoint)
        #expect(page.strokes[0].color == .black)
        #expect(page.strokes[0].points.map(\.x) == [10, 30])
        #expect(page.strokes[0].points[0].width == 2.5)
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter RMV5Tests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `RMV5.swift`**

`RMKit/Sources/RMKit/Parse/RMV5.swift`:

```swift
import Foundation

/// The flat v3/v5 format: layers of strokes of six-float points.
/// Ported from rmapi-js `rm5.js` (MIT).
enum RMV5 {
    static func parse(_ data: Data, version: Int) throws -> RMPage {
        let r = ByteReader(data, offset: rmHeaderLength)
        var strokes: [RawStroke] = []
        for _ in 0..<(try count(r)) {
            for _ in 0..<(try count(r)) {
                let penCode = Int(try r.i32())
                guard let pen = Pen(code: penCode) else { throw RMParseError.unknownPen(penCode) }
                let colorCode = Int(try r.i32())
                guard let color = InkColor(code: colorCode) else { throw RMParseError.unknownColor(colorCode) }
                _ = try r.i32() // padding
                let baseSize = try Double(r.f32())
                if version == 5 { _ = try r.i32() } // unknown
                let pointCount = try count(r)
                guard pointCount <= r.remaining / 24 else { throw RMParseError.truncated }
                var points: [RawPoint] = []
                points.reserveCapacity(pointCount)
                for _ in 0..<pointCount {
                    let x = try Double(r.f32()), y = try Double(r.f32())
                    let speed = try Double(r.f32()), direction = try Double(r.f32())
                    let width = try Double(r.f32()), pressure = try Double(r.f32())
                    points.append(RawPoint(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure))
                }
                strokes.append(RawStroke(
                    pen: pen, color: color, colorRgba: nil, thicknessScale: baseSize,
                    points: points, id: nil, hidden: false))
            }
        }
        return RMPage(version: version, strokes: strokes, paperSize: nil, unreadableBlocks: 0)
    }

    private static func count(_ r: ByteReader) throws -> Int {
        let value = try r.i32()
        guard value >= 0 else { throw RMParseError.truncated }
        return Int(value)
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter RMV5Tests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): v3/v5 parser"
```

---

### Task 15: v6 parser

**Files:**
- Create: `RMKit/Sources/RMKit/Parse/RMV6.swift`
- Create: `RMKit/Sources/RMKit/Parse/ParseRM.swift`
- Test: `RMKit/Tests/RMKitTests/RMV6Tests.swift`

A v6 file is a 43-byte header, then blocks. Each block is `length u32, reserved u8, minVersion u8, currentVersion u8, type u8`, then a body bounded by `length`.
- **Read:** 0x02 (layer label and visibility), 0x04 (a layer placed in its parent), 0x05 (a stroke) and 0x0d (scene info: `paperSize`).
- **Skipped on purpose** (not ink): text 0x07, glyphs 0x03, authors 0x09, page info 0x0a, migration 0x00, tombstones 0x08.
- **A block that fails to parse** is counted in `unreadableBlocks`, not thrown. That marks the page lossy and keeps the rest of its ink.
- **Point format:** block version 1 has 24-byte points of six float32s, rescaled the way rmapi-js does it. Newer versions have 14 bytes: `x f32, y f32, speed u16, width u16, direction u8, pressure u8`.
- **Item value subblock:** `allowTrailing`, so future firmware fields don't cost a stroke.
- **Flattening:** the root holds layers, and a layer with `visible == false` hides everything under it.
- **Fixtures:** the tests use rmscene's sample pages from Task 1.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/RMV6Tests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct RMV6Tests {
    @Test func readsEveryStrokeOfASample() throws {
        let page = try parseRM(try Fixtures.data("Color_and_tool_v3.14.4", "rm"))
        #expect(page.version == 6)
        #expect(page.unreadableBlocks == 0)
        #expect(page.strokes.count == 25)
        #expect(Set(page.strokes.map(\.pen)) == [.ballpoint, .shader])
        #expect(page.strokes.contains { $0.colorRgba != nil }) // the shader carries its own colour
        #expect(page.strokes.allSatisfy { $0.id != nil && !$0.points.isEmpty })
    }

    @Test func aTextOnlyPageHasNoStrokes() throws {
        let page = try parseRM(try Fixtures.data("Normal_AB", "rm"))
        #expect(page.strokes.isEmpty)
        #expect(page.unreadableBlocks == 0)
    }

    @Test func aTruncatedFileKeepsWhatParsedAndSaysSo() throws {
        let data = try Fixtures.data("Color_and_tool_v3.14.4", "rm")
        let page = try parseRM(data.prefix(data.count - 10))
        #expect(page.unreadableBlocks > 0)
    }

    @Test func refusesSomethingElse() {
        #expect(throws: RMParseError.notAnRMFile) { try parseRM(Data("hello".utf8)) }
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter RMV6Tests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `RMV6.swift`**

`RMKit/Sources/RMKit/Parse/RMV6.swift`:

```swift
import Foundation

/// The v6 scene format: a sequence of typed blocks building a CRDT scene tree.
/// Ported from rmapi-js `rm6.js` (MIT), which follows rmscene (MIT).
/// Only the blocks that carry ink are read; text, glyphs, authors and page
/// info are skipped here.
enum RMV6 {
    static func parse(_ data: Data) throws -> RMPage {
        let reader = ByteReader(data, offset: rmHeaderLength)
        var scene = SceneBuilder()
        var unreadable = 0
        while !reader.atEnd {
            if reader.remaining < 8 { break }
            let length = Int(try reader.u32())
            _ = try reader.u8() // reserved
            _ = try reader.u8() // min version
            let version = try reader.u8()
            let blockType = try reader.u8()
            let start = reader.offset
            guard length <= reader.remaining else {
                unreadable += 1
                break
            }
            let end = start + length
            do {
                try reader.bounded(to: end) {
                    try scene.read(blockType: blockType, version: version, from: reader)
                }
            } catch {
                unreadable += 1
            }
            reader.seek(end)
        }
        return scene.page(unreadableBlocks: unreadable)
    }
}

private struct SceneBuilder {
    enum Value {
        case group(CrdtID)
        case line(RawStroke)
    }

    struct Child {
        let itemID, left, right: CrdtID
        let value: Value
    }

    struct Node {
        var visible: Bool?
        var children: [Child] = []
    }

    var nodes: [CrdtID: Node] = [CrdtID.root: Node()]
    var paperSize: PaperSize?

    mutating func read(blockType: UInt8, version: UInt8, from r: ByteReader) throws {
        switch blockType {
        case 0x02: // tree node: a layer's label and visibility
            let node = try r.id(1)
            _ = try r.lww(2) { try r.string(2) }
            let visible = try r.lww(3) { try r.bool(2) }
            nodes[node, default: Node()].visible = visible
        case 0x04: // group item: a layer placed in its parent
            if let found = try Self.item(r, type: 0x02, { .group(try r.id(2)) }) {
                nodes[found.parent, default: Node()].children.append(found.child)
            }
        case 0x05: // line item: a stroke
            if let found = try Self.item(r, type: 0x03, { .line(try Self.line(r, version: version)) }) {
                nodes[found.parent, default: Node()].children.append(found.child)
            }
        case 0x0d: // scene info
            _ = try r.lww(1) { try r.id(2) }
            if r.hasTag(2, .length4) { _ = try r.lww(2) { try r.bool(2) } }
            if r.hasTag(3, .length4) { _ = try r.lww(3) { try r.bool(2) } }
            if r.hasTag(5, .length4) {
                paperSize = try r.subblock(5) {
                    let width = Int(try r.u32())
                    return PaperSize(width: width, height: Int(try r.u32()))
                }
            }
        default:
            break
        }
    }

    private static func item(
        _ r: ByteReader,
        type itemType: UInt8,
        _ value: () throws -> Value
    ) throws -> (parent: CrdtID, child: Child)? {
        let parent = try r.id(1)
        let itemID = try r.id(2)
        let left = try r.id(3)
        let right = try r.id(4)
        _ = try r.int(5) // deleted length
        guard r.hasTag(6, .length4) else { return nil } // a deleted item has no value
        let found: Value? = try r.subblock(6, allowTrailing: true) {
            guard try r.u8() == itemType else { return nil }
            return try value()
        }
        guard let found else { return nil }
        return (parent, Child(itemID: itemID, left: left, right: right, value: found))
    }

    private static func line(_ r: ByteReader, version: UInt8) throws -> RawStroke {
        let penCode = Int(try r.int(1))
        guard let pen = Pen(code: penCode) else { throw RMParseError.unknownPen(penCode) }
        let colorCode = Int(try r.int(2))
        guard let color = InkColor(code: colorCode) else { throw RMParseError.unknownColor(colorCode) }
        let thicknessScale = try r.double(3)
        _ = try r.float(4) // starting length
        let points: [RawPoint] = try r.subblock(5) {
            let size = version == 1 ? 24 : 14
            let count = r.remaining / size
            var points: [RawPoint] = []
            points.reserveCapacity(count)
            for _ in 0..<count {
                let x = try Double(r.f32())
                let y = try Double(r.f32())
                if version == 1 {
                    let speed = try Double(r.f32()) * 4
                    let direction = try Double(r.f32()) * 255 / (2 * Double.pi)
                    let width = try Double(r.f32()) * 4
                    let pressure = try Double(r.f32()) * 255
                    points.append(RawPoint(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure))
                } else {
                    let speed = try Double(r.u16())
                    let width = try Double(r.u16())
                    let direction = try Double(r.u8())
                    let pressure = try Double(r.u8())
                    points.append(RawPoint(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure))
                }
            }
            return points
        }
        if r.hasTag(6, .id) { _ = try r.id(6) } // timestamp
        if r.hasTag(7, .id) { _ = try r.id(7) } // move id
        let rgba = r.hasTag(8, .byte4) ? try r.int(8) : nil
        return RawStroke(
            pen: pen, color: color, colorRgba: rgba, thicknessScale: thicknessScale,
            points: points, id: nil, hidden: false)
    }

    /// Flatten the tree back to front. The root holds layers; a hidden layer
    /// hides everything under it.
    func page(unreadableBlocks: Int) -> RMPage {
        var strokes: [RawStroke] = []
        var visited: Set<CrdtID> = []
        func walk(_ id: CrdtID, hidden: Bool, groupsOnly: Bool) {
            guard let node = nodes[id], visited.insert(id).inserted else { return }
            let hidden = hidden || node.visible == false
            let ordered = Toposort.order(node.children, id: \.itemID, left: \.left, right: \.right)
            for child in ordered {
                switch child.value {
                case .group(let group):
                    walk(group, hidden: hidden, groupsOnly: false)
                case .line(var stroke) where !groupsOnly:
                    stroke.id = child.itemID
                    stroke.hidden = hidden
                    strokes.append(stroke)
                case .line:
                    break
                }
            }
        }
        walk(.root, hidden: false, groupsOnly: true)
        return RMPage(version: 6, strokes: strokes, paperSize: paperSize, unreadableBlocks: unreadableBlocks)
    }
}
```

**Step 4: Implement `ParseRM.swift`**

`RMKit/Sources/RMKit/Parse/ParseRM.swift`:

```swift
import Foundation

private let rmHeaderPrefix = "reMarkable .lines file, version="

/// Parse a `.rm` page file of version 3, 5 or 6.
public func parseRM(_ data: Data) throws -> RMPage {
    guard data.count >= rmHeaderLength else { throw RMParseError.notAnRMFile }
    let header = String(decoding: data.prefix(rmHeaderLength), as: UTF8.self)
    guard header.hasPrefix(rmHeaderPrefix) else { throw RMParseError.notAnRMFile }
    let version = header.dropFirst(rmHeaderPrefix.count).prefix(1)
    switch version {
    case "6": return try RMV6.parse(data)
    case "3": return try RMV5.parse(data, version: 3)
    case "5": return try RMV5.parse(data, version: 5)
    default: throw RMParseError.unsupportedVersion(String(version))
    }
}
```

**Step 5: Run the tests**

Run: `swift test --package-path RMKit --filter RMV6Tests`
Expected: PASS.

**Step 6: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): v6 scene parser"
```

---

### Task 16: Palette

**Files:**
- Create: `RMKit/Sources/RMKit/Render/Palette.swift`
- Test: `RMKit/Tests/RMKitTests/PaletteTests.swift`

Port of rm2agent `src/render/palette.ts`, kept exhaustive with `switch`, so a pen or colour added later fails the build instead of painting black. A packed `colorRgba` (`0xAARRGGBB`) wins over the colour code. Zero means "absent", not transparent black. The pen caps opacity: highlighter 0.35, shader 0.5.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/PaletteTests.swift`:

```swift
import Testing
@testable import RMKit

@Suite struct PaletteTests {
    @Test func packedColourWinsAndIsCappedByThePen() {
        let style = Palette.style(pen: .highlighter, color: .highlight, rgba: 0xff_ff_00_00)
        #expect(style.color == "#ff0000")
        #expect(style.opacity == 0.35)
    }

    @Test func zeroIsNoColourAndErasersErase() {
        #expect(Palette.style(pen: .ballpoint, color: .blue, rgba: 0).color == "#0062cc")
        #expect(Palette.style(pen: .eraser, color: .black, rgba: nil).erase)
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter PaletteTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `Palette.swift`**

`RMKit/Sources/RMKit/Render/Palette.swift`:

```swift
import Foundation

/// The paint one stroke needs.
public struct StrokeStyle: Sendable, Equatable {
    /// `#rrggbb`
    public var color: String
    /// 0...1
    public var opacity: Double
    /// Eraser strokes remove ink rather than add it.
    public var erase: Bool
    public var pen: Pen
}

/// Pen and colour codes to paint. Ported from rm2agent `palette.ts`. The
/// switches are exhaustive on purpose: a pen or colour added upstream must
/// fail the build, not paint black.
public enum Palette {
    static func shade(_ color: InkColor) -> String {
        switch color {
        case .black: "#000000"
        case .gray, .grayOverlap: "#808080"
        case .white: "#ffffff"
        case .yellow, .highlight: "#f5d800"
        case .green: "#00a000"
        case .pink: "#ff70c0"
        case .blue: "#0062cc"
        case .red: "#d02020"
        case .cyan: "#00b0c0"
        case .magenta: "#c000a0"
        }
    }

    static func maxOpacity(_ pen: Pen) -> Double {
        switch pen {
        case .highlighter: 0.35
        case .shader: 0.5
        case .brush, .pencil, .ballpoint, .marker, .fineliner, .mechanicalPencil,
             .calligraphy, .eraser, .eraseArea: 1
        }
    }

    public static func style(pen: Pen, color: InkColor, rgba: UInt32?) -> StrokeStyle {
        var hex = shade(color)
        var opacity = 1.0
        // a packed zero is an absent field, not transparent black
        if let rgba, rgba != 0 {
            hex = String(format: "#%02x%02x%02x", (rgba >> 16) & 0xff, (rgba >> 8) & 0xff, rgba & 0xff)
            let alpha = rgba >> 24
            if alpha != 0 { opacity = Double(alpha) / 255 }
        }
        return StrokeStyle(
            color: hex,
            opacity: min(opacity, maxOpacity(pen)),
            erase: pen == .eraser || pen == .eraseArea,
            pen: pen)
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter PaletteTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): pen and colour palette"
```

---

### Task 17: Geometry and stroke normalization

**Files:**
- Create: `RMKit/Sources/RMKit/Render/Geometry.swift`
- Create: `RMKit/Sources/RMKit/Render/Strokes.swift`
- Test: `RMKit/Tests/RMKitTests/StrokesTests.swift`

Port of rm2agent `src/render/strokes.ts` and `geometry.ts`.
- **v6 x coordinates** are relative to the page's horizontal centre in the *current orientation* (a landscape page centres at 936).
- **v6 widths** are quarter pixels and pressure is a byte; v3/v5 store pixels and 0...1.
- **Widths already include pressure**, so never scale them again.
- **Dropped strokes are counted:** erasers and hidden layers are the page as the user left it; empty strokes, non-finite points and clamped values are loss (`isLossy`).
- **Page size:** the geometry is built from the page's own `paperSize` (1620×2160 on Paper Pro, absent on rm2, meaning 1404×1872).

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/StrokesTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct StrokesTests {
    func raw(_ pen: Pen, points: [RawPoint], hidden: Bool = false) -> RawStroke {
        RawStroke(pen: pen, color: .black, colorRgba: nil, thicknessScale: 1, points: points, id: nil, hidden: hidden)
    }

    @Test func v5PointsPassThroughInDevicePixels() throws {
        let ink = normalize(try parseRM(Fixtures.v5()), orientation: .portrait)
        #expect(ink.strokes.map(\.points) == [[
            StrokePoint(x: 10, y: 20, width: 2.5, pressure: 0.5),
            StrokePoint(x: 30, y: 40, width: 2.5, pressure: 0.5),
        ]])
    }

    @Test func v6IsCentredAndScaledByOrientation() {
        let point = RawPoint(x: 0, y: 5, speed: 0, direction: 0, width: 8, pressure: 255)
        let page = RMPage(version: 6, strokes: [raw(.fineliner, points: [point])], paperSize: nil, unreadableBlocks: 0)
        let landscape = normalize(page, orientation: .landscape)
        #expect(landscape.geometry.width == 1872)
        #expect(landscape.strokes[0].points == [StrokePoint(x: 936, y: 5, width: 2, pressure: 1)])
    }

    @Test func countsWhatItLeavesOut() {
        let point = RawPoint(x: 1, y: 1, speed: 0, direction: 0, width: 4, pressure: 100)
        let page = RMPage(version: 6, strokes: [
            raw(.eraser, points: [point]),
            raw(.ballpoint, points: [point], hidden: true),
            raw(.ballpoint, points: []),
            raw(.ballpoint, points: [RawPoint(x: .nan, y: 1, speed: 0, direction: 0, width: 4, pressure: 1), point]),
        ], paperSize: nil, unreadableBlocks: 0)
        let ink = normalize(page, orientation: .portrait)
        #expect(ink.strokes.count == 1)
        #expect(ink.drops == PageDrops(eraserStrokes: 1, hiddenStrokes: 1, emptyStrokes: 1, nonFinitePoints: 1))
        #expect(ink.drops.isLossy)
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter StrokesTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `Geometry.swift`**

`RMKit/Sources/RMKit/Render/Geometry.swift`:

```swift
import Foundation

/// A page's coordinate system, origin top-left, in device pixels.
/// Ported from rm2agent `geometry.ts`.
public struct PageGeometry: Sendable, Equatable {
    /// rm1, rm2 and Paper Pure; the size of any page that declares none.
    public static let defaultScreen = PaperSize(width: 1404, height: 1872)

    public let width: Double
    public let height: Double
    public let orientation: Orientation

    /// `portrait` is the page's native portrait size (a v6 `paperSize`).
    public init(portrait: PaperSize?, orientation: Orientation) {
        let size = portrait ?? Self.defaultScreen
        let short = Double(size.width), long = Double(size.height)
        width = orientation == .landscape ? long : short
        height = orientation == .landscape ? short : long
        self.orientation = orientation
    }

    /// v6 stores x relative to the page's horizontal centre; v3/v5 from the left edge.
    func toPage(x: Double, y: Double, version: Int) -> (x: Double, y: Double) {
        version == 6 ? (x + width / 2, y) : (x, y)
    }
}

public struct Box: Sendable, Equatable {
    public var x, y, width, height: Double
}

struct Bounds {
    var minX, minY, maxX, maxY: Double
}

func bounds<S: Sequence>(of points: S) -> Bounds? where S.Element == (x: Double, y: Double) {
    var result: Bounds?
    for p in points {
        if var b = result {
            b.minX = min(b.minX, p.x); b.minY = min(b.minY, p.y)
            b.maxX = max(b.maxX, p.x); b.maxY = max(b.maxY, p.y)
            result = b
        } else {
            result = Bounds(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y)
        }
    }
    return result
}

/// The page box grown to cover ink dragged off the page, which the move tool allows.
func renderBox(_ page: PageGeometry, ink: Bounds?) -> Box {
    guard let ink else { return Box(x: 0, y: 0, width: page.width, height: page.height) }
    let x = min(0, ink.minX), y = min(0, ink.minY)
    return Box(x: x, y: y, width: max(page.width, ink.maxX) - x, height: max(page.height, ink.maxY) - y)
}
```

**Step 4: Implement `Strokes.swift`**

`RMKit/Sources/RMKit/Render/Strokes.swift`:

```swift
import Foundation

/// One sample along a stroke, in page coordinates.
public struct StrokePoint: Sendable, Equatable {
    public var x, y: Double
    /// Already includes pressure for the pens that respond to it: never scale it again.
    public var width: Double
    /// 0...1
    public var pressure: Double
}

public struct NormalizedStroke: Sendable {
    public var points: [StrokePoint]
    public var style: StrokeStyle
    public var id: CrdtID?
}

/// Everything on the page that is not in the stroke list, counted.
public struct PageDrops: Sendable, Equatable {
    public var eraserStrokes = 0
    public var hiddenStrokes = 0
    public var emptyStrokes = 0
    public var nonFinitePoints = 0
    public var clampedWidths = 0
    public var clampedPressures = 0
    public var unreadableBlocks = 0

    /// Erasers and hidden layers are the page as the user left it; the rest is loss.
    public var isLossy: Bool {
        emptyStrokes + nonFinitePoints + clampedWidths + clampedPressures + unreadableBlocks > 0
    }
}

public struct NormalizedPage: Sendable {
    public var strokes: [NormalizedStroke]
    public var drops: PageDrops
    public var geometry: PageGeometry
}

/// The narrowest a stroke is drawn; defensive, real widths start at 1.5.
private let minWidth = 0.5

/// Every `.rm` version in, one back-to-front stroke list in page coordinates
/// out. Ported from rm2agent `strokes.ts`. Orientation is a document-level
/// fact from `.content`; no page carries it.
public func normalize(_ page: RMPage, orientation: Orientation) -> NormalizedPage {
    let geometry = PageGeometry(portrait: page.paperSize, orientation: orientation)
    // v6 stores widths in quarter pixels and pressure as a byte
    let widthDivisor = page.version == 6 ? 4.0 : 1.0
    let pressureDivisor = page.version == 6 ? 255.0 : 1.0
    var drops = PageDrops(unreadableBlocks: page.unreadableBlocks)
    var strokes: [NormalizedStroke] = []

    for raw in page.strokes {
        if raw.hidden {
            drops.hiddenStrokes += 1
            continue
        }
        let style = Palette.style(pen: raw.pen, color: raw.color, rgba: raw.colorRgba)
        if style.erase {
            drops.eraserStrokes += 1
            continue
        }
        var points: [StrokePoint] = []
        points.reserveCapacity(raw.points.count)
        for point in raw.points {
            let (x, y) = geometry.toPage(x: point.x, y: point.y, version: page.version)
            guard x.isFinite, y.isFinite else {
                drops.nonFinitePoints += 1
                continue
            }
            var width = point.width / widthDivisor
            if !width.isFinite || width < minWidth {
                drops.clampedWidths += 1
                width = minWidth
            }
            var pressure = point.pressure / pressureDivisor
            if !pressure.isFinite {
                drops.clampedPressures += 1
                pressure = 0
            }
            points.append(StrokePoint(x: x, y: y, width: width, pressure: pressure))
        }
        if points.isEmpty {
            drops.emptyStrokes += 1
            continue
        }
        strokes.append(NormalizedStroke(points: points, style: style, id: raw.id))
    }
    return NormalizedPage(strokes: strokes, drops: drops, geometry: geometry)
}
```

**Step 5: Run the tests**

Run: `swift test --package-path RMKit --filter StrokesTests`
Expected: PASS.

**Step 6: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): page geometry and stroke normalization"
```

---

### Task 18: SVG port and the rm2agent golden check

**Files:**
- Create: `RMKit/Sources/RMKit/Render/SVG.swift`
- Test: `RMKit/Tests/RMKitTests/GoldenTests.swift`

A byte-identical port of rm2agent `src/render/svg.ts`, used as the oracle for the parser and normalization. Two JavaScript semantics matter:
- `Math.round(x)` is `floor(x + 0.5)`, not Swift's `.rounded()`, which rounds half away from zero.
- `String(n)` prints integers without `.0`.

The golden test renders each rmscene sample and compares it line by line with the SVG rm2agent made in Task 1. **When this plan was proven, all 13 samples and 8 pages from the user's real library matched byte for byte.**

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/GoldenTests.swift`:

```swift
import Foundation
import Testing
@testable import RMKit

@Suite struct GoldenTests {
    @Test func fixturesArePresent() {
        #expect(Fixtures.rmsceneNames().count == 13)
    }

    @Test(arguments: Fixtures.rmsceneNames())
    func matchesRm2agent(name: String) throws {
        let page = try parseRM(try Fixtures.data(name, "rm"))
        let normalized = normalize(page, orientation: .portrait)
        #expect(!normalized.drops.isLossy)
        let ours = try SVG.render(normalized).split(separator: "\n", omittingEmptySubsequences: false)
        let theirs = String(decoding: try Fixtures.data(name, "svg"), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(ours.count == theirs.count, "line count \(ours.count) vs rm2agent \(theirs.count)")
        if let line = zip(ours, theirs).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            Issue.record("line \(line + 1) differs\n ours:     \(ours[line].prefix(200))\n rm2agent: \(theirs[line].prefix(200))")
        }
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter GoldenTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `SVG.swift`**

`RMKit/Sources/RMKit/Render/SVG.swift`:

```swift
import Foundation

/// A stretch of a stroke drawn at one width.
struct Run {
    var width: Double
    var points: [StrokePoint]
}

/// Port of rm2agent `svg.ts`, kept byte-identical so the two can be diffed.
/// Number formatting and rounding follow JavaScript's `String(n)` and `Math.round`.
public enum SVG {
    public enum Error: Swift.Error { case nonFinite(String), badColor(String) }

    private static let coordDecimals = 1
    private static let opacityDecimals = 2
    private static let minOpacity = 0.01
    private static let maxMagnitude = 9_007_199_254_740_991.0 / 10

    static func round(_ value: Double, _ decimals: Int, _ what: String) throws -> Double {
        guard value.isFinite, abs(value) <= maxMagnitude else { throw Error.nonFinite(what) }
        let scale = pow(10, Double(decimals))
        // Math.round is floor(x + 0.5); `+ 0` turns -0 into 0
        return (value * scale + 0.5).rounded(.down) / scale + 0
    }

    static func coord(_ value: Double, _ what: String) throws -> Double {
        try round(value, coordDecimals, what)
    }

    /// JavaScript's `String(n)` for the values this file produces.
    static func js(_ value: Double) -> String {
        if value == value.rounded(.towardZero), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    static func runs(_ points: [StrokePoint]) throws -> [Run] {
        var runs: [Run] = []
        var previous: StrokePoint?
        for point in points {
            if let prev = previous {
                let width = try coord((prev.width + point.width) / 2, "width")
                if let last = runs.last, last.width == width {
                    runs[runs.count - 1].points.append(point)
                } else {
                    runs.append(Run(width: width, points: [prev, point]))
                }
            }
            previous = point
        }
        if runs.isEmpty, let previous {
            runs.append(Run(width: try coord(previous.width, "width"), points: [previous]))
        }
        return runs
    }

    /// The page box, grown to the painted extent of the ink, snapped outward to the 0.1 grid.
    public static func paintBox(_ page: NormalizedPage) throws -> Box {
        var corners: [(x: Double, y: Double)] = []
        for stroke in page.strokes {
            for run in try runs(stroke.points) {
                let radius = run.width / 2
                for point in run.points {
                    let x = try coord(point.x, "x"), y = try coord(point.y, "y")
                    corners.append((x - radius, y - radius))
                    corners.append((x + radius, y + radius))
                }
            }
        }
        let box = renderBox(page.geometry, ink: bounds(of: corners))
        let grid = pow(10, Double(coordDecimals))
        let left = (box.x * grid).rounded(.down), top = (box.y * grid).rounded(.down)
        let right = ((box.x + box.width) * grid).rounded(.up)
        let bottom = ((box.y + box.height) * grid).rounded(.up)
        return Box(x: left / grid, y: top / grid, width: (right - left) / grid, height: (bottom - top) / grid)
    }

    private static func pathData(_ run: Run) throws -> String {
        let first = run.points[0]
        let tail = run.points.count == 1 ? run.points[...] : run.points.dropFirst()
        var parts = ["M\(js(try coord(first.x, "x"))) \(js(try coord(first.y, "y")))"]
        for p in tail { parts.append("L\(js(try coord(p.x, "x"))) \(js(try coord(p.y, "y")))") }
        return parts.joined(separator: " ")
    }

    public static func render(_ page: NormalizedPage) throws -> String {
        let box = try paintBox(page)
        let viewBox = [box.x, box.y, box.width, box.height].map(js).joined(separator: " ")
        var parts = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(viewBox)\" width=\"\(js(box.width))\" height=\"\(js(box.height))\">",
            "<g fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\">",
        ]
        for stroke in page.strokes {
            let runs = try runs(stroke.points)
            if runs.isEmpty { continue }
            let color = stroke.style.color
            guard color.count == 7, color.hasPrefix("#"), UInt32(color.dropFirst(), radix: 16) != nil else {
                throw Error.badColor(color)
            }
            let opacity = max(try round(stroke.style.opacity, opacityDecimals, "opacity"), minOpacity)
            if opacity < 1, runs.count > 1 {
                // one group so overlapping runs of one stroke don't darken each other
                parts.append("<g stroke=\"\(color)\" opacity=\"\(js(opacity))\">")
                for run in runs {
                    parts.append("<path d=\"\(try pathData(run))\" stroke-width=\"\(js(run.width))\"/>")
                }
                parts.append("</g>")
                continue
            }
            let fade = opacity < 1 ? " stroke-opacity=\"\(js(opacity))\"" : ""
            for run in runs {
                parts.append("<path d=\"\(try pathData(run))\" stroke=\"\(color)\"\(fade) stroke-width=\"\(js(run.width))\"/>")
            }
        }
        parts.append("</g>")
        parts.append("</svg>")
        return parts.joined(separator: "\n")
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter GoldenTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): byte-identical svg port and rm2agent golden test"
```

---

### Task 19: Core Graphics flat renderer

**Files:**
- Create: `RMKit/Sources/RMKit/Render/FlatRenderer.swift`
- Test: `RMKit/Tests/RMKitTests/FlatRendererTests.swift`

Same runs and paint as the SVG, without the rounding. The y-flip and scale are set up once, so drawing code works in page coordinates with y down. A translucent stroke is drawn inside one transparency layer with the stroke's alpha. Otherwise, where its runs overlap, the highlighter would darken itself; the second test checks exactly that.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/FlatRendererTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing
@testable import RMKit

@Suite struct FlatRendererTests {
    func page(_ strokes: [NormalizedStroke]) -> NormalizedPage {
        NormalizedPage(strokes: strokes, drops: PageDrops(), geometry: PageGeometry(portrait: nil, orientation: .portrait))
    }

    func stroke(_ points: [(Double, Double, Double)], opacity: Double) -> NormalizedStroke {
        NormalizedStroke(
            points: points.map { StrokePoint(x: $0.0, y: $0.1, width: $0.2, pressure: 1) },
            style: StrokeStyle(color: "#000000", opacity: opacity, erase: false, pen: .ballpoint))
    }

    /// The red channel at a pixel, rows counted from the top.
    func red(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels[(y * image.width + x) * 4]
    }

    @Test func drawsInkWhereThePageSaysWithYDown() throws {
        let image = try FlatRenderer.image(page([stroke([(100, 100, 10), (300, 100, 10)], opacity: 1)]), scale: 0.5)
        #expect(image.width == 702)
        #expect(red(image, 100, 50) < 40) // on the line
        #expect(red(image, 100, 800) > 250) // far below it
    }

    @Test func aTranslucentStrokeDoesNotDarkenWhereItOverlapsItself() throws {
        // runs of width 20 then 30 over the same line; only the wide one reaches y = 112
        let ink = page([stroke([(100, 100, 20), (500, 100, 20), (100, 100, 40)], opacity: 0.35)])
        let image = try FlatRenderer.image(ink, scale: 0.5)
        let overlap = Int(red(image, 150, 50)), single = Int(red(image, 150, 56))
        #expect(abs(overlap - single) <= 3)
        #expect(abs(overlap - 166) <= 4) // 255 * (1 - 0.35)
    }
}
```

**Step 2: Run it to see it fail**

Run: `swift test --package-path RMKit --filter FlatRendererTests`
Expected: a build failure naming the types this task adds.

**Step 3: Implement `FlatRenderer.swift`**

`RMKit/Sources/RMKit/Render/FlatRenderer.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flat ink with Core Graphics: the same runs and paint as the SVG port,
/// unrounded. A translucent stroke is drawn in one transparency layer, so its
/// overlapping runs don't darken each other.
public enum FlatRenderer {
    /// Draw into a context whose user space is page coordinates, y down.
    public static func draw(_ page: NormalizedPage, in context: CGContext) throws {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in page.strokes {
            let runs = try SVG.runs(stroke.points)
            guard !runs.isEmpty else { continue }
            let opacity = stroke.style.opacity
            if opacity < 1 {
                context.setAlpha(opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            context.setStrokeColor(color(stroke.style.color))
            for run in runs {
                context.beginPath()
                context.move(to: CGPoint(x: run.points[0].x, y: run.points[0].y))
                // a one-point run still draws: a zero-length segment with a round cap is a dot
                for point in run.points.count == 1 ? run.points[...] : run.points.dropFirst() {
                    context.addLine(to: CGPoint(x: point.x, y: point.y))
                }
                context.setLineWidth(run.width)
                context.strokePath()
            }
            if opacity < 1 {
                context.endTransparencyLayer()
                context.setAlpha(1)
            }
        }
    }

    /// The page on white, covering the same box as the SVG.
    public static func image(_ page: NormalizedPage, scale: Double) throws -> CGImage {
        let box = try SVG.paintBox(page)
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SVG.Error.nonFinite("bitmap \(width)x\(height)") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -box.x, y: -box.y)
        try draw(page, in: context)
        return context.makeImage()!
    }

    public static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func color(_ hex: String) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}
```

**Step 4: Run the tests**

Run: `swift test --package-path RMKit --filter FlatRendererTests`
Expected: PASS.

**Step 5: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): core graphics flat renderer"
```

---

### Task 20: Documents and the developer CLI

**Files:**
- Create: `RMKit/Sources/RMKit/Model/Document.swift`
- Create: `RMKit/Sources/remora-cli/RemoraCLI.swift`

`Document` is the glue the CLI and the app share: it loads a document's file list, `.content` and `.pagedata`, builds the page map, and parses one page's ink on demand (nil for a page nobody drew on). Its check is the live test in Task 21, because it is pure wiring over parts that are already tested.

The CLI is a developer tool only. No ArgumentParser dependency: a `switch` over the arguments.

**Step 1: Implement `Document.swift`**

`RMKit/Sources/RMKit/Model/Document.swift`:

```swift
import Foundation

/// An opened document: its files, its content and its pages in order.
public struct Document: Sendable {
    public let id: String
    public let files: [Entry]
    public let content: DocumentContent
    public let pages: [PageRef]

    public static func load(_ item: LibraryItem, blobs: BlobStore) async throws -> Document {
        let files = try await blobs.entries(hash: item.hash, id: item.id)
        guard let contentFile = files.first(where: { $0.id == "\(item.id).content" }) else {
            throw CloudError.malformed("\(item.id) has no .content")
        }
        let content = try JSONDecoder().decode(DocumentContent.self, from: try await blobs.data(hash: contentFile.hash, name: contentFile.id))
        var pagedata: [String] = []
        if let file = files.first(where: { $0.id == "\(item.id).pagedata" }) {
            pagedata = String(decoding: try await blobs.data(hash: file.hash, name: file.id), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        let prefix = "\(item.id)/"
        let rmPageIDs = files.map(\.id)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".rm") }
            .map { String($0.dropFirst(prefix.count).dropLast(3)) }
        let pages = PageMap.pages(content: content, rmPageIDs: rmPageIDs, pagedata: pagedata)
        return Document(id: item.id, files: files, content: content, pages: pages)
    }

    /// The page's ink file; nil for a page nobody drew on.
    public func inkFile(_ page: PageRef) -> Entry? {
        files.first { $0.id == "\(id)/\(page.id).rm" }
    }

    /// The page's strokes, or nil for a blank page.
    public func ink(_ page: PageRef, blobs: BlobStore) async throws -> NormalizedPage? {
        guard let file = inkFile(page) else { return nil }
        let rm = try parseRM(try await blobs.data(hash: file.hash, name: file.id))
        return normalize(rm, orientation: content.orientation)
    }
}
```

**Step 2: Implement `RemoraCLI.swift`**

`RMKit/Sources/remora-cli/RemoraCLI.swift`:

```swift
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
```

**Step 3: Build and check it against the real account (with the user)**

```bash
swift build --package-path RMKit
swift run --package-path RMKit remora-cli
```
Expected: the usage text.

Pair once. Ask the user for a one-time code from https://my.remarkable.com/device/desktop/connect, then:
```bash
swift run --package-path RMKit remora-cli pair <code>
swift run --package-path RMKit remora-cli ls | head
swift run --package-path RMKit remora-cli svg <a notebook id from ls> /tmp/remora-svg && open /tmp/remora-svg
swift run --package-path RMKit remora-cli png <same id> /tmp/remora-png && open /tmp/remora-png
```
Expected: `paired <email>`, the library listed by path, and SVG and PNG files of the notebook's inked pages that look like the tablet.

**If pairing is refused:** the `desktop-macos` device description is unverified. Switch `deviceDesc` to `"browser-chrome"`, which rm2agent uses successfully, and take the code from https://my.remarkable.com/device/browser/connect instead. Then record the outcome in the design doc's "Open questions and risks" section.

**Step 4: Commit**
```bash
git add RMKit
git commit -m "feat(rmkit): documents and the remora-cli developer tool"
```

---

### Task 21: Live test and live golden diff

**Files:**
- Test: `RMKit/Tests/RMKitTests/LiveTests.swift`

The opt-in live test from the design: `REMORA_LIVE_TOKEN` holds a device token. It builds the real library (no failures allowed) and renders the most recent notebooks (no lossy pages allowed). With `REMORA_LIVE_SVG_DIR` set, it also writes the SVGs.

`scripts/golden-live.sh` diffs `remora-cli svg` against `rm2agent export --format svg` page by page for documents you name. Output goes to `golden-out/` (gitignored), because it's your handwriting.

**Step 1: Write the failing test**

`RMKit/Tests/RMKitTests/LiveTests.swift`:

```swift
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
```

**Step 2: The live golden script**

`scripts/golden-live.sh` (make it executable with `chmod +x`):

```bash
#!/usr/bin/env bash
# Diff Remora's SVG against rm2agent's, page by page, for real notebooks.
# usage: scripts/golden-live.sh "<rm2agent path>"...
# Needs rm2agent and jq on PATH and a paired remora-cli. Output stays in
# golden-out/ (gitignored): it is your own handwriting, never commit it.
# Each run mints a session token per tool and document; reMarkable rate-limits
# that exchange, so check a few documents at a time.
set -euo pipefail
out=${GOLDEN_OUT:-golden-out}
status=0
swift build --package-path RMKit -c release --product remora-cli >/dev/null
cli=$(swift build --package-path RMKit -c release --show-bin-path)/remora-cli
for doc in "$@"; do
  manifest=$(rm2agent export "$doc" --format svg --out "$out/rm2agent" --json)
  id=$(jq -r .id <<<"$manifest")
  "$cli" svg "$id" "$out/remora/$id" >/dev/null
  while IFS=$'\t' read -r page svg; do
    if cmp -s "$svg" "$out/remora/$id/$page.svg"; then
      echo "same  $doc  $page"
    else
      echo "DIFF  $doc  $page"
      status=1
    fi
  done < <(jq -r '.pages[] | select(.svg) | [.pageId, .svg] | @tsv' <<<"$manifest")
done
exit $status
```

**Step 3: Run both against the real account**

```bash
swift test --package-path RMKit                       # the live suite is skipped without a token
REMORA_LIVE_TOKEN=$(security find-generic-password -s io.github.gveres.remora -w) \
  REMORA_LIVE_DOCS=5 swift test --package-path RMKit --filter LiveTests
scripts/golden-live.sh "<path of a notebook as rm2agent ls shows it>"
```
Expected: the live suite passes. When this plan was proven it took 37 s from a cold cache, then seconds. Every page prints `same`.

A `DIFF` page is a real finding. Open both SVGs from `golden-out/` side by side, find the first differing line, and fix the port, not the oracle. If `rm2agent export` reports rate-limiting, wait a few minutes. Every run mints session tokens, which is the risk the design doc names.

**Step 4: Commit**
```bash
git add RMKit scripts
git commit -m "test(rmkit): opt-in live test and the live golden diff against rm2agent"
```

---

## Done when

- `swift test --package-path RMKit` passes: 46 tests in 20 suites, with the live suite skipped and Keychain included.
- The live test passes against the user's account, and `scripts/golden-live.sh` prints only `same` for a handful of notebooks, including at least one Paper Pro (1620-wide) page.
- `remora-cli pair`, `ls`, `svg` and `png` work, and the `deviceDesc` outcome is recorded in the design doc.
- No `TODO`, `.skip` or placeholder code. Check with `grep -rn "TODO\|FIXME" RMKit`, which should print nothing.

Then write plan 2 (the app) against the API this produced.
