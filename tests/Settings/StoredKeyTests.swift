import NarrariKit
import Synchronization
import Testing

@MainActor
struct StoredKeyTests {
    @Test func a_good_read_clears_an_earlier_keychain_error() {
        let keychain = FlakyKeychain()
        let key = StoredKey(account: "cleanup.chat", keychain: keychain)
        key.refresh()
        #expect(key.error != nil)

        keychain.isLocked.withLock { $0 = false }
        key.refresh()

        #expect(key.error == nil)
        #expect(key.isSet)
    }
}

private final class FlakyKeychain: KeyStoring {
    let isLocked = Mutex(true)

    func read(_ account: String) throws -> String? { nil }

    func contains(_ account: String) throws -> Bool {
        if isLocked.withLock({ $0 }) { throw KeychainError.unexpectedStatus(-25308) }
        return true
    }

    func write(_ value: String, for account: String) throws {}
    func delete(_ account: String) throws {}
}
