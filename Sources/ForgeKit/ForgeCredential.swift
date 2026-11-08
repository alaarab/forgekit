import Foundation
#if canImport(Security)
import Security
#endif

/// A saved non-GitHub forge account. GitHub tokens stay in the app's own
/// `KeychainStore`; this is the same credential shape for every other host.
public struct ForgeCredential: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case deviceFlow
        case pastedToken
    }

    public let host: ForgeHost
    public let token: String
    public let user: ForgeUser?
    public let scopes: [String]
    public let expiresAt: Date?
    public let source: Source

    public init(host: ForgeHost, token: String, user: ForgeUser?, scopes: [String],
                expiresAt: Date?, source: Source) {
        self.host = host
        self.token = token
        self.user = user
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.source = source
    }
}

/// Storage behind ``ForgeCredentialStore``. The static API is kept for source
/// compatibility; callers that want to inject storage can talk to this
/// protocol and use ``ForgeKeychainCredentialStore`` as the default.
public protocol ForgeCredentialStoring: Sendable {
    func save(_ credential: ForgeCredential) throws
    func read(_ host: ForgeHost) -> ForgeCredentialStore.ReadResult
    func delete(_ host: ForgeHost) throws
    func storedHosts() -> [ForgeHost]
}

/// Keychain storage for non-GitHub forge accounts: generic password, service
/// "com.phren.ios.forge", account = host.id,
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. Non-Security fallback =
/// in-memory dictionary (Linux tests), same pattern as the app's KeychainStore.
public struct ForgeKeychainCredentialStore: ForgeCredentialStoring {
    public static let `default` = ForgeKeychainCredentialStore()

    static let service = "com.phren.ios.forge"

    public init() {}

#if canImport(Security)
    public func save(_ credential: ForgeCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: credential.host.id,
        ]
        // An interrupted sign-in must not erase a working credential.
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ForgeError.validation("Keychain save failed (\(status)).")
        }
    }

    public func read(_ host: ForgeHost) -> ForgeCredentialStore.ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host.id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Before the first unlock after a restart the Keychain refuses reads
        // (errSecInteractionNotAllowed) although the credential is still there.
        if status == errSecInteractionNotAllowed { return .locked }
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(ForgeCredential.self, from: data) else {
            return .invalidData
        }
        return .found(credential)
    }

    public func delete(_ host: ForgeHost) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host.id,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ForgeError.validation("Keychain delete failed (\(status)).")
        }
    }

    /// Attributes only — never `kSecReturnData` — so listing accounts cannot
    /// read a token, and cannot be blocked by data protection.
    public func storedHosts() -> [ForgeHost] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let single = result as? [String: Any] {
            items = [single]
        } else {
            return []
        }
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .compactMap(Self.host(fromID:))
            .sorted { $0.id < $1.id }
    }
#else
    // Linux CI fallback: in-memory only. Never used by the iOS app.
    private final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: ForgeCredential] = [:]

        func get(_ id: String) -> ForgeCredential? {
            lock.lock(); defer { lock.unlock() }
            return values[id]
        }

        func set(_ credential: ForgeCredential) {
            lock.lock(); defer { lock.unlock() }
            values[credential.host.id] = credential
        }

        func remove(_ id: String) {
            lock.lock(); defer { lock.unlock() }
            values.removeValue(forKey: id)
        }

        func ids() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(values.keys)
        }
    }
    private static let memory = MemoryBox()

    public func save(_ credential: ForgeCredential) throws {
        Self.memory.set(credential)
    }

    public func read(_ host: ForgeHost) -> ForgeCredentialStore.ReadResult {
        Self.memory.get(host.id).map(ForgeCredentialStore.ReadResult.found) ?? .missing
    }

    public func delete(_ host: ForgeHost) throws {
        Self.memory.remove(host.id)
    }

    public func storedHosts() -> [ForgeHost] {
        Self.memory.ids().compactMap(Self.host(fromID:)).sorted { $0.id < $1.id }
    }
#endif

    /// "gitboy:git.example.com" back into its parts. Ids written by this store
    /// always parse; anything else is skipped rather than guessed at.
    static func host(fromID id: String) -> ForgeHost? {
        guard let separator = id.firstIndex(of: ":") else { return nil }
        let kind = String(id[id.startIndex..<separator])
        let domain = String(id[id.index(after: separator)...])
        guard let forgeKind = ForgeKind(rawValue: kind), !domain.isEmpty else { return nil }
        return ForgeHost(kind: forgeKind, domain: domain)
    }
}

/// Keychain storage for non-GitHub forge accounts (GitHub keeps the app's
/// `KeychainStore`). The service and account names match the ones the app
/// wrote, so credentials saved before this extraction still load; the static
/// methods are the API the app already calls.
public enum ForgeCredentialStore {
    static let service = ForgeKeychainCredentialStore.service

    public enum ReadResult: Equatable, Sendable {
        case found(ForgeCredential)
        case missing
        case locked
        /// A Keychain failure is not evidence that the credential was removed.
        case unavailable(Int32)
        /// An item exists, but its stored document cannot be decoded.
        case invalidData
    }

    private static let storage: any ForgeCredentialStoring = ForgeKeychainCredentialStore.default

    public static func save(_ credential: ForgeCredential) throws {
        try storage.save(credential)
    }

    public static func read(_ host: ForgeHost) -> ReadResult {
        storage.read(host)
    }

    public static func delete(_ host: ForgeHost) throws {
        try storage.delete(host)
    }

    public static func storedHosts() -> [ForgeHost] {
        storage.storedHosts()
    }
}
