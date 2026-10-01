import Foundation
import Security

/// Jeton HuggingFace, stocke dans le Trousseau (et plus en clair dans les preferences).
enum HuggingFaceToken {
    /// Modifiables par les tests, pour ne jamais toucher le vrai jeton
    static var service = "com.pierre.Voxa"
    static var defaults = UserDefaults.standard
    private static let account = "hf_token"
    /// Ancienne cle UserDefaults (versions <= 1.3.1)
    private static let legacyDefaultsKey = "hf_token"

    static var value: String {
        get { read() ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete() } else { write(trimmed) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var isSet: Bool { !value.isEmpty }

    static let didChange = Notification.Name("HuggingFaceTokenDidChange")

    /// Deplace le jeton des preferences vers le Trousseau (une seule fois).
    static func migrateFromUserDefaults() {
        guard let legacy = defaults.string(forKey: legacyDefaultsKey) else { return }
        if !legacy.isEmpty && read() == nil {
            write(legacy)
        }
        // Ne supprimer l'ancienne valeur qu'une fois le Trousseau a jour
        if legacy.isEmpty || read() != nil {
            defaults.removeObject(forKey: legacyDefaultsKey)
            print("[HuggingFaceToken] Jeton migre vers le Trousseau")
        }
    }

    // MARK: - Keychain

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ token: String) {
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[HuggingFaceToken] ERREUR SecItemAdd: \(addStatus)")
            }
        } else if status != errSecSuccess {
            print("[HuggingFaceToken] ERREUR SecItemUpdate: \(status)")
        }
    }

    private static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
