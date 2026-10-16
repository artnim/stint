import Foundation
import Security

/// One GitHub token. Fine-grained tokens belong to a single resource owner (your user
/// account or one organisation), so the app keeps one per owner, labelled by you.
struct GitHubAccount: Codable, Identifiable, Equatable {
    var label: String
    var token: String
    var id: String { label }
}

enum KeychainStore {
    static let service = "io.artnim.stint"
    static let tokenAccount = "github-token"          // legacy single token (migrated on first read)
    static let accountsAccount = "github-accounts"    // JSON array of GitHubAccount
    /// Shared by the Mac and iPhone apps (`keychain-access-groups` in both entitlements), so the synced item is
    /// visible to both; without it each app would use its own application identifier as the group.
    static let accessGroup = "76C3CLR3D5.io.artnim.stint"

    struct KeychainError: Error { let status: OSStatus }

    private static func query(_ account: String, service: String = service, synchronizable: Bool = false) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if synchronizable {
            q[kSecAttrSynchronizable as String] = true
            q[kSecAttrAccessGroup as String] = accessGroup
            #if os(macOS)
            q[kSecUseDataProtectionKeychain as String] = true   // synchronizable items live in the data-protection keychain
            #endif
        }
        return q
    }

    static func read(_ account: String) -> String? {
        if let value = read(account, service: service, synchronizable: true) { return value }
        // first launch after enabling sync: adopt the local item.
        // Delete the legacy item only once the synchronizable write succeeded (unsigned builds
        // get errSecMissingEntitlement and must not lose the token).
        guard let legacy = read(account, service: service, synchronizable: false) else { return nil }
        if (try? write(account, legacy)) != nil {
            SecItemDelete(query(account, service: service, synchronizable: false) as CFDictionary)
        }
        return legacy
    }

    private static func read(_ account: String, service: String, synchronizable: Bool) -> String? {
        var q = query(account, service: service, synchronizable: synchronizable)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) throws {
        delete(account)
        var q = query(account, synchronizable: true)
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account, synchronizable: true) as CFDictionary)
    }

    // MARK: GitHub accounts

    /// All configured accounts. A token saved by an older version is migrated into the list as "default".
    static func githubAccounts() -> [GitHubAccount] {
        if let json = read(accountsAccount), let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([GitHubAccount].self, from: data) {
            return list
        }
        if let legacy = read(tokenAccount), !legacy.isEmpty {
            let migrated = [GitHubAccount(label: "default", token: legacy)]
            if (try? saveGitHubAccounts(migrated)) != nil { delete(tokenAccount) }
            return migrated
        }
        return []
    }

    static func saveGitHubAccounts(_ accounts: [GitHubAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        try write(accountsAccount, String(decoding: data, as: UTF8.self))
    }
}
