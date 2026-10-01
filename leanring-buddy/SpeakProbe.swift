//
//  SpeakProbe.swift
//  leanring-buddy
//
//  `--speak-probe`: does each provider SPEAK to a turn the owner did not speak
//  (`RealtimeVoiceConnection.beginSystemTurn`), and does the owner's press still
//  win over it? The Guided session says "Good. Now click Activity" the moment a
//  step is done, with no key press; today a reply only follows the owner's audio.
//
//  Per stack x distinct variant x 5 runs, a fresh connection, no screenshot:
//  first audio, finish, how long the answer was and whether it named Activity.
//  Then per stack, 3 barge-ins on the variant that spoke best: at the system
//  turn's first audio the owner "presses" (`supersedeForPress`, `beginTurn`, a
//  fixture, `endTurn`); any audio delivered between the press and the release is
//  stale (must be 0), and the owner's turn must finish with audio of its own.
//
//  Safety: every tool call is refused by a stub that never reaches the harness,
//  `--harness-dry-run` must be on, nothing is played aloud, no window is opened,
//  focused or moved. Runs only after 120 s of no keyboard or mouse input and
//  stops the moment either comes back. Counts to speak-probe.log; what the model
//  said only to speak-probe-detail.log (0600). Spends OpenAI (capped) and Gemini credit.
//

import AppKit
import Foundation

@MainActor
enum SpeakProbe {
    static let logFileName = "speak-probe.log"
    static let detailLogFileName = "speak-probe-detail.log"
    static let runsPerVariant = 5
    static let bargeInRuns = 3
    static let replyTimeoutSeconds: Double = 8
    static let openAICostCapUSD = 0.50
    static let ownerFixtureFileName = "01-what-app.wav"
    static let systemTurnText = "System event, not the owner: the owner opened their profile. In one short sentence, tell them to click the Activity tab."

