//
//  ApprovalRulesKeychainStore.swift
//  leanring-buddy
//
//  Where "Always allow exactly this" rules live. Until 2026-09-14 they were
//  `harness-approvals.json`, and any process running as the owner could append
//  a rule to it and skip the card — the hardware-click check guarded the
//  button, not the file.
//
//  The data-protection keychain (`kSecUseDataProtectionKeychain`) scopes an
//  item by keychain access group, which is derived from the code signature:
//  another process cannot read or write Clicky's item, and cannot shadow it by
//  adding its own item under the same service either — its item lands in ITS
//  access group, which this store never queries. A legacy file-based keychain
//  item has an ACL instead, and another app can simply create its own item.
//

import Foundation
import Security

struct ApprovalRulesKeychainStore {
    static let productionServiceName = "com.dhruvpatel.jarvis.approval-rules"
    static let accountName = "rules"

    /// Tests pass a unique service so they never touch the real rules.
    let serviceName: String

    init(serviceName: String = ApprovalRulesKeychainStore.productionServiceName) {
        self.serviceName = serviceName
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: Self.accountName,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// No item = no rules. A failed read or undecodable bytes are a reason,
    /// never an empty list — "could not read" must not look like "none approved".
    func load() -> Result<[HarnessConfirmations.ApprovalRule], HarnessAppPolicy.ParseFailure> {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success([]) }
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(.init(reason: "keychain \(serviceName): read failed, OSStatus \(status)"))
        }
        return HarnessConfirmations.parseApprovals(data).mapError {
            .init(reason: "keychain \(serviceName): \($0.reason)")
        }
    }

    func save(_ rules: [HarnessConfirmations.ApprovalRule]) -> OSStatus {
        guard let data = try? JSONEncoder().encode(rules) else { return errSecParam }
        return write(data)
    }

    /// Raw bytes, so a test can plant undecodable data. Update first, add when
    /// there is nothing to update.
    func write(_ data: Data) -> OSStatus {
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var addQuery = itemQuery
        addQuery[kSecValueData as String] = data
        // Readable only while the Mac is unlocked, never migrated to another device.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Rules we could not read are not rules we overwrite: removing one from an
    /// unreadable item would replace everything else in it with nothing.
    func remove(_ rule: HarnessConfirmations.ApprovalRule) -> OSStatus {
        guard case .success(let rules) = load() else { return errSecDecode }
        return save(rules.filter { $0 != rule })
    }

    /// Test cleanup.
    func deleteItem() -> OSStatus {
        SecItemDelete(itemQuery as CFDictionary)
    }
}
