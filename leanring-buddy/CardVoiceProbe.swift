//
//  CardVoiceProbe.swift
//  leanring-buddy
//
//  `--notch-probe --card-voice-probe --harness-dry-run`: one voice around an
//  approval card, measured on the real realtime model with nobody speaking.
//  The live session (`RealtimeVoiceSession`, probe mode: no mic, no screenshot,
//  nothing heard aloud) takes the committed "open settings" fixture; a STUB
//  harness answers its launch with a ticket, keeps it pending, then answers it
//  after a set delay — denied, allowed fast (before the model's ask can play),
//  or expired. Nothing is launched and no card is drawn: the stub never reaches
//  the real harness. What it measures, from the release: when the model was
//  handed the card, when its ask began, when the card was answered, whether the
//  ask was cut, and when the outcome line was said and what it said.
//
//  Per run, one JSON line to ~/Library/Logs/Clicky/card-voice-probe.log (0600,
//  with what was said); the session's own lines to card-voice-probe-live.log.
//  Needs 120 s of owner idle (`NotchProbe`). Spends Gemini credit (and OpenAI's,
//  when `--notch-probe-stacks` names it).
//

import Foundation

@MainActor
enum CardVoiceProbe {
    static let logFileName = "card-voice-probe.log"
    static let liveTurnLogFileName = "card-voice-probe-live.log"

    struct Variant {
        let name: String
        let answerAfterSeconds: Double
        let answerLine: String
    }

    static let variants = [
        Variant(name: "deny", answerAfterSeconds: 6, answerLine: #"{"ok":false,"error":"confirmationDenied","message":"the owner denied it"}"#),
        // Owner's live click 2026-10-31 12:15:08Z came 1.43 s after the card: before the model's ask could play.
        Variant(name: "allowFast", answerAfterSeconds: 1.2,
                answerLine: #"{"ok":true,"status":"ready","bundleIdentifier":"com.apple.systempreferences","message":"launched"}"#),
        Variant(name: "expire", answerAfterSeconds: 8, answerLine: #"{"ok":false,"error":"confirmationExpired","message":"the card expired"}"#)
    ]

    /// The card's clock, shared with the stub (which runs off main).
    final class StubTicket: @unchecked Sendable {
        private let lock = NSLock()
        private let variant: Variant
        private(set) var cardUptime: TimeInterval?
        private(set) var answeredUptime: TimeInterval?
        init(_ variant: Variant) { self.variant = variant }

        func answer(_ line: String) -> String {
            lock.lock(); defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            guard line.contains("\"ticket\"") else {
                guard line.contains("\"launch\"") else { return #"{"ok":false,"error":"dryRun","message":"card probe: only the launch is answered"}"# }
                if cardUptime == nil { cardUptime = now }
                return #"{"ok":false,"error":"confirmationRequired","ticket":"PROBE","message":"needs the owner's click"}"#
            }
            guard let shown = cardUptime, now - shown >= variant.answerAfterSeconds else { return #"{"ok":false,"error":"confirmationPending"}"# }
            if answeredUptime == nil { answeredUptime = now }
            return variant.answerLine
        }
        var times: (card: TimeInterval?, answered: TimeInterval?) { lock.lock(); defer { lock.unlock() }; return (cardUptime, answeredUptime) }
    }

    static func run(stacks: [VoiceStackChoice]) async {
        let probeID = UUID().uuidString
        guard let (clip16k, clip24k) = VoiceToolProbe.clips(forFixture: VoiceToolProbe.fixtureFileName) else {
            MeasurementLogFile.appendJSONLine(["kind": "fixtureUnreadable", "probeId": probeID], toFileNamed: logFileName)
            return
        }
        for stack in stacks {
            for variant in variants {
                let line = await runOnce(stack: stack, variant: variant, clip: stack == .openAIRealtime ? clip24k : clip16k, probeID: probeID)
                MeasurementLogFile.appendJSONLine(line, toFileNamed: logFileName)
                print("🧪 card probe: \(stack.rawValue) \(variant.name): \(line["verdict"] ?? "?")")
            }
        }
    }

    private static func runOnce(stack: VoiceStackChoice, variant: Variant, clip: VoiceBenchPCMClip, probeID: String) async -> [String: Any] {
        let ticket = StubTicket(variant)
        let session = RealtimeVoiceSession(harnessAnswer: { ticket.answer($0) })
        session.probeMode = true
        session.stackOverride = stack
        session.liveTurnLogFileName = liveTurnLogFileName
        final class Box { var marks: RealtimeTurnMarks?; var said: RealtimeTurnMarks?; var saidDone = false; var lineWritten = false }
        let box = Box()
        session.onLiveTurnLine = { _ in box.lineWritten = true }
        session.onLiveTurnMarks = { box.marks = $0 }
        session.onCardOutcomeSaid = { box.said = $0; box.saidDone = true }
        defer { session.stop() }
        session.prewarm()
        try? await Task.sleep(for: .seconds(3))

        session.pressed()
        let chunkMilliseconds = VoiceStackBenchmark.audioChunkMilliseconds
        let clock = ContinuousClock()
        let start = clock.now
        for (index, chunk) in clip.chunks(milliseconds: chunkMilliseconds).enumerated() {
            try? await clock.sleep(until: start + .milliseconds(chunkMilliseconds * index), tolerance: nil)
            session.feedProbeAudio(chunk)
        }
        session.released()
        let released = ProcessInfo.processInfo.systemUptime
        let deadline = released + 45
        while !box.saidDone, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(50)) }

        func ms(_ uptime: TimeInterval?) -> Any { uptime.map { Int((($0 - released) * 1000).rounded()) } ?? NSNull() }
        let marks = box.marks
        let times = ticket.times
        let askStarted = marks?.followUpFirstAudioUptime
        let handedOff = marks?.cardAskedUptime
        // The defects of 2026-10-31: the model's ask arriving only after the answer, and anything asking again after it.
        let askAfterAnswer = askStarted.flatMap { started in times.answered.map { started > $0 } } ?? false
        let outcomeSaid = box.said?.transcript ?? ""
        let asksAgain = ["click", "approve", "approval", "allow"].contains { outcomeSaid.lowercased().contains($0) }
            && !["denied", "declined", "expired", "allowed", "did not", "didn't"].contains { outcomeSaid.lowercased().contains($0) }
        let verdict: String
        if handedOff == nil { verdict = "noHandOff" } else if !box.saidDone { verdict = "outcomeNotTold" }
        else if box.said == nil { verdict = "outcomeToldNotSaid" } else { verdict = "ok" }
        return [
            "kind": "run", "probeId": probeID, "stack": stack.rawValue, "variant": variant.name,
            "verdict": verdict, "turnLineWritten": box.lineWritten,
            "cardShownMs": ms(times.card), "handedOffMs": ms(handedOff), "askFirstAudioMs": ms(askStarted),
            "answeredMs": ms(times.answered), "askBeganAfterAnswer": askAfterAnswer,
            "askMuted": marks?.replyMuted ?? NSNull(), "askFinishedMs": ms(marks?.finishedUptime),
            "outcomeFirstAudioMs": ms(box.said?.firstAudioUptime), "outcomeFinishedMs": ms(box.said?.finishedUptime),
            "outcomeAsksAgain": asksAgain,
            "askSaid": marks?.transcript ?? NSNull(), "outcomeSaid": box.said?.transcript ?? NSNull(),
            "decisions": (marks?.decisions ?? []).map { "\($0.call.name):\($0.dispatch?.result["error"] as? String ?? "ok")" }
        ]
    }
}
