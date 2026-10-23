import Foundation
import Security

enum KeychainStore {
    private static let service = "com.solv.app"
    private static let account = "openai_api_key"

    /// 붙여넣기 실수(공백, Bearer, 따옴표) 제거
    static func normalizeAPIKey(_ raw: String) -> String {
        var k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("Bearer ") || k.hasPrefix("bearer ") {
            k = String(k.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (k.hasPrefix("\"") && k.hasSuffix("\"")) || (k.hasPrefix("'") && k.hasSuffix("'")) {
            k = String(k.dropFirst().dropLast())
        }
        // 줄바꿈·제로폭 공백 제거
        k = k
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return k
    }

    static func saveAPIKey(_ key: String) {
        let normalized = normalizeAPIKey(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        guard !normalized.isEmpty else { return }

        var add = query
        add[kSecValueData as String] = Data(normalized.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let k = normalizeAPIKey(raw)
        return k.isEmpty ? nil : k
    }

    /// 상태줄용: sk-or-v1-abcd…wxyz
    static func maskedPreview(_ key: String) -> String {
        let k = normalizeAPIKey(key)
        guard k.count > 12 else { return "(짧음)" }
        return "\(k.prefix(10))…\(k.suffix(4))"
    }
}
