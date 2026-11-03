//
//  CardAskProbe.swift
//  leanring-buddy
//
//  `--card-ask-probe`: exactly one spoken ask per real card, with nobody there.
//  Real harness, real ticket, real drawn card, the real nudge timer, real Haiku
//  steps, and a real Gemini session:
//   - voiceThenTask: the fixture K1 spoken into the session: the model calls do_task,
//     says its few words, and the task's first step raises a card.
//   - directTask: the session's do_task with nothing being said when the card shows.
//   - noSession: the same task with no session at all: the Deepgram clip, twice.
//  Cards are denied (in process, the runner's way), never allowed; the first two
//  outlive the voice's grace first, so a clip that should not fire would have.
//
//  The witness for "one voice" is not the code's own word: an audio-only SCStream
//  hears what this process really sent to the output, and every burst is listed in ms
//  from the card (replies are made audible here, unlike the other probes). The chime
//  is one short burst at 0. Scoped to this app: the first run's whole-display mix
//  heard something else playing on the machine for 25 s.
//
//  One JSON line per case to ~/Library/Logs/Clicky/card-ask-probe.log; the decisions
//  in confirmation-nudge.jsonl. Same gate as the runner (120 s idle, no dry run).
//  Spends a little Gemini and Claude credit. The goal only ever reaches the card.
//

import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// This process's audio output as 100 ms peak buckets.
final class SystemAudioWitness: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buckets: [Int: Float] = [:]
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "card-ask-probe.audio")

    func start() async -> String? {
        do {
            // Not `.current`: on-screen windows only, and this app has none until its card shows.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return "noDisplay" }
            let pid = ProcessInfo.processInfo.processIdentifier
            guard let own = content.applications.first(where: { $0.processID == pid }) else { return "ownAppNotListed" }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.channelCount = 1
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, including: [own], exceptingWindows: []), configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            return nil
        } catch { return "\(error)" }
    }

    func stop() async { try? await stream?.stopCapture() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return }
        let peak = pointer.withMemoryRebound(to: Float32.self, capacity: length / 4) { samples in
            (0..<(length / 4)).reduce(Float(0)) { max($0, abs(samples[$1])) }
        }
        let bucket = Int(ProcessInfo.processInfo.systemUptime * 10)
        lock.lock()
        buckets[bucket] = max(buckets[bucket] ?? 0, peak)
        lock.unlock()
    }

    /// Runs of sound in ms from `origin`, joined across gaps under 400 ms (a sentence's pauses).
    func bursts(from origin: TimeInterval, until end: TimeInterval) -> [[String: Any]] {
        lock.lock()
        let heard = buckets.filter { $0.value > 0.005 }
        lock.unlock()
        var runs: [(start: Int, end: Int, peak: Float)] = []
        for bucket in heard.keys.sorted() where Double(bucket) / 10 >= origin - 1 && Double(bucket) / 10 <= end {
            if let last = runs.last, bucket - last.end <= 4 {
                runs[runs.count - 1] = (last.start, bucket, max(last.peak, heard[bucket] ?? 0))
            } else {
                runs.append((bucket, bucket, heard[bucket] ?? 0))
            }
        }
        return runs.map { ["fromMs": Int((Double($0.start) / 10 - origin) * 1000), "toMs": Int((Double($0.end + 1) / 10 - origin) * 1000), "peak": Double($0.peak)] }
    }
}

@MainActor
enum CardAskProbe {
    static let logFileName = "card-ask-probe.log"
    static let goal = "open script editor and tell me what version it is"
    /// Past the voice's grace, so a clip that should not fire would have.
    static let denyWithSessionSeconds = 9.0
    /// Past the second nudge.
    static let denyWithoutSessionSeconds = 28.0

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func run(harness: HarnessServer, confirmations: HarnessConfirmations) async {
        func log(_ line: [String: Any]) { MeasurementLogFile.appendJSONLine(line, toFileNamed: logFileName) }
        if let refusal = ScenarioRunner.refusalToStart() {
            log(["kind": "refused", "reason": refusal])
            MeasurementLogFile.waitForPendingWrites()
            return
        }
        let witness = SystemAudioWitness()
        let witnessError = await witness.start()
        log(["kind": "start", "witnessError": witnessError ?? NSNull(), "voice": CascadeDeepgram.voice,
             "clipsCached": ConfirmationClips.cached(.first).count + ConfirmationClips.cached(.second).count])
        // Rendering at launch may still be under way; the first card of a real first run stays silent instead.
        try? await Task.sleep(for: .seconds(5))
        let answer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        for name in ["voiceThenTask", "directTask", "noSession"] {
            log(await runCase(name, answer: answer, confirmations: confirmations, witness: witness))
            MeasurementLogFile.waitForPendingWrites()
            try? await Task.sleep(for: .seconds(4))
        }
        await witness.stop()
        MeasurementLogFile.waitForPendingWrites()
    }

