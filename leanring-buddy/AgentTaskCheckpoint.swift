//
//  AgentTaskCheckpoint.swift
//  leanring-buddy
//
//  A task's state on disk, rewritten at every phase change (2026-10-10), so a
//  quit mid-task is a task the voice can offer to continue rather than one
//  forgotten. Plain words only, by agent-loop.log's rules: no page text, no
//  typed text (lengths), no element names, opened tabs by host. The model's
//  history and screenshots are never written; a resumed task looks again.
//

import Foundation

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

    private nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// `<taskId>.json`, 0600 from creation (written beside, then renamed over), and only the newest `keep` kept.
    nonisolated static func write(_ checkpoint: AgentTaskCheckpoint, in directory: URL = liveDirectory) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? encoder().encode(checkpoint) else { return }
        let url = directory.appendingPathComponent("\(checkpoint.taskId).json")
        let temporary = directory.appendingPathComponent(".\(checkpoint.taskId).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
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

    nonisolated static func read(in directory: URL = liveDirectory) -> [AgentTaskCheckpoint] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return taskFiles(directory).compactMap { try? decoder.decode(AgentTaskCheckpoint.self, from: Data(contentsOf: $0)) }
    }

    /// At launch: every task the last process left mid-task becomes `interrupted`. Newest first.
    nonisolated static func markInterrupted(in directory: URL = liveDirectory, now: Date = Date()) -> [AgentTaskCheckpoint] {
        read(in: directory).filter(\.state.isMidTask).map { found in
            var checkpoint = found
            checkpoint.state = .interrupted
            checkpoint.transitions.append(AgentTaskTransition(phase: .interrupted, at: now))
            checkpoint.updatedAt = now
            write(checkpoint, in: directory)
            return checkpoint
        }
    }

    /// Once per process: the first voice session marks what the last one left.
    nonisolated(unsafe) static let interruptedAtLaunch: [AgentTaskCheckpoint] = markInterrupted()
}
