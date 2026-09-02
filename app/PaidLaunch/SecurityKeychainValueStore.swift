import Foundation
import Security

public enum SecurityKeychainValueStoreError: Error {
  case unexpectedStatus(OSStatus)
}

/// Stores session and entitlement material in the user's login Keychain.
/// Values are scoped by service and the typed key supplied by the coordinator.
public final class SecurityKeychainValueStore: KeychainValueStore {
  private let service: String
  private let accessGroup: String?

  public init(service: String = "com.ddump.app.paid-launch", accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  public func data(forKey key: String) throws -> Data? {
    var query = baseQuery(forKey: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw SecurityKeychainValueStoreError.unexpectedStatus(status)
    }
    return result as? Data
  }

  public func setData(_ data: Data, forKey key: String) throws {
    let query = baseQuery(forKey: key)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw SecurityKeychainValueStoreError.unexpectedStatus(updateStatus)
    }

    var insert = query
    attributes.forEach { insert[$0.key] = $0.value }
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else {
      throw SecurityKeychainValueStoreError.unexpectedStatus(insertStatus)
    }
  }

  public func deleteData(forKey key: String) throws {
    let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecurityKeychainValueStoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery(forKey key: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }
}
