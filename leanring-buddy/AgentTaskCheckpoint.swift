//
//  AgentTaskCheckpoint.swift
//  leanring-buddy
//
//  A task's state on disk, rewritten at every phase change (2026-10-10), so a
//  quit mid-task is a task the voice can offer to continue rather than one
//  forgotten. By agent-loop.log's rules: no page text, typed text as lengths in
//  the receipts, no element names, opened tabs by host. But the goal and the
//  owner's words are kept as spoken, so text the owner asked to be typed IS in
//  the file. The model's history and screenshots are never written; a resumed
//  task looks again. Every file is signed (`AgentTaskStore.liveKey`).
//

import CryptoKit
import Foundation
import Security

struct AgentTaskCheckpoint: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        let step: Int
        let words: String
        let ok: Bool
        let error: String?
    }
    /// An app the task launched (host nil), or a page it opened in a browser.
    struct Opened: Codable, Equatable, Sendable {
        let bundle: String
        let host: String?
    }
    var taskId: String
    /// Both scrubbed by SecretScanner.
    var goal: String
    var ownerWords: String
    var state: AgentTaskPhase
    var step: Int
    var receipts: [Step]
    var opened: [Opened]
    /// Things the app showed the task made (`AgentLoop.artifacts`), scrubbed.
    var artifacts: [String]
    var transitions: [AgentTaskTransition]
    var createdAt: Date
    var updatedAt: Date
}

enum AgentTaskStore {
    nonisolated static let keep = 20

    nonisolated static var liveDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clicky/tasks", isDirectory: true)
    }

    /// The key every checkpoint file is signed with (security review 2026-10-10:
    /// any process running as the owner could plant `tasks/x.json` and have a yes
    /// run its goal). It lives in the data-protection keychain beside the Always
    /// rules, where another process can neither read nor plant it. nil when the
    /// keychain does not answer: then nothing is written and nothing read is trusted.
    nonisolated static let liveKey: SymmetricKey? = AgentTaskKeychain.loadOrCreate()

    /// A task id names a file: `AgentLoop.runID` (a UUID's first 8 hex digits) or a whole UUID, nothing else.
    nonisolated static func isValidTaskId(_ id: String) -> Bool {
        UUID(uuidString: id) != nil || (id.utf8.count == 8 && id.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) })
    }

    private nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// A file is its MAC (HMAC-SHA256, base64), a newline, then the JSON it signs.
    nonisolated static func signed(_ json: Data, key: SymmetricKey) -> Data {
        Data(Data(HMAC<SHA256>.authenticationCode(for: json, using: key)).base64EncodedString().utf8) + Data([0x0A]) + json
    }

    /// The checkpoint a file holds, or why it is not trusted.
    nonisolated static func verified(_ file: Data, name: String, key: SymmetricKey?) -> Result<AgentTaskCheckpoint, CheckpointRejection> {
        guard let key else { return .failure(.init(reason: "noKey")) }
        guard let newline = file.firstIndex(of: 0x0A),
              let mac = Data(base64Encoded: file[file.startIndex..<newline]) else { return .failure(.init(reason: "unsigned")) }
        let json = file[file.index(after: newline)...]
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: json, using: key) else { return .failure(.init(reason: "badSignature")) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(AgentTaskCheckpoint.self, from: Data(json)) else { return .failure(.init(reason: "undecodable")) }
        guard isValidTaskId(checkpoint.taskId), name == "\(checkpoint.taskId).json" else { return .failure(.init(reason: "badTaskId")) }
        return .success(checkpoint)
    }

    struct CheckpointRejection: Error, Equatable { let reason: String }

    /// A file that failed verification: ignored, never offered, and recorded in agent-loop.log.
    nonisolated static func reportRejected(_ name: String, _ reason: String) {
        AgentLoop.appendTrace(["kind": "checkpointRejected", "file": UntrustedText(name).forDisplay, "reason": reason,
                               "at": ISO8601DateFormatter().string(from: Date())])
    }

    /// `<taskId>.json`, 0600 from creation (written beside, then renamed over), and only the newest `keep` kept.
    nonisolated static func write(_ checkpoint: AgentTaskCheckpoint, in directory: URL = liveDirectory, key: SymmetricKey? = liveKey) {
        guard isValidTaskId(checkpoint.taskId), let key else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let json = try? encoder().encode(checkpoint) else { return }
        let url = directory.appendingPathComponent("\(checkpoint.taskId).json")
        let temporary = directory.appendingPathComponent(".\(checkpoint.taskId).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: signed(json, key: key), attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { try? fileManager.removeItem(at: temporary) }
        prune(directory)
    }

    nonisolated static func prune(_ directory: URL) {
        let files = taskFiles(directory)
        guard files.count > keep else { return }
        for old in files.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    /// Newest first, by modification time.
    nonisolated static func taskFiles(_ directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return urls.filter { $0.pathExtension == "json" }.sorted { modified($0) > modified($1) }
    }

    /// Only files this app signed; every other is reported (`reportRejected`) and skipped.
    nonisolated static func read(in directory: URL = liveDirectory, key: SymmetricKey? = liveKey,
                                 report: (String, String) -> Void = reportRejected) -> [AgentTaskCheckpoint] {
        taskFiles(directory).compactMap { url in
            switch verified((try? Data(contentsOf: url)) ?? Data(), name: url.lastPathComponent, key: key) {
            case .success(let checkpoint): return checkpoint
            case .failure(let rejection): report(url.lastPathComponent, rejection.reason); return nil
            }
        }
    }

    /// At launch: every task the last process left mid-task becomes `interrupted`. Newest first.
    nonisolated static func markInterrupted(in directory: URL = liveDirectory, now: Date = Date(), key: SymmetricKey? = liveKey) -> [AgentTaskCheckpoint] {
        read(in: directory, key: key).filter(\.state.isMidTask).map { found in
            var checkpoint = found
            checkpoint.state = .interrupted
            checkpoint.transitions.append(AgentTaskTransition(phase: .interrupted, at: now))
            checkpoint.updatedAt = now
            write(checkpoint, in: directory, key: key)
            return checkpoint
        }
    }

    /// Once per process: the first voice session marks what the last one left.
    nonisolated(unsafe) static let interruptedAtLaunch: [AgentTaskCheckpoint] = markInterrupted()
}

/// The checkpoint signing key in the data-protection keychain: the same query
/// shape, so the same access group, as `ApprovalRulesKeychainStore`.
enum AgentTaskKeychain {
    nonisolated static let service = "com.dhruvpatel.jarvis.checkpoint-key"

    nonisolated static func loadOrCreate(service: String = service) -> SymmetricKey? {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "hmac", kSecUseDataProtectionKeychain as String: true]
        func load() -> (OSStatus, SymmetricKey?) {
            var query = item
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { return (status, nil) }
            return (status, SymmetricKey(data: data))
        }
        let (status, key) = load()
        if let key { return key }
        // A read that failed is not "no key": a new key would orphan every file the real one signed.
        guard status == errSecItemNotFound else { return nil }
        let fresh = SymmetricKey(size: .bits256)
        var add = item
        add[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess: return fresh
        case errSecDuplicateItem: return load().1
        default: return nil
        }
    }

    /// Test cleanup.
    nonisolated static func delete(service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecUseDataProtectionKeychain as String: true] as CFDictionary)
    }
}