    private static func runCase(_ name: String, answer: @escaping @Sendable (String) -> String, confirmations: HarnessConfirmations,
                                witness: SystemAudioWitness) async -> [String: Any] {
        let started = Date()
        var session: RealtimeVoiceSession?
        var loop: AgentLoop?
        var loopTask: Task<Void, Never>?
        var heardTurn = false
        final class Box { var finished = false; var report: AgentLoopReport? }
        let box = Box()
        if name == "noSession" {
            let bare = AgentLoop.live(heard: goal, harnessAnswer: answer, model: AgentLoopModel()) { _ in }
            loop = bare
            loopTask = Task { @MainActor in
                _ = await bare.run(goal: goal, heard: goal)
                box.finished = true
            }
        } else {
            let live = RealtimeVoiceSession(harnessAnswer: answer)
            live.fixtureMic = true
            live.playRepliesAloudForProbe()
            live.interruptedOffer = nil
            live.stackOverride = .geminiLive
            live.liveTurnLogFileName = "card-ask-probe-live.log"
            live.onAgentLoopFinished = { box.report = $0; box.finished = true }
            session = live
            live.prewarm()
            try? await Task.sleep(for: .seconds(3))
            if name == "voiceThenTask" {
                guard case .success(let pair) = ScenarioRunner.clips(for: "K1", utterances: ScenarioRunner.loadUtterances()) else {
                    live.stop()
                    return ["kind": "case", "case": name, "verdict": "fixtureUnreadable"]
                }
                live.pressed()
                let clock = ContinuousClock()
                let streamStart = clock.now
                let chunkMs = VoiceStackBenchmark.audioChunkMilliseconds
                for (index, chunk) in pair.clip16k.chunks(milliseconds: chunkMs).enumerated() {
                    try? await clock.sleep(until: streamStart + .milliseconds(chunkMs * index), tolerance: nil)
                    live.feedProbeAudio(chunk)
                }
                live.released()
                heardTurn = true
            } else {
                live.startTaskForProbe(goal: goal)
            }
        }
        defer { session?.stop() }

        // The ask, read while the card is up (it is cleared with the card).
        var card: [String: Any] = [:]
        var cardUptime: TimeInterval?
        var askTurn: RealtimeTurnMarks?
        var denied = false
        let denyAfter = name == "noSession" ? denyWithoutSessionSeconds : denyWithSessionSeconds
        var photographed = false
        let deadline = uptime + 90
        while !box.finished, uptime < deadline {
            if let shown = ConfirmationNudger.cardShownUptime { cardUptime = cardUptime ?? shown }
            if let turn = ConfirmationNudger.voiceAskTurn { askTurn = turn }
            if let ticket = confirmations.tickets.last(where: { $0.createdAt >= started && HarnessConfirmations.status(of: $0, now: Date()) == .pending }) {
                card["verb"] = ticket.verb
                card["question"] = ticket.cardLines.first?.text ?? NSNull()
                if !photographed, Date().timeIntervalSince(ticket.createdAt) >= 1 {
                    photographed = true
                    let file = MeasurementLogFile.directoryURL.appendingPathComponent("card-ask-probe-\(name).png")
                    card["drawn"] = AgentLoopProbe.photographCard(to: file) ?? NSNull()
                }
                if Date().timeIntervalSince(ticket.createdAt) >= denyAfter {
                    confirmations.answer(ticket.id, allow: false, scope: .once)
                    denied = true
                    card["deniedAfterMs"] = Int(Date().timeIntervalSince(ticket.createdAt) * 1000)
                }
            }
            // Without a session the loop's end is the flag; with one it is the report.
            if denied, name == "noSession" { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // The outcome line (told) and the final line play out.
        try? await Task.sleep(for: .seconds(name == "noSession" ? 3 : 6))
        _ = loop
        loopTask?.cancel()
        let end = uptime
        var line: [String: Any] = ["kind": "case", "case": name, "voiceTurnSpoken": heardTurn, "taskFinished": box.finished, "denied": denied, "card": card]
        func ms(_ value: TimeInterval?) -> Any { value.flatMap { value in cardUptime.map { Int(((value - $0) * 1000).rounded()) } } ?? NSNull() }
        line["askSentMs"] = ms(askTurn?.lastAudioSentUptime)
        line["askFirstAudioMs"] = ms(askTurn?.firstAudioUptime)
        line["askFinishedMs"] = ms(askTurn?.finishedUptime)
        line["askSaid"] = askTurn?.transcript ?? NSNull()
        line["askToolCalls"] = askTurn?.toolCalls.map(\.name) ?? []
        line["finalSaid"] = box.report?.spoken ?? NSNull()
        if let cardUptime { line["bursts"] = witness.bursts(from: cardUptime, until: end) }
        return line
    }
}