    /// Only the variants that send different messages on that stack (`systemTurnMessages`).
    static func variants(for stack: VoiceStackChoice) -> [RealtimeSystemTurnVariant] {
        switch stack {
        case .openAIRealtime: [.textOnly, .textThenCreate]
        case .geminiLive: [.textOnly, .clientContent]
        }
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func appendLine(_ lineObject: [String: Any]) {
        MeasurementLogFile.appendJSONLine(lineObject, toFileNamed: logFileName)
    }

    private static func ms(_ start: TimeInterval?, _ end: TimeInterval?) -> Any {
        VoiceToolProbe.milliseconds(from: start, to: end) ?? NSNull()
    }

    static func run() async {
        defer { MeasurementLogFile.waitForPendingWrites() }
        let probeID = UUID().uuidString
        let logPath = MeasurementLogFile.directoryURL.appendingPathComponent(logFileName).path
        guard CommandLine.arguments.contains("--harness-dry-run") else {
            appendLine(["kind": "refused", "probeId": probeID, "reason": "needs --harness-dry-run"])
            print("🧪 speak probe: refused, needs --harness-dry-run -> \(logPath)")
            return
        }
        guard WorkerConfiguration.isConfigured else {
            appendLine(["kind": "notConfigured", "probeId": probeID])
            return
        }
        let startUptime = uptime
        let idle = await Task.detached { NotchProbe.hidIdleSeconds() }.value
        guard let idle, idle >= NotchProbe.requiredIdleSeconds else {
            appendLine(["kind": "ownerActive", "probeId": probeID, "hidIdleSeconds": idle ?? NSNull()])
            print("🧪 speak probe: owner active, not running -> \(logPath)")
            return
        }
        /// The probe posts no input, so idle shorter than the run means the owner is back.
        func ownerIsBack() async -> Bool {
            let now = uptime
            guard let idle = await Task.detached(operation: { NotchProbe.hidIdleSeconds() }).value else { return true }
            return idle < now - startUptime - 1
        }
        guard let (clip16k, clip24k) = VoiceToolProbe.clips(forFixture: ownerFixtureFileName) else {
            appendLine(["kind": "fixtureUnreadable", "probeId": probeID, "fixture": ownerFixtureFileName])
            return
        }
        appendLine(["kind": "start", "probeId": probeID, "hidIdleSeconds": idle, "runsPerVariant": runsPerVariant, "bargeInRuns": bargeInRuns])

        var openAISpentUSD = 0.0
        stackLoop: for stack in VoiceStackChoice.allCases {
            var best: (variant: RealtimeSystemTurnVariant, replied: Int, medianMs: Int)?
            for variant in variants(for: stack) {
                var firstAudio: [Int?] = []
                var replied = 0
                for runNumber in 1...runsPerVariant {
                    if await ownerIsBack() { appendLine(["kind": "ownerReturned", "probeId": probeID]); break stackLoop }
                    if stack == .openAIRealtime, openAISpentUSD > openAICostCapUSD {
                        appendLine(["kind": "costCapReached", "probeId": probeID, "spentUSD": openAISpentUSD]); break stackLoop
                    }
                    let connection = RealtimeVoiceConnection(stack: stack, harnessAnswer: NotchProbe.refusingHarnessAnswer)
                    var errorKind: String?
                    do {
                        try await connection.connect()
                        try await connection.beginSystemTurn(text: systemTurnText, variant: variant)
                        _ = try await connection.turn.finished.value(timeoutSeconds: replyTimeoutSeconds, timeoutKind: "replyTimeout")
                    } catch {
                        errorKind = (error as? VoiceBenchFailure)?.kind ?? String(describing: type(of: error))
                    }
                    let turn = connection.turn
                    connection.close()
                    if stack == .openAIRealtime { openAISpentUSD += connection.estimatedOpenAIUSD }
                    let firstAudioMs = VoiceToolProbe.milliseconds(from: turn.lastAudioSentUptime, to: turn.firstAudioUptime)
                    if firstAudioMs != nil { replied += 1 }
                    firstAudio.append(firstAudioMs)
                    let lineID = UUID().uuidString
                    appendLine(["kind": "run", "probeId": probeID, "lineId": lineID, "stack": stack.rawValue, "variant": variant.rawValue,
                                "run": runNumber, "firstAudioMs": firstAudioMs ?? NSNull(), "finishedMs": ms(turn.lastAudioSentUptime, turn.finishedUptime),
                                "saidLength": turn.transcript.count, "saidMentionsActivity": turn.transcript.lowercased().contains("activity"),
                                "toolCalls": turn.toolCalls.count, "errorKind": errorKind ?? NSNull(), "eventTrail": turn.eventTrail])
                    MeasurementLogFile.appendJSONLine(["probeId": probeID, "lineId": lineID, "said": turn.transcript], toFileNamed: detailLogFileName)
                }
                let distribution = VoiceBenchStatistics.distribution(of: firstAudio)
                appendLine(["kind": "summary", "probeId": probeID, "stack": stack.rawValue, "variant": variant.rawValue,
                            "replied": "\(replied)/\(firstAudio.count)", "medianFirstAudioMs": distribution?.medianMs ?? NSNull()])
                if replied > 0, let median = distribution?.medianMs,
                   best == nil || replied > best!.replied || (replied == best!.replied && median < best!.medianMs) {
                    best = (variant, replied, median)
                }
            }
            guard let best else {
                appendLine(["kind": "bargeInSkipped", "probeId": probeID, "stack": stack.rawValue, "reason": "noVariantSpoke"])
                continue
            }
            for runNumber in 1...bargeInRuns {
                if await ownerIsBack() { appendLine(["kind": "ownerReturned", "probeId": probeID]); break stackLoop }
                let record = await bargeIn(stack: stack, variant: best.variant, clip: stack == .openAIRealtime ? clip24k : clip16k)
                if stack == .openAIRealtime { openAISpentUSD += record["spentUSD"] as? Double ?? 0 }
                appendLine(record.merging(["kind": "bargeIn", "probeId": probeID, "run": runNumber]) { _, new in new })
            }
        }
        appendLine(["kind": "end", "probeId": probeID, "estimatedOpenAIUSD": openAISpentUSD])
        print("🧪 speak probe: finished (OpenAI estimated US$\(openAISpentUSD)) -> \(logPath)")
    }

    /// One system turn cut off at its first audio by an owner turn.
    private static func bargeIn(stack: VoiceStackChoice, variant: RealtimeSystemTurnVariant, clip: VoiceBenchPCMClip) async -> [String: Any] {
        let connection = RealtimeVoiceConnection(stack: stack, harnessAnswer: NotchProbe.refusingHarnessAnswer)
        defer { connection.close() }
        var audioBetweenPressAndRelease = 0
        var pressed = false
        var released = false
        connection.onAudio = { _ in if pressed, !released { audioBetweenPressAndRelease += 1 } }
        var record: [String: Any] = ["stack": stack.rawValue, "variant": variant.rawValue]
        do {
            try await connection.connect()
            try await connection.beginSystemTurn(text: systemTurnText, variant: variant)
            let deadline = uptime + replyTimeoutSeconds
            while connection.turn.firstAudioUptime == nil, uptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
            record["systemTurnSpoke"] = connection.turn.firstAudioUptime != nil
            pressed = true
            connection.supersedeForPress()
            try await connection.beginTurn()
            let clock = ContinuousClock()
            let streamStart = clock.now
            for (chunkIndex, chunk) in clip.chunks(milliseconds: VoiceStackBenchmark.audioChunkMilliseconds).enumerated() {
                try await clock.sleep(until: streamStart + .milliseconds(VoiceStackBenchmark.audioChunkMilliseconds * chunkIndex), tolerance: nil)
                try await connection.appendAudio(chunk)
            }
            released = true
            try await connection.endTurn()
            _ = try await connection.turn.finished.value(timeoutSeconds: VoiceToolProbe.turnTimeoutSeconds, timeoutKind: "turnTimeout")
        } catch {
            record["errorKind"] = (error as? VoiceBenchFailure)?.kind ?? String(describing: type(of: error))
        }
        let owner = connection.turn
        record["staleAudioAfterPress"] = audioBetweenPressAndRelease
        record["ownerFinished"] = owner.finishedUptime != nil
        record["ownerFirstAudioMs"] = ms(owner.lastAudioSentUptime, owner.firstAudioUptime)
        record["ownerTurnHadOwnAudio"] = (VoiceToolProbe.milliseconds(from: owner.lastAudioSentUptime, to: owner.firstAudioUptime) ?? -1) > 0
        record["staleCompletionsIgnored"] = owner.staleCompletionsIgnored
        record["eventTrail"] = owner.eventTrail
        if stack == .openAIRealtime { record["spentUSD"] = connection.estimatedOpenAIUSD }
        return record
    }
}
