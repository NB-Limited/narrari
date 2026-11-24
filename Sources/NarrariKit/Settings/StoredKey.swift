import Foundation
import Observation

// A service key as a settings field shows it: set or not set, replaced or removed, never read back.
@MainActor
@Observable
public final class StoredKey {
    public private(set) var isSet = false
    public private(set) var isReplacing = false
    public private(set) var error: String?
    public var draft = ""

    @ObservationIgnored private let account: String
    @ObservationIgnored private let keychain: any KeyStoring

    // Read on refresh, which the page calls when it appears, so making one never touches the Keychain.
    public init(account: String, keychain: any KeyStoring) {
        self.account = account
        self.keychain = keychain
    }

    public func refresh() {
        do {
            isSet = try keychain.contains(account)
            error = nil
        } catch {
            Log.failure("key-check", error: error)
            self.error = "The Keychain could not be read, so it is unknown whether a key is set. Try again."
        }
    }

    public func beginReplacing() {
        draft = ""
        error = nil
        isReplacing = true
    }

    public func cancel() {
        draft = ""
        error = nil
        isReplacing = false
    }

    public func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            error = "Paste the key, or press Cancel to keep the one you have."
            return
        }
        do {
            try keychain.write(key, for: account)
            Log.event("key-saved")
            cancel()
            refresh()
        } catch {
            Log.failure("key-save", error: error)
            self.error = "The key could not be saved in the Keychain. Try again."
        }
    }

    public func remove() {
        do {
            try keychain.delete(account)
            Log.event("key-removed")
            error = nil
            refresh()
        } catch {
            Log.failure("key-remove", error: error)
            self.error = "The key could not be removed from the Keychain. Try again."
        }
    }
}
