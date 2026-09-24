//
//  VoiceToolProbe.swift
//  leanring-buddy
//
//  `--voice-tool-probe`: does a speech-to-speech model USE `open_app` when asked
//  to open an app, and does it tell the truth about the result? Measured on both
//  stacks with the committed "open settings" fixture instead of the mic, through
//  the same `RealtimeVoiceConnection` the live loop uses and the same
//  `HarnessServer.answer` the socket uses — every guard applies.
//
//  System Settings is quit before every run so each launch is real — or, with
//  `--voice-tool-probe-preopen`, launched through the harness and left frontmost,
//  the case where the model once claimed success without calling the tool
//  (72985B9B). `--voice-tool-probe-runs=N` sets runs per stack;
//  `--voice-tool-probe-app=<name>` replaces the app every call names, forcing a
//  failure through the real harness path; `--voice-tool-probe-notch-shots`
//  saves one crop of the notch per state to the log directory. Whether
//  it ended up frontmost is read from NSWorkspace, not from the verb's own
//  AX-based verification: a verb that marks its own homework proves nothing.
//
//  One JSON line per run to ~/Library/Logs/Clicky/voice-tool-probe.log (timings,
//  tool args, harness status); what the model SAID goes only to a 0600
//  answers file. Spends OpenAI credit, capped; run by hand only.
//

import AppKit
import Foundation

@MainActor
enum VoiceToolProbe {
    static let logFileName = "voice-tool-probe.log"
    static let defaultRunsPerStack = 10
    static let openAICostCapUSD = 0.50
    static let fixtureFileName = "05-open-settings.wav"
    static let systemSettingsBundleIdentifier = "com.apple.systempreferences"
    /// A tool call may wait on a 60 s confirmation ticket, plus the answer after it.
    static let turnTimeoutSeconds: Double = 90
    static let unpromptedReplyWatchSeconds: Double = 3

    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func appendLine(_ lineObject: [String: Any]) {
        MeasurementLogFile.appendJSONLine(lineObject, toFileNamed: logFileName)
    }

    static func milliseconds(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
        guard let start, let end else { return nil }
        return Int(((end - start) * 1000).rounded())
    }

    static func run(harness: HarnessServer) async {
        defer { MeasurementLogFile.waitForPendingWrites() }
        let probeID = UUID().uuidString
        let logPath = MeasurementLogFile.directoryURL.appendingPathComponent(logFileName).path
        guard WorkerConfiguration.isConfigured else {
            appendLine(["kind": "notConfigured", "probeId": probeID])
            print("🧪 voice tool probe: worker not configured -> \(logPath)")
            return
        }

        // The menu verbs' scenarios are their own run: fixtures, set-up, checks.
        if CommandLine.arguments.contains("--voice-tool-probe-menus") {
            await runMenuScenarios(harness: harness, probeID: probeID)
            return
        }

        guard let (clip16k, clip24k) = clips(forFixture: fixtureFileName) else {
            appendLine(["kind": "fixtureUnreadable", "probeId": probeID, "fixture": fixtureFileName])
            print("🧪 voice tool probe: fixture unreadable -> \(logPath)")
            return
        }

        let preOpen = CommandLine.arguments.contains("--voice-tool-probe-preopen")
        let runsPerStack = runsPerStackArgument(default: defaultRunsPerStack)
        let harnessAnswer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        // Pre-open mode: the one screenshot must show the app already open.
        if preOpen { _ = await openSystemSettings(harnessAnswer: harnessAnswer) }
        let appNameOverride = CommandLine.arguments.first { $0.hasPrefix("--voice-tool-probe-app=") }
            .map { String($0.dropFirst("--voice-tool-probe-app=".count)) }
        // The harness's own frontmost read, either side of every notch transition.
        JarvisNotch.shared.frontmostWitness = { HarnessServer.frontmostBundleIdentifier() }
        defer { JarvisNotch.shared.frontmostWitness = nil }
        if CommandLine.arguments.contains("--voice-tool-probe-notch-shots") { captureOneShotPerNotchState() }

        // One screenshot for every run, as the bench does.
        guard let screenshot = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen) else {
            appendLine(["kind": "captureFailed", "probeId": probeID])
            print("🧪 voice tool probe: capture failed -> \(logPath)")
            return
        }

