import Foundation
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
