import Flutter
import Security

final class SecureStorageBridge {
  private static let channelName = "dev.eixam.connect.flutter/secure_storage"
  private static let service = "dev.eixam.connect.flutter.secure-storage"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      do {
        let arguments = call.arguments as? [String: Any]
        switch call.method {
        case "read":
          result(try read(key: requiredString(arguments, key: "key")))
        case "write":
          try write(
            key: requiredString(arguments, key: "key"),
            value: requiredString(arguments, key: "value")
          )
          result(nil)
        case "delete":
          try delete(key: requiredString(arguments, key: "key"))
          result(nil)
        case "deleteAll":
          try deleteAll(namespace: arguments?["namespace"] as? String)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(
          code: "secure_storage_unavailable",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }

  private static func read(key: String) throws -> String? {
    var query = baseQuery(key: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw keychainError(status)
    }
    guard let value = String(data: data, encoding: .utf8) else {
      throw NSError(domain: channelName, code: -1, userInfo: [
        NSLocalizedDescriptionKey: "Secure storage value is not valid UTF-8"
      ])
    }
    return value
  }

  private static func write(key: String, value: String) throws {
    let data = Data(value.utf8)
    let query = baseQuery(key: key)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }
    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else { throw keychainError(insertStatus) }
  }

  private static func delete(key: String) throws {
    let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw keychainError(status)
    }
  }

  private static func deleteAll(namespace: String?) throws {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    if namespace == nil {
      query.removeValue(forKey: kSecReturnAttributes as String)
      query.removeValue(forKey: kSecMatchLimit as String)
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw keychainError(status)
      }
      return
    }
    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess else { throw keychainError(status) }
    let generatedPrefix = "eixam.\(namespace!)."
    let rawPrefix = "\(namespace!)."
    for item in (items as? [[String: Any]]) ?? [] {
      guard let account = item[kSecAttrAccount as String] as? String,
            account.hasPrefix(generatedPrefix) || account.hasPrefix(rawPrefix) else { continue }
      try delete(key: account)
    }
  }

  private static func baseQuery(key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }

  private static func requiredString(_ arguments: [String: Any]?, key: String) throws -> String {
    guard let value = arguments?[key] as? String, !value.isEmpty else {
      throw NSError(domain: channelName, code: -2, userInfo: [
        NSLocalizedDescriptionKey: "\(key) is required"
      ])
    }
    return value
  }

  private static func keychainError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
      NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ??
        "Keychain operation failed"
    ])
  }
}