        appendLine([
            "kind": "start", "probeId": probeID, "fixture": fixtureFileName, "runsPerStack": runsPerStack,
            "mode": preOpen ? "preOpen" : "quitFirst", "appNameOverride": appNameOverride ?? NSNull(),
            "openAICostCapUSD": openAICostCapUSD, "imageBytes": screenshot.imageData.count,
            "harnessSession": HarnessServer.sessionIdentifier
        ])
        let answersFile = VoiceStackBenchmark.openOwnerOnlyAnswersFile(
            at: MeasurementLogFile.directoryURL.appendingPathComponent("voice-tool-probe-answers-\(probeID).jsonl"))
        defer { try? answersFile?.close() }

        let selectedStacks = selectedStacksArgument()
        var openAISpentUSD = 0.0
        var runLines: [VoiceStackChoice: [[String: Any]]] = [:]
        var answers: [VoiceStackChoice: [String]] = [:]

        for runNumber in 1...runsPerStack {
            // Alternating first stack, so neither always inherits a warm network path.
            let order: [VoiceStackChoice] = runNumber % 2 == 1 ? [.openAIRealtime, .geminiLive] : [.geminiLive, .openAIRealtime]
            for stack in order where selectedStacks.contains(stack) {
                if stack == .openAIRealtime, openAISpentUSD > openAICostCapUSD { continue }
                let clip = stack == .openAIRealtime ? clip24k : clip16k
                let (line, transcript, spentUSD) = await measureOneRun(
                    stack: stack, runNumber: runNumber, probeID: probeID, clip: clip, preOpen: preOpen, appNameOverride: appNameOverride,
                    screenshotJPEG: screenshot.imageData, harnessAnswer: harnessAnswer)
                if stack == .openAIRealtime { openAISpentUSD += spentUSD }
                appendLine(line)
                runLines[stack, default: []].append(line)
                answers[stack, default: []].append(transcript)
                if let answersFile, let answerLine = MeasurementLogFile.jsonLine([
                    "probeId": probeID, "stack": stack.rawValue, "run": runNumber, "said": transcript
                ]) {
                    try? answersFile.write(contentsOf: Data((answerLine + "\n").utf8))
                }
                print("🧪 voice tool probe: \(stack.rawValue) #\(runNumber) \(line["errorKind"] ?? "ok") tool=\(line["toolCalled"] ?? "-") status=\(line["harnessStatus"] ?? "-")")
            }
        }

