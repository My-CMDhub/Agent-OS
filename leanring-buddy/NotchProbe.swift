//
//  NotchProbe.swift
//  leanring-buddy
//
//  `--notch-probe`: the live push-to-talk loop, driven headless. It calls
//  `RealtimeVoiceSession.pressed()` / `released()` — the methods the hotkey
//  calls — with a fixture fed where the mic would be, so barge-ins, chains of
//  them, silence and quick taps reach the real session, connection and notch.
//  `--voice-tool-probe` drives the CONNECTION and tells the notch itself, and
//  never barges in, which is why it never saw the notch go quiet (2026-09-28).
//
//  Safety: every tool call is refused by a stub that never reaches the harness
//  (it ends in "Didn't take"), `--harness-dry-run` must be on as well, no
//  screenshot is taken or sent, nothing is heard aloud, and no window is opened,
//  focused or moved. It runs only after 120 s with no keyboard or mouse input and
//  stops the moment either comes back.
//
//  Per-turn lines and one summary per stack to ~/Library/Logs/Clicky/notch-probe.log;
//  the session's own turn lines to notch-probe-live.log; the notch's drawn
//  witness to notch-drawn.log. Spends OpenAI (capped) and Gemini credit.
//

import AppKit
import Foundation

@MainActor
enum NotchProbe {
    static let logFileName = "notch-probe.log"
    static let liveTurnLogFileName = "notch-probe-live.log"
    /// A general question: no tool, and a long enough answer to barge in on.
    static let questionFixtureFileName = "02-wallpaper.wav"
    static let defaultTurnsPerStack = 50
    static let requiredIdleSeconds: Double = 120
    static let openAICostCapUSD = 1.50
    static let rapidTapSeconds = 0.12
    static let silenceSeconds = 1.5
    /// How long a barged turn's answer plays before the next press cuts it off.
    static let bargeAfterAudioSeconds = 0.6
    static let forcedWatchdogSeconds = 0.3
    /// Release -> idle for a turn nobody barged in on: watchdog + the longest hold (2.5 s) + 1 s of slack.
    static var idleBoundSeconds: Double { RealtimeVoiceSession.noReplyWatchdogSeconds + 3.5 }

    enum Scenario: String {
        case normal, bargedIn, chain, silence, rapidTap, forcedSlow
        var isBargedOn: Bool { self == .bargedIn || self == .chain }
    }

    /// Ten turns, repeated: a barge-in cut off by a quick tap (released before
    /// Gemini's stale `turnComplete`, 114-353 ms after the press), a chain of
    /// three, silence, a tap on its own, a forced watchdog.
    static let cycle: [Scenario] = [.normal, .bargedIn, .rapidTap, .chain, .chain, .chain, .normal, .silence, .rapidTap, .forcedSlow]

