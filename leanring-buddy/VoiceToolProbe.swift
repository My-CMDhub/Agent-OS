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
//  System Settings is quit before every run so each launch is real, and whether
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
    static let runsPerStack = 5
    static let openAICostCapUSD = 0.50
    static let fixtureFileName = "05-open-settings.wav"
    static let systemSettingsBundleIdentifier = "com.apple.systempreferences"
    /// A tool call may wait on a 60 s confirmation ticket, plus the answer after it.
    static let turnTimeoutSeconds: Double = 90

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func appendLine(_ lineObject: [String: Any]) {
        MeasurementLogFile.appendJSONLine(lineObject, toFileNamed: logFileName)
    }

    private static func milliseconds(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
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

        let fixture16kData = try? Data(contentsOf: VoiceStackBenchmark.fixtureDirectoryURL.appendingPathComponent(fixtureFileName))
        guard let fixture16kData, let clip16k = VoiceBenchPCMClip.parseWAV(fixture16kData), clip16k.sampleRate == 16_000,
              case .success(let clip24k) = VoiceBenchPCMClip.paired24kClip(
                fileData: try? Data(contentsOf: VoiceStackBenchmark.fixture24kDirectoryURL.appendingPathComponent(fixtureFileName)),
                matching: clip16k) else {
            appendLine(["kind": "fixtureUnreadable", "probeId": probeID, "fixture": fixtureFileName])
            print("🧪 voice tool probe: fixture unreadable -> \(logPath)")
            return
        }

        // One screenshot for every run, as the bench does.
        guard let screenshot = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen) else {
            appendLine(["kind": "captureFailed", "probeId": probeID])
            print("🧪 voice tool probe: capture failed -> \(logPath)")
            return
        }

        appendLine([
            "kind": "start", "probeId": probeID, "fixture": fixtureFileName, "runsPerStack": runsPerStack,
            "openAICostCapUSD": openAICostCapUSD, "imageBytes": screenshot.imageData.count,
            "harnessSession": HarnessServer.sessionIdentifier
        ])
        let answersFile = VoiceStackBenchmark.openOwnerOnlyAnswersFile(
            at: MeasurementLogFile.directoryURL.appendingPathComponent("voice-tool-probe-answers-\(probeID).jsonl"))
        defer { try? answersFile?.close() }

        // `--voice-tool-probe-stacks=geminiLive` re-runs one stack without paying for the other.
        let stacksArgument = CommandLine.arguments.first { $0.hasPrefix("--voice-tool-probe-stacks=") }
        let selectedStacks = stacksArgument.map { argument in
            argument.dropFirst("--voice-tool-probe-stacks=".count).split(separator: ",").compactMap { VoiceStackChoice(rawValue: String($0)) }
        } ?? VoiceStackChoice.allCases
        let harnessAnswer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        var openAISpentUSD = 0.0
        var runLines: [VoiceStackChoice: [[String: Any]]] = [:]

        for runNumber in 1...runsPerStack {
            // Alternating first stack, so neither always inherits a warm network path.
            let order: [VoiceStackChoice] = runNumber % 2 == 1 ? [.openAIRealtime, .geminiLive] : [.geminiLive, .openAIRealtime]
            for stack in order where selectedStacks.contains(stack) {
                if stack == .openAIRealtime, openAISpentUSD > openAICostCapUSD { continue }
                let clip = stack == .openAIRealtime ? clip24k : clip16k
                let (line, transcript, spentUSD) = await measureOneRun(
                    stack: stack, runNumber: runNumber, probeID: probeID, clip: clip,
                    screenshotJPEG: screenshot.imageData, harnessAnswer: harnessAnswer)
                if stack == .openAIRealtime { openAISpentUSD += spentUSD }
                appendLine(line)
                runLines[stack, default: []].append(line)
                if let answersFile, let answerLine = MeasurementLogFile.jsonLine([
                    "probeId": probeID, "stack": stack.rawValue, "run": runNumber, "said": transcript
                ]) {
                    try? answersFile.write(contentsOf: Data((answerLine + "\n").utf8))
                }
                print("🧪 voice tool probe: \(stack.rawValue) #\(runNumber) \(line["errorKind"] ?? "ok") tool=\(line["toolCalled"] ?? "-") status=\(line["harnessStatus"] ?? "-")")
            }
        }

        for stack in selectedStacks {
            appendLine(summary(for: runLines[stack] ?? [], stack: stack, probeID: probeID,
                               spentUSD: stack == .openAIRealtime ? openAISpentUSD : nil))
        }
        print("🧪 voice tool probe: finished (OpenAI estimated US$\(openAISpentUSD)) -> \(logPath)")
    }

    // MARK: One run

    private static func measureOneRun(
        stack: VoiceStackChoice, runNumber: Int, probeID: String, clip: VoiceBenchPCMClip,
        screenshotJPEG: Data, harnessAnswer: @escaping @Sendable (String) -> String
    ) async -> (line: [String: Any], transcript: String, spentUSD: Double) {
        var line: [String: Any] = ["kind": "run", "probeId": probeID, "stack": stack.rawValue, "run": runNumber]
        line["systemSettingsQuit"] = await quitSystemSettings()

        let connection = RealtimeVoiceConnection(stack: stack, harnessAnswer: harnessAnswer)
        defer { connection.close() }
        var marks: [String: Any] = [:]
        var errorKind: String?
        do {
            let setupStart = uptime
            try await connection.connect()
            try await connection.sendScreenshot(screenshotJPEG)
            marks["sessionSetupMs"] = milliseconds(from: setupStart, to: uptime)
            try await connection.beginTurn()
            let clock = ContinuousClock()
            let streamStart = clock.now
            for (chunkIndex, chunk) in clip.chunks(milliseconds: VoiceStackBenchmark.audioChunkMilliseconds).enumerated() {
                try await clock.sleep(until: streamStart + .milliseconds(VoiceStackBenchmark.audioChunkMilliseconds * chunkIndex), tolerance: nil)
                try await connection.appendAudio(chunk)
            }
            try await connection.endTurn()
            _ = try await connection.turn.finished.value(timeoutSeconds: turnTimeoutSeconds, timeoutKind: "turnTimeout")
        } catch {
            errorKind = (error as? VoiceBenchFailure)?.kind ?? VoiceBenchRun.errorKind(for: error, stage: stack.rawValue)
        }

        // Independent witness, after the app has had a moment to come forward.
        try? await Task.sleep(for: .milliseconds(500))
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let turn = connection.turn
        let released = turn.lastAudioSentUptime
        let firstDispatch = turn.dispatches.first
        let harnessConfirmed = turn.dispatches.contains(where: \.harnessConfirmed)
        marks["firstAudioMs"] = milliseconds(from: released, to: turn.firstAudioUptime)
        marks["toolCallMs"] = milliseconds(from: released, to: turn.toolCallUptime)
        marks["harnessMs"] = firstDispatch?.harnessMilliseconds
        marks["freshLookMs"] = turn.freshLookMilliseconds
        marks["followUpFirstAudioMs"] = milliseconds(from: turn.toolResultSentUptime, to: turn.followUpFirstAudioUptime)
        marks["totalToFirstSpokenResultMs"] = milliseconds(from: released, to: turn.followUpFirstAudioUptime)
        if let firstAudio = turn.firstAudioUptime, firstAudio < (turn.toolCallUptime ?? .infinity), turn.toolCallUptime != nil {
            marks["firstAudioBeforeToolMs"] = milliseconds(from: released, to: firstAudio)
        }

        line["marksMs"] = marks
        line["toolCalled"] = !turn.toolCalls.isEmpty
        line["toolCalls"] = turn.toolCalls.map { ["name": $0.name, "app": ($0.appName ?? NSNull()) as Any] }
        line["toolResults"] = turn.dispatches.map(\.result)
        line["harnessStatus"] = (firstDispatch?.result["status"] as? String) ?? NSNull()
        line["harnessError"] = (firstDispatch?.result["error"] as? String) ?? NSNull()
        line["harnessConfirmed"] = harnessConfirmed
        line["freshLook"] = turn.freshLookOutcome ?? NSNull()
        line["freshLookImageBytes"] = turn.freshLookImageBytes ?? NSNull()
        line["waitedForConfirmation"] = turn.dispatches.contains(where: \.waitedForConfirmation)
        line["frontmostBundleIdentifier"] = frontmostBundleIdentifier ?? NSNull()
        line["systemSettingsFrontmost"] = frontmostBundleIdentifier == systemSettingsBundleIdentifier
        line["claimedSuccessWithoutConfirmation"] = RealtimeOpenAppTool.claimedSuccessWithoutConfirmation(
            transcript: turn.transcript, harnessConfirmed: harnessConfirmed)
        line["spokenCharacters"] = turn.transcript.count
        line["outputAudioMime"] = turn.outputAudioMime ?? NSNull()
        line["eventTrail"] = turn.eventTrail
        line["errorKind"] = errorKind ?? NSNull()
        let spentUSD = stack == .openAIRealtime ? connection.estimatedOpenAIUSD : 0
        if stack == .openAIRealtime { line["estimatedCostUSD"] = spentUSD }
        return (line, turn.transcript, spentUSD)
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

    static func summary(for lines: [[String: Any]], stack: VoiceStackChoice, probeID: String, spentUSD: Double?) -> [String: Any] {
        var marks: [String: Any] = [:]
        for markName in ["sessionSetupMs", "firstAudioMs", "toolCallMs", "harnessMs", "freshLookMs", "followUpFirstAudioMs",
                         "totalToFirstSpokenResultMs", "firstAudioBeforeToolMs"] {
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
            "systemSettingsFrontmost": count("systemSettingsFrontmost"),
            "claimedSuccessWithoutConfirmation": count("claimedSuccessWithoutConfirmation"),
            "errorKinds": errorKindCounts,
            "marksMs": marks,
            "estimatedCostUSD": spentUSD ?? NSNull()
        ]
    }
}
