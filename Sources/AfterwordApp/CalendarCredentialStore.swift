import Foundation
import Security

protocol CalendarCredentialStoring: Sendable {
    func load(allowInteraction: Bool) throws -> Data?
    func save(_ data: Data, allowInteraction: Bool) throws
}

enum CalendarCredentialStoreError: LocalizedError {
    case locked
    case unavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .locked: "Unlock the login Keychain, then try connecting Google Calendar again."
        case .unavailable(let status): "Google Calendar credentials could not be accessed in Keychain (\(status))."
        }
    }
}

struct KeychainCalendarCredentialStore: CalendarCredentialStoring {
    private static let interactionLock = NSLock()
    private let service = "local.afterword.google-calendar"
    private let account = "desktop-oauth"

    private var query: [String: Any] {
        // Ad-hoc builds do not have a provisioning-backed data-protection access group.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load(allowInteraction: Bool) throws -> Data? {
        try withInteraction(allowed: allowInteraction) {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = value as? Data, data.count <= 65_536 else {
                throw CalendarCredentialStoreError.unavailable(errSecDecode)
            }
            return data
        }
    }

    func save(_ data: Data, allowInteraction: Bool) throws {
        guard data.count <= 65_536 else { throw CalendarCredentialStoreError.unavailable(errSecParam) }
        try withInteraction(allowed: allowInteraction) {
            let attributes = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = "Afterword Google Calendar"
                let added = SecItemAdd(item as CFDictionary, nil)
                if added == errSecDuplicateItem {
                    try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
                } else { try check(added) }
            } else { try check(status) }
        }
    }

    private func withInteraction<T>(allowed: Bool, _ operation: () throws -> T) throws -> T {
        try Self.interactionLock.withLock {
            // Legacy/file Keychain UI suppression uses a process-wide switch.
            var previous = DarwinBoolean(false)
            try check(SecKeychainGetUserInteractionAllowed(&previous))
            try check(SecKeychainSetUserInteractionAllowed(allowed && previous.boolValue))
            defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            return try operation()
        }
    }

    private func check(_ status: OSStatus) throws {
        if status == errSecSuccess { return }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw CalendarCredentialStoreError.locked
        }
        throw CalendarCredentialStoreError.unavailable(status)
    }
}
