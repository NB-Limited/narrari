import Foundation
import Security

public enum KeychainError: ProblemError, Equatable {
    case unexpectedStatus(OSStatus)
    case unreadable

    public var problem: Problem {
        switch self {
        case .unexpectedStatus: Problem("keychain.failed", "The Keychain refused the key. Enter it again.", canRetry: true)
        case .unreadable: Problem("keychain.unreadable", "The key in the Keychain can't be read. Enter it again.")
        }
    }

    public var status: Int? {
        if case .unexpectedStatus(let status) = self { return Int(status) }
        return nil
    }
}

// What Narrari needs from the Keychain, so a test can stand in for it.
public protocol KeyStoring: Sendable {
    func read(_ account: String) throws -> String?
    func contains(_ account: String) throws -> Bool
    func write(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}

public struct Keychain: KeyStoring {
    public static let narrari = Keychain(service: "com.nb-limited.narrari")

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unreadable
        }
        return value
    }

    // Asks only whether an item exists, so the secret itself is never read into memory.
    public func contains(_ account: String) throws -> Bool {
        let status = SecItemCopyMatching(baseQuery(account) as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return true
    }

    public func write(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
            SettingsChanges.post(account)
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        SettingsChanges.post(account)
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        SettingsChanges.post(account)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
