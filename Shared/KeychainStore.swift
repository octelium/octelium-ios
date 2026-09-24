import Foundation
import OcteliumCore
import Security

struct KeychainStore: SecretStore {
    let service: String
    let accessGroup: String

    func get(_ account: String) throws -> Data? {
        var query = getQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var ret: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ret)

        switch status {
        case errSecSuccess:
            return ret as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw getError(status)
        }
    }

    func set(_ account: String, _ data: Data) throws {
        let query = getQuery(account)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }

        if status != errSecSuccess {
            throw getError(status)
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(getQuery(account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw getError(status)
        }
    }

    private func getQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func getError(_ status: OSStatus) -> SecretStoreError {
        if status == errSecInteractionNotAllowed {
            return .locked
        }

        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return .failure("\(msg) (\(status))")
    }
}