    static let refusingHarnessAnswer: @Sendable (String) -> String = { _ in
        #"{"ok":false,"error":"dryRun","message":"notch probe: every tool call is refused and nothing was done"}"#
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func appendLine(_ lineObject: [String: Any]) {
        MeasurementLogFile.appendJSONLine(lineObject, toFileNamed: logFileName)
    }

    // MARK: The owner is away

    /// Seconds since the last keyboard or mouse input (IOHIDSystem's HIDIdleTime), nil if unreadable.
    nonisolated static func hidIdleSeconds() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-c", "IOHIDSystem", "-d", "4"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let line = output.split(separator: "\n").first(where: { $0.contains("\"HIDIdleTime\"") }),
              let nanoseconds = line.split(separator: "=").last.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        return nanoseconds / 1_000_000_000
    }

    /// The probe posts no input, so idle shorter than the run means the owner is back.
    @MainActor private final class OwnerWatch {
        let startUptime = ProcessInfo.processInfo.systemUptime
        private var lastCheckUptime = 0.0
        private(set) var ownerReturned = false

        /// `ioreg` runs off main: it takes tens of ms, and main is what the notch is measured on.
        func check(force: Bool = false) async -> Bool {
            let now = ProcessInfo.processInfo.systemUptime
            guard !ownerReturned else { return false }
            guard force || now - lastCheckUptime >= 0.5 else { return true }
            lastCheckUptime = now
            if let idle = await Task.detached(operation: { NotchProbe.hidIdleSeconds() }).value, idle < now - startUptime - 1 { ownerReturned = true }
            return !ownerReturned
        }
    }

    // MARK: Run

    static func run() async {
        defer { MeasurementLogFile.waitForPendingWrites() }
        let probeID = UUID().uuidString
        let logPath = MeasurementLogFile.directoryURL.appendingPathComponent(logFileName).path
        guard CommandLine.arguments.contains("--harness-dry-run") else {
            appendLine(["kind": "refused", "probeId": probeID, "reason": "needs --harness-dry-run"])
            print("🧪 notch probe: refused, needs --harness-dry-run -> \(logPath)")
            return
        }
        guard WorkerConfiguration.isConfigured else {
            appendLine(["kind": "notConfigured", "probeId": probeID])
            return
        }
        let idle = hidIdleSeconds()
        guard let idle, idle >= requiredIdleSeconds else {
            appendLine(["kind": "ownerActive", "probeId": probeID, "hidIdleSeconds": idle ?? NSNull(), "requiredIdleSeconds": requiredIdleSeconds])
            print("🧪 notch probe: owner active (idle \(idle ?? -1) s), not running -> \(logPath)")
            return
        }
        guard let (clip16k, clip24k) = VoiceToolProbe.clips(forFixture: questionFixtureFileName) else {
            appendLine(["kind": "fixtureUnreadable", "probeId": probeID, "fixture": questionFixtureFileName])
            return
        }
        let turnsPerStack = CommandLine.arguments.first { $0.hasPrefix("--notch-probe-turns=") }
            .flatMap { Int($0.dropFirst("--notch-probe-turns=".count)) }.map { max(1, $0) } ?? defaultTurnsPerStack
        let stacks = CommandLine.arguments.first { $0.hasPrefix("--notch-probe-stacks=") }.map { argument in
            argument.dropFirst("--notch-probe-stacks=".count).split(separator: ",").compactMap { VoiceStackChoice(rawValue: String($0)) }
        } ?? VoiceStackChoice.allCases
        appendLine(["kind": "start", "probeId": probeID, "turnsPerStack": turnsPerStack, "stacks": stacks.map(\.rawValue),
                    "hidIdleSeconds": idle, "fixture": questionFixtureFileName, "watchdogSeconds": RealtimeVoiceSession.noReplyWatchdogSeconds])

        let watch = OwnerWatch()
        for stack in stacks {
            let clip = stack == .openAIRealtime ? clip24k : clip16k
            let completed = await runStack(stack, turns: turnsPerStack, clip: clip, probeID: probeID, watch: watch)
            if !completed { break }
        }
        print("🧪 notch probe: finished -> \(logPath)")
    }

    private struct PressedTurn {
        let index: Int
        let scenario: Scenario
        let turnID: String
        let releasedUptime: TimeInterval
        var bargeAudioSeen: Bool?
    }

    /// false when the owner came back and the run stopped.
    private static func runStack(_ stack: VoiceStackChoice, turns: Int, clip: VoiceBenchPCMClip, probeID: String, watch: OwnerWatch) async -> Bool {
        let session = RealtimeVoiceSession(harnessAnswer: refusingHarnessAnswer)
        session.probeMode = true
        session.stackOverride = stack
        session.liveTurnLogFileName = liveTurnLogFileName
        var lines: [String: RealtimeLiveTurnLine] = [:]
        session.onLiveTurnLine = { lines[$0.turnID] = $0 }
        defer { session.stop() }

        let chunkMilliseconds = VoiceStackBenchmark.audioChunkMilliseconds
        let question = clip.chunks(milliseconds: chunkMilliseconds)
        let silentChunk = Data(count: stack.inputSampleRate * 2 * chunkMilliseconds / 1000)
        let silence = Array(repeating: silentChunk, count: Int(silenceSeconds * 1000) / chunkMilliseconds)
        var pressed: [PressedTurn] = []
        var aborted = false

        /// Polls every 20 ms; false on timeout or when the owner is back.
        func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = uptime + seconds
            while !condition() {
                guard await watch.check() else { aborted = true; return false }
                guard uptime < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }

        session.prewarm()
        turnLoop: for index in 0..<turns {
            if stack == .openAIRealtime, session.estimatedOpenAIUSD > openAICostCapUSD {
                appendLine(["kind": "costCapReached", "probeId": probeID, "stack": stack.rawValue, "atTurn": index])
                break
            }
            guard await watch.check(force: true) else { aborted = true; break }
            let scenario = cycle[index % cycle.count]
            session.noReplyWatchdogSeconds = scenario == .forcedSlow ? forcedWatchdogSeconds : RealtimeVoiceSession.noReplyWatchdogSeconds
            session.pressed()
            let turnID = JarvisNotch.shared.currentTurnID ?? "-"
            let chunks: [Data] = switch scenario {
            case .silence: silence
            case .rapidTap: Array(question.prefix(1))
            default: question
            }
            let clock = ContinuousClock()
            let streamStart = clock.now
            for (chunkIndex, chunk) in chunks.enumerated() {
                try? await clock.sleep(until: streamStart + .milliseconds(chunkMilliseconds * chunkIndex), tolerance: nil)
                session.feedProbeAudio(chunk)
            }
            try? await clock.sleep(until: streamStart + .milliseconds(scenario == .rapidTap ? Int(rapidTapSeconds * 1000) : chunkMilliseconds * chunks.count),
                                   tolerance: nil)
            session.released()
            var turn = PressedTurn(index: index, scenario: scenario, turnID: turnID, releasedUptime: uptime)
            if scenario.isBargedOn {
                // Cut the answer off mid-sentence: the next press is the barge-in.
                turn.bargeAudioSeen = await waitUntil(15) { session.isReplyAudioPlaying }
                if turn.bargeAudioSeen == true { _ = await waitUntil(bargeAfterAudioSeconds) { false } }
            } else {
                _ = await waitUntil(idleBoundSeconds + 6) {
                    lines[turnID] != nil && !session.isReplyAudioPlaying && JarvisNotch.shared.state == .idle
                }
                // The settled sample, taken 0.7 s after the idle transition.
                _ = await waitUntil(JarvisNotch.settledSampleSeconds + 0.2) { false }
            }
            pressed.append(turn)
            if aborted { break turnLoop }
        }
        if !aborted, let last = pressed.last { _ = await waitUntil(20) { lines[last.turnID] != nil } }

        var records: [[String: Any]] = []
        for turn in pressed {
            let record = turnRecord(turn, line: lines[turn.turnID], stack: stack, probeID: probeID)
            appendLine(record)
            records.append(record)
        }
        appendLine(summary(records, stack: stack, probeID: probeID, aborted: aborted,
                           estimatedOpenAIUSD: stack == .openAIRealtime ? session.estimatedOpenAIUSD : nil))
        if aborted { appendLine(["kind": "aborted", "probeId": probeID, "stack": stack.rawValue, "reason": "ownerInputResumed", "afterTurns": pressed.count]) }
        print("🧪 notch probe: \(stack.rawValue) \(pressed.count) turns\(aborted ? " (aborted: owner input)" : "")")
        return !aborted
    }

    private static func turnRecord(_ turn: PressedTurn, line: RealtimeLiveTurnLine?, stack: VoiceStackChoice, probeID: String) -> [String: Any] {
        let samples = JarvisNotch.shared.drawnSamples.filter { $0.turnID == turn.turnID }
        let mismatches = samples.filter { !$0.matchesLogic }
        let idleAfterRelease = samples.first { $0.state == "idle" && $0.transitionUptime >= turn.releasedUptime }
        let releaseToIdleMs = idleAfterRelease.map { Int((($0.transitionUptime - turn.releasedUptime) * 1000).rounded()) }
        let finalState = samples.last?.state
        var record: [String: Any] = [
            "kind": "turn", "probeId": probeID, "stack": stack.rawValue, "index": turn.index, "scenario": turn.scenario.rawValue,
            "turnId": turn.turnID, "lineWritten": line != nil, "bargeAudioSeen": turn.bargeAudioSeen ?? NSNull(),
            "drawnSamples": samples.count, "drawnMismatches": mismatches.count,
            "mismatchedSamples": mismatches.map { "\($0.state)/\($0.sample)" },
            "finalNotchState": finalState ?? NSNull(), "stuckThinking": finalState == "thinking",
            "releaseToIdleMs": releaseToIdleMs ?? NSNull(),
            // Barged turns hand the notch to the next press; the bound is for the rest.
            "idleWithinBound": turn.scenario.isBargedOn ? NSNull() : (releaseToIdleMs.map { Double($0) / 1000 <= idleBoundSeconds } ?? false),
            "earlyCompletion": (line?.finishedMs ?? 0) < 0
        ]
        if let line {
            let object = line.jsonObject
            for key in ["holdMs", "firstAudioMs", "turnDoneMs", "finishedMs", "turnEndReason", "staleCompletionsIgnored", "bargedIn",
                        "bargedInPreviousTurnId", "previousAudioWasPlaying", "errorKind", "toolName", "harnessError",
                        "eventTrail", "notchTransitions"] {
                record[key] = object[key]
            }
        }
        return record
    }

    private static func summary(_ records: [[String: Any]], stack: VoiceStackChoice, probeID: String, aborted: Bool,
                                estimatedOpenAIUSD: Double?) -> [String: Any] {
        func count(_ predicate: ([String: Any]) -> Bool) -> Int { records.filter(predicate).count }
        func sum(_ key: String) -> Int { records.reduce(0) { $0 + (($1[key] as? Int) ?? 0) } }
        var reasons: [String: Int] = [:]
        var scenarios: [String: Int] = [:]
        for record in records {
            reasons[(record["turnEndReason"] as? String) ?? "noLine", default: 0] += 1
            scenarios[(record["scenario"] as? String) ?? "-", default: 0] += 1
        }
        let normalFirstAudio = records.filter { $0["scenario"] as? String == Scenario.normal.rawValue }.map { $0["firstAudioMs"] as? Int }
        let distribution = VoiceBenchStatistics.distribution(of: normalFirstAudio)
        return [
            "kind": "summary", "probeId": probeID, "stack": stack.rawValue, "turns": records.count, "aborted": aborted,
            "scenarios": scenarios, "turnEndReasons": reasons,
            "stuckThinking": count { $0["stuckThinking"] as? Bool == true },
            "drawnSamples": sum("drawnSamples"), "drawnMismatches": sum("drawnMismatches"),
            "earlyCompletions": count { $0["earlyCompletion"] as? Bool == true },
            "staleCompletionsIgnored": sum("staleCompletionsIgnored"),
            "notIdleWithinBound": count { $0["idleWithinBound"] as? Bool == false },
            "linesMissing": count { $0["lineWritten"] as? Bool == false },
            "bargeAudioMissing": count { $0["bargeAudioSeen"] as? Bool == false },
            "normalFirstAudioMs": distribution.map { ["n": $0.count, "medianMs": $0.medianMs, "p95Ms": $0.p95Ms] as [String: Any] } ?? NSNull(),
            "estimatedOpenAIUSD": estimatedOpenAIUSD ?? NSNull()
        ]
    }
}
