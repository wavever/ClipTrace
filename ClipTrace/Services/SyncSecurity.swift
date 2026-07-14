import CryptoKit
import Foundation
import Security

enum SyncKeychain {
    private static let service = "com.wavever.cliptrace.sync"

    enum Account: String {
        case encryptionKey = "encryption-key"
        case webDAVPassword = "webdav-password"
        case s3SecretAccessKey = "s3-secret-access-key"
        case s3SessionToken = "s3-session-token"
    }

    static func data(for account: Account) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    static func set(_ data: Data, for account: Account) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SyncSecurityError.keychain(updateStatus)
        }

        var insertion = identity
        attributes.forEach { insertion[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SyncSecurityError.keychain(addStatus)
        }
    }

    static func remove(_ account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncSecurityError.keychain(status)
        }
    }
}

enum SyncCipher {
    private static let magic = Data([0x43, 0x54, 0x45, 0x31]) // CTE1
    static let keyByteCount = 32

    static func generateKeyData() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SyncSecurityError.randomGeneration
        }
        return Data(bytes)
    }

    static func recoveryKey(from keyData: Data) throws -> String {
        guard keyData.count == keyByteCount else { throw SyncSecurityError.invalidRecoveryKey }
        return keyData.base64EncodedString()
    }

    static func keyData(fromRecoveryKey value: String) throws -> Data {
        let compact = value.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: compact), data.count == keyByteCount else {
            throw SyncSecurityError.invalidRecoveryKey
        }
        return data
    }

    static func seal(_ plaintext: Data, keyData: Data) throws -> Data {
        guard keyData.count == keyByteCount else { throw SyncSecurityError.invalidRecoveryKey }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else { throw SyncSecurityError.encryptionFailed }
        return magic + combined
    }

    static func open(_ ciphertext: Data, keyData: Data) throws -> Data {
        guard keyData.count == keyByteCount else { throw SyncSecurityError.invalidRecoveryKey }
        guard ciphertext.count > magic.count,
              ciphertext.prefix(magic.count) == magic else {
            throw SyncSecurityError.invalidEncryptedFile
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext.dropFirst(magic.count))
            return try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
        } catch {
            throw SyncSecurityError.decryptionFailed
        }
    }

    /// Remote attachment names are keyed, so a WebDAV administrator cannot
    /// infer whether two accounts contain the same clipboard image from a
    /// plain content hash. The actual hash remains inside the encrypted
    /// manifest and is verified after every download.
    static func remoteAttachmentName(contentHash: String, keyData: Data) throws -> String {
        guard keyData.count == keyByteCount else { throw SyncSecurityError.invalidRecoveryKey }
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(contentHash.utf8),
            using: SymmetricKey(data: keyData)
        )
        return authentication.map { String(format: "%02x", $0) }.joined() + ".bin"
    }
}

enum SyncSecurityError: LocalizedError {
    case keychain(OSStatus)
    case randomGeneration
    case invalidRecoveryKey
    case encryptionFailed
    case invalidEncryptedFile
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            return L("settings.sync.error.keychain", detail)
        case .randomGeneration:
            return L("settings.sync.error.random")
        case .invalidRecoveryKey:
            return L("settings.sync.error.invalidKey")
        case .encryptionFailed:
            return L("settings.sync.error.encrypt")
        case .invalidEncryptedFile:
            return L("settings.sync.error.invalidEncryptedFile")
        case .decryptionFailed:
            return L("settings.sync.error.decrypt")
        }
    }
}
