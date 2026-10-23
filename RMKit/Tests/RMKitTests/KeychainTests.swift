#if canImport(Security)
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
        #expect(try keychain.label(account: "a") == nil)
        try keychain.set("two", account: "a", label: "me@example.com")
        #expect(try keychain.label(account: "a") == "me@example.com")
        #expect(try keychain.get(account: "a") == "two")
        try keychain.delete(account: "a")
        #expect(try keychain.accounts() == [])
    }
}
#endif
