import Foundation
import Network
import Testing
@testable import RMKit

@Suite struct NoticesTests {
    @Test func onlySyncCompleteCounts() {
        let sync = #"{"message":{"attributes":{"event":"SyncComplete","sourceDeviceID":"tablet","auth0UserID":"auth0|x"},"messageId":"1"},"subscription":"s"}"#
        #expect(Notices.parse(sync) == SyncNotice(sourceDeviceID: "tablet"))
        #expect(Notices.parse(#"{"message":{"attributes":{"event":"ScreenShareStart"}}}"#) == nil)
        #expect(Notices.parse("not json") == nil)
    }

    @Test func pollingYieldsWithoutASocket() async {
        // no reachable host: the socket keeps failing, the poll still ticks
        let (session, host) = StubProtocol.make { _ in (500, Data()) }
        let cloud = CloudSession(deviceToken: jwt(["device-id": "me"]), session: session, authHost: host, syncHost: host)
        var ticks = 0
        for await _ in cloud.changes(poll: .milliseconds(20)) {
            ticks += 1
            if ticks == 3 { break }
        }
        #expect(ticks == 3)
    }
}

/// A local notification socket. Accepts every client and answers its pings
/// unless `answerPings` is false; drops each client `closeAfter` ms after it
/// connects; with `refuse`, answers the handshake with a plain 401.
final class NoticeServer: Sendable {
    private let listener: NWListener
    private let clients = Locked<[NWConnection]>([])
    /// When each client connected.
    let connects = Locked<[ContinuousClock.Instant]>([])
    /// Clients whose websocket handshake finished.
    let ready = Locked(0)
    /// Clients that closed their end.
    let gone = Locked(0)
    let url: URL

    init(answerPings: Bool = true, closeAfter: Int? = nil, refuse: Bool = false) async throws {
        let parameters = NWParameters.tcp
        if !refuse {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = answerPings
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "NoticeServer")
        listener.newConnectionHandler = { [clients, connects, ready, gone] client in
            connects.update { $0.append(.now) }
            clients.update { $0.append(client) }
            client.stateUpdateHandler = { if case .ready = $0 { ready.update { $0 += 1 } } }
            client.start(queue: queue)
            if refuse {
                let reply = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                client.send(content: Data(reply.utf8), completion: .contentProcessed { _ in client.cancel() })
            }
            if let closeAfter { queue.asyncAfter(deadline: .now() + .milliseconds(closeAfter)) { client.cancel() } }
            // the client's close only shows up to a pending read
            @Sendable func read() {
                client.receiveMessage { _, context, _, error in
                    let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
                    if error != nil || opcode == .close || context?.isFinal == true {
                        gone.update { $0 += 1 }
                    } else {
                        read()
                    }
                }
            }
            read()
        }
        let port = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(port)")!
    }

    deinit {
        listener.cancel()
        for client in clients.value { client.cancel() }
    }

    func send(_ text: String) {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        for client in clients.value {
            client.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    /// A session for device `me` whose token exchanges are counted, syncing against this server.
    func cloud() -> (CloudSession, exchanges: Locked<Int>) {
        let exchanges = Locked(0)
        let (session, auth) = StubProtocol.make { _ in
            exchanges.update { $0 += 1 }
            return (200, Data(jwt(["exp": Date().timeIntervalSince1970 + 3600]).utf8))
        }
        return (CloudSession(deviceToken: jwt(["device-id": "me"]), session: session, authHost: auth, syncHost: url), exchanges)
    }
}

/// Polls `condition` until it holds or `limit` passes.
func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        if .now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@Suite struct NoticeSocketTests {
    func notice(from device: String) -> String {
        #"{"message":{"attributes":{"event":"SyncComplete","sourceDeviceID":"\#(device)"}}}"#
    }

    @Test func aSyncFromAnotherDeviceCountsAndOurOwnDoesNot() async throws {
        let server = try await NoticeServer()
        let (cloud, _) = server.cloud()
        let calls = Locked(0)
        let listener = Task { await cloud.listen { calls.update { $0 += 1 } } }
        defer { listener.cancel() }
        #expect(await eventually { server.connects.value.count == 1 })
        server.send(notice(from: "me"))
        server.send(notice(from: "tablet"))
        #expect(await eventually { calls.value == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 1)
    }

    @Test func aServerThatClosesRightAwayIsNotARefusedToken() async throws {
        let server = try await NoticeServer(closeAfter: 0)
        let (cloud, exchanges) = server.cloud()
        let listener = Task { await cloud.listen(backoff: .milliseconds(5)) {} }
        defer { listener.cancel() }
        #expect(await eventually { server.connects.value.count >= 5 })
        #expect(exchanges.value == 1)
    }

    @Test func aRoutineCloseReconnectsWithoutBackingOff() async throws {
        let server = try await NoticeServer(closeAfter: 150)
        let (cloud, exchanges) = server.cloud()
        let listener = Task { await cloud.listen(ping: .milliseconds(30), backoff: .milliseconds(100)) {} }
        defer { listener.cancel() }
        #expect(await eventually { server.connects.value.count >= 5 })
        // up 150 ms, then the base 100 ms backoff each time; a doubling one reaches 950 ms by the fourth gap
        let connects = server.connects.value
        let gaps = zip(connects, connects.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 < .milliseconds(600) }, "\(gaps)")
        #expect(exchanges.value == 1)
    }

    @Test func aRefusedHandshakeGetsAFreshToken() async throws {
        let server = try await NoticeServer(refuse: true)
        let (cloud, exchanges) = server.cloud()
        let listener = Task { await cloud.listen(backoff: .milliseconds(5)) {} }
        defer { listener.cancel() }
        #expect(await eventually { exchanges.value >= 2 })
    }

    @Test func anUnansweredPingDropsTheSocket() async throws {
        let server = try await NoticeServer(answerPings: false)
        let (cloud, _) = server.cloud()
        let listener = Task { await cloud.listen(ping: .milliseconds(30), backoff: .milliseconds(5)) {} }
        defer { listener.cancel() }
        #expect(await eventually { server.connects.value.count >= 2 })
    }

    @Test func reopensOnSchedule() async throws {
        let server = try await NoticeServer()
        let (cloud, _) = server.cloud()
        let listener = Task { await cloud.listen(ping: .milliseconds(20), reopen: .milliseconds(100), backoff: .milliseconds(5)) {} }
        defer { listener.cancel() }
        #expect(await eventually { server.connects.value.count >= 2 })
    }

    @Test func endingTheStreamClosesTheSocket() async throws {
        let server = try await NoticeServer()
        let (cloud, _) = server.cloud()
        let consumer = Task { for await _ in cloud.changes(poll: .seconds(3600)) {} }
        // a client cancelled mid-handshake sends no close frame for the server to see
        #expect(await eventually { server.ready.value == 1 })
        consumer.cancel()
        #expect(await eventually(within: .seconds(1)) { server.gone.value == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.connects.value.count == 1)
    }
}
