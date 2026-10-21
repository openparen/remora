import Foundation
import Testing
@testable import RMKit

@Suite struct CloudSessionTests {
    /// A fake cloud on one host: the token exchange, the root and one file.
    static func fakeCloud(rootStatuses: [Int] = [200], tokenStatus: Int = 200) -> (CloudSession, Locked<Int>) {
        let tokens = Locked(0)
        let roots = Locked(rootStatuses)
        let (session, host) = StubProtocol.make { request in
            switch request.url?.path() {
            case "/token/json/2/user/new":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
                let n = tokens.update { $0 += 1; return $0 }
                guard tokenStatus == 200 else { return (tokenStatus, Data()) }
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

    @Test func givesUpAfterOneRefresh() async throws {
        let (cloud, tokens) = Self.fakeCloud(rootStatuses: [401, 401])
        await #expect(throws: CloudError.unauthorized) { _ = try await cloud.root() }
        #expect(tokens.value == 2)
    }

    @Test func concurrentRequestsShareAFailedExchange() async throws {
        let (cloud, tokens) = Self.fakeCloud(tokenStatus: 429)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await cloud.file(hash: fakeHash(2), name: "doc.content")
                        return false
                    } catch {
                        return true
                    }
                }
            }
            var allThrew = true
            for await threw in group { allThrew = allThrew && threw }
            #expect(allThrew)
        }
        #expect(tokens.value == 1)
    }

    @Test func concurrent401sShareOneRefresh() async throws {
        let tokens = Locked(0)
        let firstToken = Locked<String?>(nil)
        let (session, host) = StubProtocol.make { request in
            switch request.url?.path() {
            case "/token/json/2/user/new":
                let n = tokens.update { $0 += 1; return $0 }
                let token = jwt(["n": n, "exp": Date().timeIntervalSince1970 + 3600])
                firstToken.update { if $0 == nil { $0 = token } }
                return (200, Data(token.utf8))
            case "/sync/v4/root":
                let usingFirst = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(firstToken.value ?? "")"
                return (
                    usingFirst ? 401 : 200,
                    Data(#"{"hash":"\#(fakeHash(1))","generation":7,"schemaVersion":4}"#.utf8)
                )
            default:
                return (404, Data())
            }
        }
        let cloud = CloudSession(deviceToken: "device-token", session: session, authHost: host, syncHost: host)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await cloud.root() } }
            try await group.waitForAll()
        }
        #expect(tokens.value == 2)
    }
}
