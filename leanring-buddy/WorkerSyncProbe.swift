//
//  WorkerSyncProbe.swift
//  leanring-buddy
//
//  `--sync-probe` (`--sync-cases=a,b`): fault injection on the real cascade session: real fixture audio, real Nova-3, Haiku and
//  Aura, real actions on Calculator, TextEdit and Script Editor (each closed only if this run started it), cards denied in
//  process. One JSON line per case to sync-probe.log. Same gate as the runner: 120 s idle, no dry run. (`WorkerSync.swift`)
//

import AppKit
import Foundation

@MainActor
enum WorkerSyncProbe {
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func argument(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private final class Box {
        var deliveries: [[String: Any]] = []
        var report: AgentLoopReport?
        var reports = 0
        var lines: [RealtimeLiveTurnLine] = []
        var turnWords: [[String: Any]] = []
        var cardAsk: String?
    }

    static let allCases = ["baseline", "ttsKilledOnce", "ttsKilledTwice", "workerStall", "cardMidTask", "pressStop", "pressStatus", "pressNew"]
    /// Launched by a case, quit after it; never one already running.
    static let quitAfter = ["com.apple.calculator", "com.apple.TextEdit", "com.apple.ScriptEditor2"]

    static func run(harness: HarnessServer, confirmations: HarnessConfirmations) async {
        func log(_ line: [String: Any]) { MeasurementLogFile.appendJSONLine(line, toFileNamed: "sync-probe.log") }
        if let refusal = ScenarioRunner.refusalToStart() { return log(["kind": "refused", "reason": refusal]) }
        let answer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        let cases = argument("--sync-cases=")?.split(separator: ",").map(String.init) ?? allCases
        for name in cases {
            log(await runCase(name, answer: answer, confirmations: confirmations))
            MeasurementLogFile.waitForPendingWrites()
            try? await Task.sleep(for: .seconds(3))
        }
        MeasurementLogFile.waitForPendingWrites()
    }

    private static func runCase(_ name: String, answer: @escaping @Sendable (String) -> String, confirmations: HarnessConfirmations) async -> [String: Any] {
        let box = Box()
        let utterances = ScenarioRunner.loadUtterances()
        let session = RealtimeVoiceSession(harnessAnswer: answer)
        session.fixtureMic = true
        session.interruptedOffer = nil
        session.stackOverride = .cascade
        session.liveTurnLogFileName = "sync-probe-live.log"
        session.onLiveTurnLine = { box.lines.append($0) }
        session.onLiveTurnMarks = { marks in box.turnWords.append(["heard": marks?.heardText ?? "", "said": marks?.transcript ?? ""]) }
        session.onAgentLoopFinished = { box.report = $0; box.reports += 1 }
        let runningBefore = Set(quitAfter.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        let startedAt = Date()
        let origin = uptime
        func ms(_ value: TimeInterval) -> Int { Int(((value - origin) * 1000).rounded()) }
        session.onWorkerStatusDelivered = { status, turn in
            box.deliveries.append(["status": status.kind.rawValue, "said": turn?.transcript ?? NSNull(), "audio": turn?.firstAudioUptime != nil, "deliveredMs": ms(uptime),
                                   "trail": turn?.eventTrail.filter { $0.hasPrefix("tts.") } ?? []])
        }
        defer { session.stop() }
        _ = await VoiceToolProbe.ask(["verb": "focus", "app": "Finder"], answer)
        session.prewarm()
        try? await Task.sleep(for: .seconds(4))

        func speak(_ fixtureID: String) async {
            guard case .success(let pair) = ScenarioRunner.clips(for: fixtureID, utterances: utterances) else { return }
            session.pressed()
            let clock = ContinuousClock(), start = clock.now
            let chunkMs = VoiceStackBenchmark.audioChunkMilliseconds
            for (index, chunk) in pair.clip16k.chunks(milliseconds: chunkMs).enumerated() {
                try? await clock.sleep(until: start + .milliseconds(chunkMs * index), tolerance: nil)
                session.feedProbeAudio(chunk)
            }
            session.released()
        }
        /// The press's line is written: its reply has been said.
        func heardOut(count: Int, seconds: Double = 25) async {
            let until = uptime + seconds
            while uptime < until, box.lines.count < count { try? await Task.sleep(for: .milliseconds(100)) }
        }
        func endOfTasks(_ reports: Int = 1, seconds: Double = 200) async {
            let until = uptime + seconds
            while uptime < until, box.reports < reports {
                denyCards(confirmations, since: startedAt, after: 9)
                if let said = ConfirmationNudger.voiceAskTurn?.transcript, !said.isEmpty { box.cardAsk = said }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        var note: [String: Any] = [:]
        switch name {
        case "baseline":
            await speak("B4")
            await endOfTasks()
        case "ttsKilledOnce":
            // The words of the task's end, on a socket killed under them: one more socket says them.
            await speak("B4")
            await heardOut(count: 1)
            session.connectionForProbe?.killSpeechForProbe(times: 1)
            await endOfTasks()
        case "ttsKilledTwice":
            // No voice at all: the notch says it, never silence.
            await speak("B4")
            await heardOut(count: 1)
            session.connectionForProbe?.killSpeechForProbe(times: 2)
            await endOfTasks()
            note["notchReason"] = JarvisNotch.shared.transitions.suffix(4).map(\.state)
        case "workerStall":
            await speak("B4")
            await heardOut(count: 1)
            session.stallWorkerForProbe(seconds: 170)
            await endOfTasks(seconds: 130)
            session.stallWorkerForProbe(seconds: 0)
        case "cardMidTask":
            await speak("K1")
            await endOfTasks()
        case "pressStop":
            await speak("B4")
            try? await Task.sleep(for: .seconds(4))
            note["stepAtPress"] = session.agentLoop?.step ?? NSNull()
            await speak("B8")
            await endOfTasks(seconds: 40)
            await heardOut(count: 2)
            note["runningAfter"] = session.agentLoop?.isRunning ?? false
        case "pressStatus":
            await speak("B4")
            try? await Task.sleep(for: .seconds(4))
            note["stepAtPress"] = session.agentLoop?.step ?? NSNull()
            await speak("S1")
            await heardOut(count: 2)
            note["runningAfterAnswer"] = session.agentLoop?.isRunning ?? false
            await endOfTasks()
        case "pressNew":
            await speak("B4")
            try? await Task.sleep(for: .seconds(4))
            note["stepAtPress"] = session.agentLoop?.step ?? NSNull()
            await speak("K17a")
            await heardOut(count: 2)
            note["runningAfterAnswer"] = session.agentLoop?.isRunning ?? false
            await endOfTasks(2)
        default:
            return ["kind": "case", "case": name, "error": "unknown"]
        }
        try? await Task.sleep(for: .seconds(2))
        // A force-quit TextEdit relaunches with every window it had (K01 and K16 then judged 6 of them, 2026-11-03).
        if !runningBefore.contains("com.apple.TextEdit") { note["textEdit"] = await ScenarioCatalog.closeRunTextEditWindows() }
        for bundle in quitAfter where !runningBefore.contains(bundle) {
            // Only the run's own document or calculation: nothing of the owner's to save.
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) { _ = application.forceTerminate() }
        }
        var line: [String: Any] = ["kind": "case", "case": name, "note": note, "deliveries": box.deliveries, "reports": box.reports, "words": box.turnWords,
                                   "cardAsk": box.cardAsk ?? NSNull(), "outcome": box.report?.outcome.name ?? NSNull(), "steps": box.report?.steps ?? NSNull(),
                                   "elapsedMs": ms(uptime)]
        line["turns"] = box.lines.map { turn -> [String: Any] in
            ["firstAudioMs": turn.firstAudioMs ?? NSNull(), "sttFinalMs": turn.cascadeSttFinalMs ?? NSNull(), "turnDoneMs": turn.turnDoneMs ?? NSNull(),
             "error": turn.errorKind ?? NSNull(), "end": turn.turnEndReason ?? NSNull(), "handOffWords": turn.handOffWordsSpoken,
             "trail": turn.eventTrail.filter { $0.hasPrefix("stt.") || $0.hasPrefix("tts.") }]
        }
        return line
    }

    private static func denyCards(_ confirmations: HarnessConfirmations, since: Date, after seconds: TimeInterval) {
        for ticket in confirmations.tickets where ticket.createdAt >= since && HarnessConfirmations.status(of: ticket, now: Date()) == .pending
            && Date().timeIntervalSince(ticket.createdAt) >= seconds {
            confirmations.answer(ticket.id, allow: false, scope: .once)
        }
    }
}
