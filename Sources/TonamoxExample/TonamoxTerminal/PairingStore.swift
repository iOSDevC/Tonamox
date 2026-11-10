import Foundation
import os
import Security
import TerminalBridgeKit

/// The pairing secret and phone ID, pinned to this app's own keychain access group (never the shared App
/// Group) and not the SDK's `KeychainStore` service, so the other Tonamox apps cannot read or plant them.
struct PairingStore {
    struct Credentials {
        let code: PairingCode
        let phoneID: UUID
        /// Set when the keychain refused a write; the values then live only until the app quits.
        let problem: String?
    }

    static let service = "io.iosdevc.TonamoxTerminal.bridge-pairing"
    private static let secretAccount = "pairing-secret"
    private static let phoneAccount = "phone-id"
    static let log = Logger(subsystem: "io.iosdevc.TonamoxTerminal", category: "pairing")
    static let unpinnedProblem = "No se pudo fijar el grupo propio del llavero; el código vale hasta que cierres la app."

    /// The app's default access group, read back from a fresh probe item. Without an explicit group,
    /// CopyMatching and Update would also match items in the App Group that sibling apps can write.
    static let ownAccessGroup: String? = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".group-probe",
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        var added: [String: Any] = probe
        added[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemAdd(added as CFDictionary, &result)
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String, !group.isEmpty
        else {
            log.error("Keychain access-group probe failed: \(status, privacy: .public)")
            return nil
        }
        var cleanup = probe
        cleanup[kSecAttrAccessGroup as String] = group
        SecItemDelete(cleanup as CFDictionary)
        return group
    }()

    func loadOrCreate() -> Credentials {
        var problems: [String] = []
        if Self.ownAccessGroup == nil { problems.append(Self.unpinnedProblem) }
        let phoneID = readPhoneID() ?? newPhoneID(problems: &problems)
        let code: PairingCode
        if let data = read(account: Self.secretAccount), let stored = try? PairingCode(secret: data) {
            code = stored
        } else {
            code = PairingCode.generate()
            if let problem = save(code) { problems.append(problem) }
        }
        return Credentials(code: code, phoneID: phoneID, problem: problems.first)
    }

    /// Stores `code` as the current secret; returns a message when the keychain refused it.
    func save(_ code: PairingCode) -> String? {
        guard Self.ownAccessGroup != nil else { return Self.unpinnedProblem }
        let status = write(code.secret, account: Self.secretAccount)
        guard status != errSecSuccess else { return nil }
        Self.log.error("Keychain write of the pairing secret failed: \(status, privacy: .public)")
        return "No se pudo guardar el código en el llavero (OSStatus \(status)). Vale hasta que cierres la app."
    }

    #if DEBUG && targetEnvironment(simulator)
    static let debugCodeVariable = "TONAMOX_DEBUG_PAIRING_CODE"

    /// Simulator-only pairing without the clipboard: `SIMCTL_CHILD_TONAMOX_DEBUG_PAIRING_CODE=<code>`.
    static func debugLaunchCode(environment: [String: String] = ProcessInfo.processInfo.environment) -> PairingCode? {
        guard let raw = environment[debugCodeVariable], !raw.isEmpty else { return nil }
        do {
            let code = try PairingCode(parsing: raw)
            log.notice("Adopting the launch pairing code, fingerprint \(code.fingerprint, privacy: .public)")
            return code
        } catch {
            let reason = String(describing: error)
            log.error("\(debugCodeVariable, privacy: .public) is not a valid pairing code: \(reason, privacy: .public)")
            return nil
        }
    }
    #endif

    // MARK: Keychain

    private func readPhoneID() -> UUID? {
        guard let data = read(account: Self.phoneAccount), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return UUID(uuidString: text)
    }

    private func newPhoneID(problems: inout [String]) -> UUID {
        let phoneID = UUID()
        let status = write(Data(phoneID.uuidString.utf8), account: Self.phoneAccount)
        if status != errSecSuccess {
            Self.log.error("Keychain write of the phone ID failed: \(status, privacy: .public)")
            problems.append("No se pudo guardar el identificador del teléfono en el llavero (OSStatus \(status)).")
        }
        return phoneID
    }

    /// Nil when the app's own group is unknown: then nothing is read or written (fail closed).
    private func baseQuery(account: String) -> [String: Any]? {
        guard let group = Self.ownAccessGroup else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private func read(account: String) -> Data? {
        guard var query = baseQuery(account: account) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(_ data: Data, account: String) -> OSStatus {
        guard let query = baseQuery(account: account) else { return errSecMissingEntitlement }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        let item = query.merging(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil)
    }
}