        for stack in selectedStacks {
            appendLine(summary(for: runLines[stack] ?? [], answers: answers[stack] ?? [], stack: stack, probeID: probeID,
                               spentUSD: stack == .openAIRealtime ? openAISpentUSD : nil))
        }
        print("🧪 voice tool probe: finished (OpenAI estimated US$\(openAISpentUSD)) -> \(logPath)")
    }

    /// The 16 kHz clip and its 24 kHz twin, or nil when either is unreadable.
    static func clips(forFixture fileName: String) -> (clip16k: VoiceBenchPCMClip, clip24k: VoiceBenchPCMClip)? {
        let fixture16kData = try? Data(contentsOf: VoiceStackBenchmark.fixtureDirectoryURL.appendingPathComponent(fileName))
        guard let fixture16kData, let clip16k = VoiceBenchPCMClip.parseWAV(fixture16kData), clip16k.sampleRate == 16_000,
              case .success(let clip24k) = VoiceBenchPCMClip.paired24kClip(
                fileData: try? Data(contentsOf: VoiceStackBenchmark.fixture24kDirectoryURL.appendingPathComponent(fileName)),
                matching: clip16k) else { return nil }
        return (clip16k, clip24k)
    }

    static func runsPerStackArgument(default defaultRuns: Int) -> Int {
        CommandLine.arguments.first { $0.hasPrefix("--voice-tool-probe-runs=") }
            .flatMap { Int($0.dropFirst("--voice-tool-probe-runs=".count)) }.map { max(1, $0) } ?? defaultRuns
    }

    /// `--voice-tool-probe-stacks=geminiLive` re-runs one stack without paying for the other.
    static func selectedStacksArgument() -> [VoiceStackChoice] {
        CommandLine.arguments.first { $0.hasPrefix("--voice-tool-probe-stacks=") }.map { argument in
            argument.dropFirst("--voice-tool-probe-stacks=".count).split(separator: ",").compactMap { VoiceStackChoice(rawValue: String($0)) }
        } ?? VoiceStackChoice.allCases
    }

    // MARK: One run

    private static func measureOneRun(
        stack: VoiceStackChoice, runNumber: Int, probeID: String, clip: VoiceBenchPCMClip, preOpen: Bool, appNameOverride: String?,
        screenshotJPEG: Data, harnessAnswer: @escaping @Sendable (String) -> String
    ) async -> (line: [String: Any], transcript: String, spentUSD: Double) {
        var line: [String: Any] = ["kind": "run", "probeId": probeID, "stack": stack.rawValue, "run": runNumber]
        if preOpen {
            line["systemSettingsPreOpened"] = await openSystemSettings(harnessAnswer: harnessAnswer)
        } else {
            line["systemSettingsQuit"] = await quitSystemSettings()
        }

        let connection = RealtimeVoiceConnection(stack: stack, harnessAnswer: harnessAnswer)
        connection.appNameOverride = appNameOverride
        defer { connection.close() }
        let facts = await runTurn(on: connection, clip: clip, screenshotJPEG: screenshotJPEG)
        line.merge(facts) { _, new in new }

        let frontmostBundleIdentifier = line["frontmostBundleIdentifier"] as? String
        line["systemSettingsFrontmost"] = frontmostBundleIdentifier == systemSettingsBundleIdentifier
        let turnID = UUID().uuidString
        line["turnId"] = turnID
        RealtimeDecisionTrace.append(
            connection.turn.decisions, turnID: turnID, stack: stack.rawValue, source: "probe",
            releasedUptime: connection.turn.lastAudioSentUptime, probeID: probeID, fixture: fixtureFileName,
            independentCheck: ["kind": "frontmost", "expected": systemSettingsBundleIdentifier,
                               "actual": frontmostBundleIdentifier ?? NSNull(), "passed": frontmostBundleIdentifier == systemSettingsBundleIdentifier])
        // The fixture is always an open request, so no call is a skipped tool.
        line["toolSkipped"] = connection.turn.toolCalls.isEmpty
        let spentUSD = stack == .openAIRealtime ? connection.estimatedOpenAIUSD : 0
        if stack == .openAIRealtime { line["estimatedCostUSD"] = spentUSD }
        return (line, connection.turn.transcript, spentUSD)
    }

    /// One fixture turn on an open-to-be connection, and everything the turn
    /// did that does not depend on which fixture it was: marks, tool calls and
    /// results, the notch's order, the honesty checks, frontmost after.
    static func runTurn(on connection: RealtimeVoiceConnection, clip: VoiceBenchPCMClip, screenshotJPEG: Data) async -> [String: Any] {
        var line: [String: Any] = [:]
        let runStartUptime = uptime
        var marks: [String: Any] = [:]
        var errorKind: String?
        do {
            let setupStart = uptime
            try await connection.connect()
            try await connection.sendScreenshot(screenshotJPEG)
            marks["sessionSetupMs"] = milliseconds(from: setupStart, to: uptime)
            try await connection.beginTurn()
            // The fixture stands in for the held hotkey, and its own level drives the bars.
            JarvisNotch.shared.handle(.hotkeyDown)
            let clock = ContinuousClock()
            let streamStart = clock.now
            for (chunkIndex, chunk) in clip.chunks(milliseconds: VoiceStackBenchmark.audioChunkMilliseconds).enumerated() {
                try await clock.sleep(until: streamStart + .milliseconds(VoiceStackBenchmark.audioChunkMilliseconds * chunkIndex), tolerance: nil)
                try await connection.appendAudio(chunk)
                JarvisNotch.shared.setLevel(rms: JarvisNotchLevel.rms(pcm16: chunk))
            }
            JarvisNotch.shared.handle(.hotkeyUp)
            try await connection.endTurn()
            _ = try await connection.turn.finished.value(timeoutSeconds: turnTimeoutSeconds, timeoutKind: "turnTimeout")
            // The look is sent as context with no reply asked for; watch long
            // enough after it that a reply to it would be counted.
            await connection.turn.waitForFreshLook()
            try? await Task.sleep(for: .seconds(unpromptedReplyWatchSeconds))
        } catch {
            errorKind = (error as? VoiceBenchFailure)?.kind ?? VoiceBenchRun.errorKind(for: error, stage: connection.stack.rawValue)
            JarvisNotch.shared.handle(.turnEnded)
        }
        // Let a proof or didn't-take hold play out, so the next run starts idle.
        let settleDeadline = uptime + 3
        while JarvisNotch.shared.state != .idle, uptime < settleDeadline { try? await Task.sleep(for: .milliseconds(50)) }

        // Independent witness, after the app has had a moment to come forward.
        try? await Task.sleep(for: .milliseconds(500))
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let turn = connection.turn
        let notchTransitions = JarvisNotch.shared.transitions.filter { $0.uptime >= runStartUptime }
        let released = turn.lastAudioSentUptime
        let firstDispatch = turn.dispatches.first
        // The receipt is an ACTING tool's ok: a find that worked changed nothing.
        let actingOk = turn.decisions.filter { RealtimeVoiceVerbs.isActingTool($0.call.name) }.compactMap(\.dispatch).filter(\.harnessConfirmed)
        marks["firstAudioMs"] = milliseconds(from: released, to: turn.firstAudioUptime)
        marks["toolCallMs"] = milliseconds(from: released, to: turn.toolCallUptime)
        marks["harnessMs"] = firstDispatch?.harnessMilliseconds
        marks["freshLookMs"] = turn.freshLookMilliseconds
        marks["freshLookArrivedAfterSpeechStartMs"] = turn.freshLookArrivedAfterSpeechStartMs
        marks["followUpFirstAudioMs"] = milliseconds(from: turn.toolResultSentUptime, to: turn.followUpFirstAudioUptime)
        marks["totalToFirstSpokenResultMs"] = milliseconds(from: released, to: turn.followUpFirstAudioUptime)
        marks["intentLeadMs"] = milliseconds(from: turn.intentShownUptime, to: firstDispatch?.firstRequestSentUptime)
        if let firstAudio = turn.firstAudioUptime, firstAudio < (turn.toolCallUptime ?? .infinity), turn.toolCallUptime != nil {
            marks["firstAudioBeforeToolMs"] = milliseconds(from: released, to: firstAudio)
        }

        line["marksMs"] = marks
        line["toolCalled"] = !turn.toolCalls.isEmpty
        line["toolCalls"] = turn.toolCalls.map {
            ["name": $0.name, "app": ($0.appName ?? NSNull()) as Any, "args": RealtimeDecisionTrace.loggedArguments(for: $0)] as [String: Any]
        }
        line["toolResults"] = turn.dispatches.map(\.result)
        line["harnessStatus"] = (firstDispatch?.result["status"] as? String) ?? NSNull()
        line["harnessError"] = (firstDispatch?.result["error"] as? String) ?? NSNull()
        line["harnessConfirmed"] = !actingOk.isEmpty
        line["intentShownBeforeLaunchRequest"] = turn.intentShownUptime.flatMap { shown in
            firstDispatch?.firstRequestSentUptime.map { shown <= $0 } } ?? false
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        line["notchTransitions"] = notchTransitions.map { transition in
            ["state": transition.state, "ms": milliseconds(from: released, to: transition.uptime) ?? NSNull(),
             "frontmostBefore": transition.frontmostBefore ?? NSNull(), "frontmostAfter": transition.frontmostAfter ?? NSNull()] as [String: Any]
        }
        let proofs = notchTransitions.filter { $0.state == "proof" }
        let confirmedAnswers = actingOk.compactMap(\.answeredUptime)
        line["proofShown"] = !proofs.isEmpty
        line["didntTakeShown"] = notchTransitions.contains { $0.state == "didntTake" }
        // A proof with no confirmed acting answer at or before it is the one lie the notch must never tell.
        line["proofViolations"] = proofs.filter { proof in !confirmedAnswers.contains { $0 <= proof.uptime } }.count
        line["proofAfterOkMs"] = proofs.first.flatMap { proof in milliseconds(from: confirmedAnswers.first, to: proof.uptime) } ?? NSNull()
        line["frontmostUnchangedByNotch"] = notchTransitions.allSatisfy { transition in
            transition.frontmostBefore == transition.frontmostAfter
                && transition.frontmostAfter != nil && transition.frontmostAfter != ownBundleIdentifier
        }
        line["freshLook"] = turn.freshLookOutcome ?? NSNull()
        line["freshLookImageBytes"] = turn.freshLookImageBytes ?? NSNull()
        line["audioChunksAfterFinish"] = turn.audioChunksAfterFinish
        line["waitedForConfirmation"] = turn.dispatches.contains(where: \.waitedForConfirmation)
        line["frontmostBundleIdentifier"] = frontmostBundleIdentifier ?? NSNull()
        line["claimedSuccessWithoutReceipt"] = RealtimeOpenAppTool.claimedSuccessWithoutReceipt(
            transcript: turn.transcript, hadOkToolResult: !actingOk.isEmpty)
        line["reusedExampleVerbatim"] = RealtimeOpenAppTool.reusesExampleVerbatim(turn.transcript)
        line["reusedExampleTemplate"] = RealtimeOpenAppTool.reusesExampleTemplate(turn.transcript)
        line["spokenCharacters"] = turn.transcript.count
        line["outputAudioMime"] = turn.outputAudioMime ?? NSNull()
        line["eventTrail"] = turn.eventTrail
        line["errorKind"] = errorKind ?? NSNull()
        return line
    }

    /// One crop of the top band round the notch per state, the first time each is
    /// shown, after its motion has settled. Written beside the logs; read before
    /// publishing — the band carries whatever the menu bar showed.
    private static func captureOneShotPerNotchState() {
        let delays: [String: Double] = ["listening": 0.5, "intent": 0.35, "proof": 0.9, "didntTake": 0.6]
        var taken = Set<String>()
        JarvisNotch.shared.onTransition = { state in
            guard let delay = delays[state.name], !taken.contains(state.name) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard JarvisNotch.shared.state.name == state.name, !taken.contains(state.name),
                      let frame = JarvisNotch.shared.panelFrame, let primary = NSScreen.screens.first,
                      let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return }
                taken.insert(state.name)
                // From the screen's top edge, so the menu bar round the notch is in frame.
                // `screencapture -R` is top-left global points; AppKit is bottom-left.
                let region = CGRect(x: frame.minX - 60, y: primary.frame.maxY - screen.frame.maxY,
                                    width: frame.width + 120, height: screen.frame.maxY - frame.minY + 8)
                let path = MeasurementLogFile.directoryURL.appendingPathComponent("notch-\(state.name).png").path
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", path]
                try? process.run()
            }
        }
    }

    /// The harness's own `launch`, left frontmost: the "already open" start state.
    private static func openSystemSettings(harnessAnswer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        let line = #"{"app":"System Settings","verb":"launch"}"#
        let response = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { harnessAnswer(line) }.value)
        return ["ok": response["ok"] as? Bool ?? false, "status": response["status"] ?? NSNull(), "error": response["error"] ?? NSNull()]
    }

    /// Terminate and wait until gone (5 s), so every launch is a cold one.
    private static func quitSystemSettings() async -> [String: Any] {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsBundleIdentifier)
        guard !running.isEmpty else { return ["wasRunning": false] }
        let start = uptime
        running.forEach { $0.terminate() }
        while running.contains(where: { !$0.isTerminated }), uptime - start < 5 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ["wasRunning": true, "gone": running.allSatisfy(\.isTerminated), "quitMs": milliseconds(from: start, to: uptime) ?? 0]
    }

    // MARK: Summary

    /// `answers` are what the model said, one per run; only counts leave this
    /// function, so the log still carries no model text.
    static func summary(for lines: [[String: Any]], answers: [String], stack: VoiceStackChoice, probeID: String, spentUSD: Double?) -> [String: Any] {
        var marks: [String: Any] = [:]
        for markName in ["sessionSetupMs", "firstAudioMs", "toolCallMs", "harnessMs", "freshLookMs", "freshLookArrivedAfterSpeechStartMs", "followUpFirstAudioMs",
                         "totalToFirstSpokenResultMs", "firstAudioBeforeToolMs", "intentLeadMs"] {
            let values = lines.map { ($0["marksMs"] as? [String: Any])?[markName] as? Int }
            if let distribution = VoiceBenchStatistics.distribution(of: values) {
                marks[markName] = ["n": distribution.count, "medianMs": distribution.medianMs, "p95Ms": distribution.p95Ms]
            } else {
                marks[markName] = NSNull()
            }
        }
        var outcomeCounts: [String: Int] = [:]
        var errorKindCounts: [String: Int] = [:]
        var freshLookCounts: [String: Int] = [:]
        for line in lines {
            freshLookCounts[(line["freshLook"] as? String) ?? "notAttempted", default: 0] += 1
            let outcome = (line["harnessStatus"] as? String) ?? (line["harnessError"] as? String) ?? "noTool"
            outcomeCounts[outcome, default: 0] += 1
            if let errorKind = line["errorKind"] as? String { errorKindCounts[errorKind, default: 0] += 1 }
        }
        func count(_ key: String) -> Int { lines.filter { $0[key] as? Bool == true }.count }
        return [
            "kind": "summary", "probeId": probeID, "stack": stack.rawValue, "runs": lines.count,
            "toolCalled": count("toolCalled"),
            "harnessOutcomes": outcomeCounts,
            "freshLookOutcomes": freshLookCounts,
            "intentShownBeforeLaunchRequest": count("intentShownBeforeLaunchRequest"),
            "proofShown": count("proofShown"),
            "didntTakeShown": count("didntTakeShown"),
            "proofViolations": lines.reduce(0) { $0 + (($1["proofViolations"] as? Int) ?? 0) },
            "frontmostUnchangedByNotch": count("frontmostUnchangedByNotch"),
            "systemSettingsFrontmost": count("systemSettingsFrontmost"),
            "claimedSuccessWithoutReceipt": count("claimedSuccessWithoutReceipt"),
            "toolSkipped": count("toolSkipped"),
            "verbatimExampleReuse": answers.filter(RealtimeOpenAppTool.reusesExampleVerbatim).count,
            "templateReuse": answers.filter(RealtimeOpenAppTool.reusesExampleTemplate).count,
            "answerVariety": Set(answers.map(RealtimeOpenAppTool.normalisedAnswer)).count,
            "repliedToFreshLook": lines.filter { ($0["audioChunksAfterFinish"] as? Int ?? 0) > 0 }.count,
            "errorKinds": errorKindCounts,
            "marksMs": marks,
            "estimatedCostUSD": spentUSD ?? NSNull()
        ]
    }
}
