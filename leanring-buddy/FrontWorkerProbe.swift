//
//  FrontWorkerProbe.swift
//  leanring-buddy
//
//  What the front-and-worker stack is measured by, nobody there (`FrontAndWorker.swift`).
//
//  `--route-probe`: who should decide a turn. Over labelled words: the local check, then Haiku through
//  the worker's /chat (accuracy and latency, `--route-rounds=N`). Over fixtures: Gemini alone, on its own
//  ear, and on Nova-3's words: did it call do_task when the words asked for the machine, and not when they did not.
//  Nothing acts: do_task is a stub here, and the words are only classified.
//
//  `--front-probe` (`--front-cases=a,b`): fault injection on the real session: real fixture audio, real Gemini, Nova-3 and
//  Haiku, real actions on Calculator, TextEdit and Script Editor (each closed only if this run started it), cards denied in
//  process. One JSON line per case to front-probe.log. Same gate as the runner: 120 s idle, no dry run.
//

import AppKit
import Foundation

@MainActor
enum FrontWorkerProbe {
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func argument(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    // MARK: Route

    /// Words -> where they should go; `nil`: either is fine. The context is what a running task adds.
    struct Labelled { let words: String; let expect: FrontRoute?; var running: String? = nil; var previous: String? = nil; var replaces: Bool? = nil; var continues: Bool? = nil }

    static let labelled: [Labelled] = {
        // Every action the scenario fixtures speak.
        var rows = ScenarioRunner.loadUtterances().compactMap { id, utterance -> Labelled? in
            guard !id.hasPrefix("T"), !["B8", "S1", "S2", "K18a", "K04"].contains(id) else { return nil }
            return Labelled(words: utterance.words, expect: .act)
        }
        rows += [
            Labelled(words: "I don't need this window right now", expect: nil),
            Labelled(words: "hey can you close the calculator, actually wait, hold on, not yet", expect: nil),
            Labelled(words: "what's on my screen", expect: .act), Labelled(words: "what's open right now", expect: .act),
            Labelled(words: "what am I looking at", expect: .act), Labelled(words: "how much battery do I have left", expect: .act),
            Labelled(words: "what's the weather like", expect: .act), Labelled(words: "what time is my next meeting", expect: .act),
            Labelled(words: "how are you this morning", expect: .chat), Labelled(words: "thanks, that was quick", expect: .chat),
            Labelled(words: "tell me a joke", expect: .chat), Labelled(words: "what's the capital of France", expect: .chat),
            Labelled(words: "what can you do", expect: .chat), Labelled(words: "who built you", expect: .chat),
            Labelled(words: "good morning", expect: .chat), Labelled(words: "what do you think of rust", expect: .chat),
            Labelled(words: "that's brilliant, cheers", expect: .chat), Labelled(words: "explain what a mutex is", expect: .chat),
            Labelled(words: "write me a haiku about spring", expect: .chat), Labelled(words: "how do you say hello in Japanese", expect: .chat),
            // Beside a running task.
            Labelled(words: "is it done yet", expect: .chat, running: "open a new textedit document and type my shopping list"),
            Labelled(words: "how's it going", expect: .chat, running: "open a new textedit document and type my shopping list"),
            Labelled(words: "what step are you on", expect: .chat, running: "search google for superloop and open their official site"),
            Labelled(words: "did you open the plans page yet", expect: .chat, running: "open the plans page on this shop and tell me the cheapest plan"),
            Labelled(words: "open the calculator", expect: .act, running: "open a new textedit document and type my shopping list", replaces: false),
            Labelled(words: "no, open chrome instead", expect: .act, running: "open safari", replaces: true),
            // A follow-up leans on the turn before.
            Labelled(words: "okay now hide that one", expect: .act, previous: "open the calculator", continues: true),
            Labelled(words: "yeah do it", expect: .act, previous: "hey can you close the calculator, actually wait, hold on, not yet", continues: true),
            Labelled(words: "um, actually, put that away", expect: .act, previous: "open the calculator", continues: true),
            Labelled(words: "open the calculator", expect: .act, previous: "how are you this morning", continues: false)
        ]
        return rows.sorted { $0.words < $1.words }
    }()

    static func runRouteProbe() async {
        let file = "route-probe.log"
        func log(_ line: [String: Any]) { MeasurementLogFile.appendJSONLine(line, toFileNamed: file) }
        let rounds = Int(argument("--route-rounds=") ?? "") ?? 2
        // The local check, no network.
        var localHits = 0, localWrong: [String] = [], localMissedActs = 0
        for row in labelled where row.running == nil && row.previous == nil {
            let hit = FrontRouter.local(row.words)
            if hit == .act {
                localHits += 1
                if row.expect == .chat { localWrong.append(row.words) }
            } else if row.expect == .act { localMissedActs += 1 }
        }
        log(["kind": "local", "n": labelled.count, "hits": localHits, "wrong": localWrong, "actsLeftToHaiku": localMissedActs])
        // Haiku, every row, forced through (the local check is what `decide` tries first, so it is not called here).
        var latencies: [Int] = [], wrong: [[String: Any]] = [], usage: [String: Int] = [:], failures = 0
        for round in 0..<rounds {
            for row in labelled {
                let context = FrontRouter.Context(runningGoal: row.running, question: nil, previousWords: row.previous)
                let started = uptime
                guard let answer = await askHaiku(words: row.words, context: context) else { failures += 1; continue }
                let ms = Int(((uptime - started) * 1000).rounded())
                latencies.append(ms)
                for (key, value) in answer.usage { usage[key, default: 0] += value }
                let routeWrong = row.expect.map { $0 != answer.route } ?? false
                let replacesWrong = row.replaces.map { $0 != answer.replaces } ?? false
                let continuesWrong = row.continues.map { $0 != answer.continues } ?? false
                if routeWrong || replacesWrong || continuesWrong {
                    wrong.append(["round": round, "words": row.words, "route": answer.route.rawValue, "replaces": answer.replaces, "continues": answer.continues])
                }
                log(["kind": "haiku", "round": round, "ms": ms])
            }
        }
        latencies.sort()
        func pct(_ p: Double) -> Int { latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * p))] }
        log(["kind": "haikuSummary", "n": latencies.count, "failures": failures, "p50": pct(0.5), "p90": pct(0.9), "p99": pct(0.99), "max": latencies.last ?? 0,
             "wrong": wrong, "usage": usage])
        MeasurementLogFile.waitForPendingWrites()
    }

    private static func askHaiku(words: String, context: FrontRouter.Context) async -> (route: FrontRoute, replaces: Bool, continues: Bool, usage: [String: Int])? {
        var request = URLRequest(url: WorkerConfiguration.routeURL("/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        WorkerConfiguration.attachClientKey(to: &request)
        guard let body = try? JSONSerialization.data(withJSONObject: FrontRouter.requestBody(words: words, context: context), options: [.sortedKeys]) else { return nil }
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let parsed = FrontRouter.parse(json) else { return nil }
        var usage: [String: Int] = [:]
        for (key, value) in json["usage"] as? [String: Any] ?? [:] { if let number = value as? Int { usage[key] = number } }
        return (parsed.route, parsed.replaces, parsed.continues, usage)
    }

    /// Gemini deciding by itself, on its own ear and on Nova-3's words. do_task is a stub.
    static func runGeminiRouteProbe(answer: @escaping @Sendable (String) -> String) async {
        let file = "route-probe.log"
        func log(_ line: [String: Any]) { MeasurementLogFile.appendJSONLine(line, toFileNamed: file) }
        if let refusal = ScenarioRunner.refusalToStart() { return log(["kind": "refused", "reason": refusal]) }
        let fixtures: [(id: String, act: Bool)] = [("A1", true), ("A3", true), ("A10", true), ("K07", true), ("K10", true), ("K14", true), ("K15", true),
                                                    ("K16", true), ("K05", true), ("B7", true), ("T1", false), ("T2", false), ("T3", false), ("T4", false), ("T5", false), ("T6", false)]
        let utterances = ScenarioRunner.loadUtterances()
        for condition in ["geminiEar", "novaWords"] {
            for fixture in fixtures {
                guard case .success(let pair) = ScenarioRunner.clips(for: fixture.id, utterances: utterances) else {
                    log(["kind": "gemini", "id": fixture.id, "error": "fixture"])
                    continue
                }
                let connection = RealtimeVoiceConnection(stack: .frontAndWorker, harnessAnswer: answer)
                do { try await connection.connect() } catch { log(["kind": "gemini", "id": fixture.id, "error": "connect"]); continue }
                var called = false
                connection.onDoTask = { _, _, _, _ in
                    called = true
                    return ["ok": true, "status": "started", "message": "say only a few words"]
                }
                connection.onFrontTurn = { marks, _ in
                    condition == "novaWords" ? FrontTurnPlan(lines: [FrontPrompt.heardLine(marks.heardText), FrontPrompt.chatLine], plain: nil)
                        : FrontTurnPlan(lines: [], plain: nil)
                }
                try? await connection.beginTurn()
                let clock = ContinuousClock(), start = clock.now
                let chunkMs = VoiceStackBenchmark.audioChunkMilliseconds
                for (index, chunk) in pair.clip16k.chunks(milliseconds: chunkMs).enumerated() {
                    try? await clock.sleep(until: start + .milliseconds(chunkMs * index), tolerance: nil)
                    try? await connection.appendAudio(chunk)
                }
                try? await connection.endTurn()
                let marks = connection.turn
                _ = try? await marks.finished.value(timeoutSeconds: 15, timeoutKind: "probe")
                log(["kind": "gemini", "condition": condition, "id": fixture.id, "expectAct": fixture.act, "called": called,
                     "right": called == fixture.act, "heardNova": marks.heardText, "heardGemini": marks.geminiHeardText, "said": marks.transcript,
                     "firstAudioMs": marks.firstAudioUptime.flatMap { first in marks.lastAudioSentUptime.map { Int((first - $0) * 1000) } } ?? NSNull()])
                connection.close()
                MeasurementLogFile.waitForPendingWrites()
            }
        }
    }

    // MARK: Fault injection

    private final class Box {
        var deliveries: [[String: Any]] = []
        var report: AgentLoopReport?
        var reports = 0
        var lines: [RealtimeLiveTurnLine] = []
        var turnWords: [[String: Any]] = []
        var socket: [[String: Any]] = []
        var cardAsk: String?
    }

    static let allCases = ["baseline", "socketKilled", "frontUnreachable", "frontSilent", "goAway", "workerStall", "cardMidTask", "pressStop", "pressStatus", "pressNew", "earFailed"]
    /// Launched by a case, quit after it; never one already running.
    static let quitAfter = ["com.apple.calculator", "com.apple.TextEdit", "com.apple.ScriptEditor2"]

    static func runFrontProbe(harness: HarnessServer, confirmations: HarnessConfirmations) async {
        func log(_ line: [String: Any]) { MeasurementLogFile.appendJSONLine(line, toFileNamed: "front-probe.log") }
        if let refusal = ScenarioRunner.refusalToStart() { return log(["kind": "refused", "reason": refusal]) }
        let answer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        let cases = argument("--front-cases=")?.split(separator: ",").map(String.init) ?? allCases
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
        session.stackOverride = .frontAndWorker
        session.liveTurnLogFileName = "front-probe-live.log"
        session.onLiveTurnLine = { box.lines.append($0) }
        session.onLiveTurnMarks = { marks in
            box.turnWords.append(["heard": marks?.heardText ?? "", "said": marks?.transcript ?? "", "gemini": marks?.geminiHeardText ?? ""])
        }
        session.onAgentLoopFinished = { box.report = $0; box.reports += 1 }
        let runningBefore = Set(quitAfter.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        let startedAt = Date()
        let origin = uptime
        func ms(_ value: TimeInterval) -> Int { Int(((value - origin) * 1000).rounded()) }
        session.onFrontStatusDelivered = { status, turn in
            box.deliveries.append(["status": status.kind.rawValue, "via": turn?.frontVia ?? NSNull(), "said": turn?.transcript ?? NSNull(),
                                   "deliveredMs": ms(uptime),
                                   "statusFirstAudioMs": turn.flatMap { turn in turn.firstAudioUptime.flatMap { first in turn.lastAudioSentUptime.map { Int((first - $0) * 1000) } } } ?? NSNull()])
        }
        session.onFrontSocketForProbe = { event in box.socket.append(["event": event, "ms": ms(uptime)]) }
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
        /// The press's line is written: its acknowledgement has been said.
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
            await speak("K17a")
            await endOfTasks()
        case "socketKilled":
            await speak("B4")
            await heardOut(count: 1)
            let killed = uptime
            session.connectionForProbe?.killFrontForProbe()
            note["killedMs"] = ms(killed)
            await endOfTasks()
        case "frontUnreachable":
            await speak("B4")
            await heardOut(count: 1)
            session.connectionForProbe?.frontUnreachableForProbe = true
            session.connectionForProbe?.killFrontForProbe()
            note["killedMs"] = ms(uptime)
            await endOfTasks()
        case "frontSilent":
            await speak("B4")
            await heardOut(count: 1)
            session.connectionForProbe?.frontDeafForProbe = true
            note["deafMs"] = ms(uptime)
            await endOfTasks()
            session.connectionForProbe?.frontDeafForProbe = false
        case "goAway":
            await speak("B4")
            await heardOut(count: 1)
            session.connectionForProbe?.handle(["goAway": ["timeLeft": "10s"]], arrivalUptime: uptime)
            note["goAwayMs"] = ms(uptime)
            await endOfTasks()
        case "workerStall":
            session.stallWorkerForProbe(seconds: 170)
            await speak("K17a")
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
        case "earFailed":
            session.prewarm()
            try? await Task.sleep(for: .seconds(1))
            session.connectionForProbe?.breakEarForProbe()
            await speak("K17a")
            await heardOut(count: 1)
            await endOfTasks(seconds: 60)
        default:
            return ["kind": "case", "case": name, "error": "unknown"]
        }
        try? await Task.sleep(for: .seconds(2))
        for bundle in quitAfter where !runningBefore.contains(bundle) {
            // Only the run's own document or calculation: nothing of the owner's to save.
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) { _ = application.forceTerminate() }
        }
        var line: [String: Any] = ["kind": "case", "case": name, "note": note, "deliveries": box.deliveries, "reports": box.reports, "words": box.turnWords,
                                   "socket": box.socket, "cardAsk": box.cardAsk ?? NSNull(),
                                   "outcome": box.report?.outcome.name ?? NSNull(), "steps": box.report?.steps ?? NSNull(),
                                   "elapsedMs": ms(uptime)]
        line["turns"] = box.lines.map { turn -> [String: Any] in
            ["route": turn.frontRoute ?? NSNull(), "source": turn.frontRouteSource ?? NSNull(), "routeMs": turn.frontRouteMs ?? NSNull(), "via": turn.frontVia ?? NSNull(),
             "heardSource": turn.heardSource ?? NSNull(), "firstAudioMs": turn.firstAudioMs ?? NSNull(), "sttFinalMs": turn.cascadeSttFinalMs ?? NSNull(),
             "turnDoneMs": turn.turnDoneMs ?? NSNull(), "error": turn.errorKind ?? NSNull(), "end": turn.turnEndReason ?? NSNull(),
             "handOffWords": turn.handOffWordsSpoken, "trail": turn.eventTrail.filter { $0.hasPrefix("front.") || $0.hasPrefix("ear.") || $0.hasPrefix("stt.") }]
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
