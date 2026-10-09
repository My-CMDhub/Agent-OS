//
//  AgentTaskCheckpointTests.swift
//  leanring-buddyTests
//
//  A checkpoint per step (2026-10-10): written at every phase change, plain
//  words only, 0600, the newest 20 kept; a task found mid-task at launch is
//  interrupted, and resuming it looks at the screen before anything else.
//

import CryptoKit
import Foundation
import Testing
@testable import Clicky

@MainActor
private final class Run {
    var replies: [[String: Any]]
    var events: [String] = []
    var checkpoints: [AgentTaskCheckpoint] = []
    var firstContent: [[String: Any]] = []
    init(_ replies: [[String: Any]]) { self.replies = replies }
}

private func call(_ name: String, _ input: [String: Any] = [:]) -> [String: Any] {
    ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": UUID().uuidString, "name": name, "input": input]]]
}

@MainActor
private func checkpointedLoop(_ run: Run) -> AgentLoop {
    AgentLoop(dependencies: AgentLoop.Dependencies(
        model: { body, _ in
            run.events.append("model")
            if run.firstContent.isEmpty, let first = (body["messages"] as? [[String: Any]])?.first {
                run.firstContent = first["content"] as? [[String: Any]] ?? []
            }
            let reply = run.replies.count > 1 ? run.replies.removeFirst() : run.replies[0]
            return AgentModelReply(json: reply, model: "fake", milliseconds: 1)
        },
        observe: { run.events.append("observe"); return AgentObservation() },
        execute: { _, _, _, _ in
            RealtimeToolDispatch(result: ["ok": true], harnessMilliseconds: 1, waitedForConfirmation: false, harnessResponse: ["ok": true])
        },
        readPage: { ["ok": true, "text": "Your PIN is 4417 and meet.google.com/abc-defg-hij"] },
        trace: { _ in },
        checkpoint: { run.checkpoints.append($0) }))
}

private let testKey = SymmetricKey(size: .bits256)
/// Task ids are a UUID's first 8 hex digits: "T7" -> "00000007".
private func taskId(_ index: Int) -> String { String(format: "%08X", index) }

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tasks-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func checkpoint(_ id: String, _ state: AgentTaskPhase, at date: Date = Date()) -> AgentTaskCheckpoint {
    AgentTaskCheckpoint(taskId: id, goal: "make a meet link", ownerWords: "make a meet link", state: state, step: 3,
                        receipts: [.init(step: 1, words: "opened meet.google.com", ok: true, error: nil)],
                        opened: [.init(bundle: "com.google.Chrome", host: "meet.google.com")], artifacts: [],
                        transitions: [AgentTaskTransition(phase: state, at: date)], createdAt: date, updatedAt: date)
}

@MainActor struct AgentTaskCheckpointTests {

    @Test func everyPhaseChangeWritesPlainWordsOnly() async {
        let secret = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let run = Run([call("type_text", ["text": "my secret draft words"]), call("read_page"),
                       call("done", ["summary": "Typed and read.", "evidence": [1, 2]])])
        let loop = checkpointedLoop(run)
        _ = await loop.run(goal: "type my draft, key \(secret)", heard: "type my draft, key \(secret)")
        #expect(run.checkpoints.count == loop.transitions.count)
        let last = run.checkpoints.last
        #expect(last?.state == .done)
        #expect(last?.step == 3)
        #expect(last?.taskId == loop.runID)
        #expect(last?.receipts.map(\.words) == ["typed 21 characters into a field", "read the page"])
        let json = String(data: (try? JSONEncoder().encode(last)) ?? Data(), encoding: .utf8) ?? ""
        #expect(!json.contains("secret draft"))
        #expect(!json.contains("4417"))
        #expect(!json.contains(secret))
        #expect(json.contains("type my draft"))
    }

    @Test func theFileIsPrivateAndOnlyTheNewestTwentyStay() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<25 {
            AgentTaskStore.write(checkpoint(taskId(index), .done), in: directory, key: testKey)
            // Distinct modification times, oldest first.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 100))],
                                                  ofItemAtPath: directory.appendingPathComponent("\(taskId(index)).json").path)
        }
        AgentTaskStore.prune(directory)
        let files = AgentTaskStore.taskFiles(directory).map(\.lastPathComponent)
        #expect(files.count == 20)
        #expect(!files.contains("\(taskId(0)).json") && !files.contains("\(taskId(4)).json") && files.contains("\(taskId(24)).json"))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(taskId(24)).json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(AgentTaskStore.read(in: directory, key: testKey).first?.taskId == taskId(24))
    }

    @Test func aTaskLeftMidTaskIsInterruptedAtLaunch() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (id, state) in [("0000000A", AgentTaskPhase.acting), ("0000000B", .waitingForOwner), ("0000000C", .waitingForCard),
                            ("0000000D", .planning), ("0000000E", .done), ("0000000F", .cancelled)] {
            AgentTaskStore.write(checkpoint(id, state), in: directory, key: testKey)
        }
        let interrupted = AgentTaskStore.markInterrupted(in: directory, key: testKey)
        #expect(Set(interrupted.map(\.taskId)) == ["0000000A", "0000000B", "0000000C", "0000000D"])
        let states = Dictionary(uniqueKeysWithValues: AgentTaskStore.read(in: directory, key: testKey).map { ($0.taskId, $0.state) })
        #expect(states == ["0000000A": .interrupted, "0000000B": .interrupted, "0000000C": .interrupted, "0000000D": .interrupted,
                           "0000000E": .done, "0000000F": .cancelled])
        #expect(interrupted.allSatisfy { $0.transitions.last?.phase == .interrupted })
    }

    // Resuming never replays: the first thing it does is look, and the model is told the screen may have changed.
    @Test func resumingAnInterruptedTaskLooksFirstAndContinuesItsCount() async {
        let run = Run([call("done", ["summary": "Checked.", "evidence": []])])
        let loop = checkpointedLoop(run)
        loop.restore(from: checkpoint("OLD12345", .interrupted))
        #expect(loop.runID == "OLD12345")
        #expect(loop.phase == .interrupted)
        #expect(loop.statusLine().contains("interrupted"))
        loop.move(to: .planning)
        _ = await loop.run(goal: "make a meet link", heard: "make a meet link yes continue")
        #expect(run.events.prefix(2) == ["observe", "model"])
        #expect(loop.step == 4)
        #expect(loop.transitions.map(\.phase).prefix(2) == [.interrupted, .planning])
        #expect(loop.illegalTransitions == 0)
        let text = run.firstContent.compactMap { $0["text"] as? String }.joined(separator: " ")
        #expect(text.contains("interrupted"))
        #expect(text.contains("opened meet.google.com"))
    }

    @Test func theVoiceOffersToContinueAndOnlyAYesResumes() {
        let line = AgentLoop.interruptedLine(checkpoint("T", .interrupted))
        #expect(line.contains("shall I continue?"))
        #expect(line.contains("make a meet link"))
        for words in ["yes", "Yes, continue.", "carry on", "go ahead", "resume it", "yeah keep going"] {
            #expect(RealtimeVoiceSession.isResumeAnswer(words), "\(words)")
        }
        for words in ["no", "open Spotify", "what's the weather", "no, don't continue", ""] {
            #expect(!RealtimeVoiceSession.isResumeAnswer(words), "\(words)")
        }
    }
}
