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
    static let service = "io.artnim.timetracker"
    static let tokenAccount = "github-token"          // legacy single token (migrated on first read)
    static let accountsAccount = "github-accounts"    // JSON array of GitHubAccount

    struct KeychainError: Error { let status: OSStatus }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) throws {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
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
