//
//  ConfirmationNudge.swift
//  leanring-buddy
//
//  A short spoken nudge when an approval card appears ("Sir, I need your
//  go-ahead on the card."), after the card's chime. Our own fixed words —
//  never an app's or a model's, which could carry an instruction.
//
//  Timing (pure, `step`): nothing for the first 2 s (a card answered that fast
//  needs no nudge), then once, never over the owner talking or over J.A.R.V.I.S.'s
//  own reply audio — right after it instead; one gentle second nudge at 25 s if
//  still unanswered; never a third.
//
//  Spoken locally (AVSpeechSynthesizer, a British voice), NOT through the realtime
//  session's system turn. Decided 2026-10-08: (1) a card is most often up while an
//  owner turn's tool call waits on its ticket — `speakForAgent` speaks only between
//  owner turns, and `beginSystemTurn` replaces the connection's `turn`, which would
//  orphan that call; (2) a system turn is the model's words about our text, and
//  these must be ours verbatim; (3) no provider credit, and it works with no
//  session connected.
//
//  Since 2026-11-01 the realtime voice asks for a card itself, in its own voice,
//  the moment the card shows (`RealtimeVoiceConnection.handCardToVoice`). Owner's
//  live test 2026-10-31 12:14:26Z: this line spoke at 2 s while the model sat
//  silent on its held tool call, then the model asked AFTER the card was answered
//  — two voices. So a card the voice was handed is never nudged once the voice's
//  reply audio plays; this line is only the fallback for a voice that stayed
//  silent `voiceGraceSeconds`, or a card no voice turn asked about.
//

import AVFoundation
import Foundation

nonisolated enum ConfirmationNudge {
    enum Nudge: Equatable, Sendable { case first, second }
    enum Step: Equatable, Sendable { case wait, speak(Nudge), done }

    /// A card answered inside this is never nudged: the owner was already on it.
    static let quietSeconds: TimeInterval = 2
    static let secondNudgeSeconds: TimeInterval = 25
    /// A first nudge held back by the owner talking is not followed straight away.
    static let minimumGapSeconds: TimeInterval = 10
    static let maximumNudges = 2
    /// A card the realtime voice was handed waits this long for the voice to speak before
    /// our line stands in: ~2.2x the slowest tool result -> first audio in voice-live.log
    /// (Gemini 2,705 ms, 2026-10-31 12:14:20Z).
    static let voiceGraceSeconds: TimeInterval = 6
    /// The voice's hand-off may land just BEFORE the card's own `cardShown` (both hop to main).
    static let voiceAskLeadSeconds: TimeInterval = 5

    /// `voiceAsked`: the realtime voice was handed this card's question. `voiceSpoke`: its
    /// reply audio has played since — then the card is the voice's, and never nudged.
    static func step(shownAt: TimeInterval, now: TimeInterval, spoken: Int, lastSpokenAt: TimeInterval?,
                     pending: Bool, voiceBusy: Bool, voiceAsked: Bool = false, voiceSpoke: Bool = false) -> Step {
        guard pending, spoken < maximumNudges, !voiceSpoke else { return .done }
        let age = now - shownAt
        guard age >= (voiceAsked ? voiceGraceSeconds : quietSeconds), !voiceBusy else { return .wait }
        if spoken == 0 { return .speak(.first) }
        guard age >= secondNudgeSeconds, now - (lastSpokenAt ?? shownAt) >= minimumGapSeconds else { return .wait }
        return .speak(.second)
    }

    static func lines(for nudge: Nudge) -> [String] {
        switch nudge {
        case .first: return ["Sir, I need your go-ahead on the card.", "Sir, the card needs your approval.",
                             "A card awaits your answer, sir."]
        case .second: return ["Still awaiting your go-ahead on the card, sir.", "Sir, the card is still waiting on you."]
        }
    }

    static func line(for nudge: Nudge, pick: Int) -> String {
        let lines = lines(for: nudge)
        return lines[Int(pick.magnitude % UInt(lines.count))]
    }
}

/// Runs `ConfirmationNudge.step` for one card presentation on a 0.25 s timer.
@MainActor
final class ConfirmationNudger {
    /// Set by the realtime voice when it hands a card's question to the model; cleared when a card goes.
    static var voiceAskedUptime: TimeInterval?

    private let synthesizer = AVSpeechSynthesizer()
    private var voiceSpoke = false
    private var timer: Timer?
    private var shownAt: TimeInterval = 0
    private var spoken = 0
    private var lastSpokenAt: TimeInterval?
    /// Whether the card is still up with a question on it.
    var isPending: () -> Bool = { false }
    /// J.A.R.V.I.S.'s own reply audio playing (set by the app; the owner's
    /// push-to-talk is read from the notch).
    var replyAudioIsPlaying: () -> Bool = { false }

    func cardShown() {
        timer?.invalidate()
        shownAt = ProcessInfo.processInfo.systemUptime
        spoken = 0
        lastSpokenAt = nil
        voiceSpoke = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Answered or gone: no more nudges, and a line still being said stops.
    func cardDismissed() {
        timer?.invalidate()
        timer = nil
        Self.voiceAskedUptime = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let ownerTalking = JarvisNotch.shared.state == .listening
        // The owner's press beats our line: the mic must not hear it.
        if ownerTalking, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let replyPlaying = replyAudioIsPlaying()
        let voiceAsked = Self.voiceAskedUptime.map { $0 >= shownAt - ConfirmationNudge.voiceAskLeadSeconds } ?? false
        if voiceAsked, replyPlaying, !voiceSpoke {
            voiceSpoke = true
            MeasurementLogFile.appendJSONLine(["event": "voiceAsked", "cardAgeMs": Int(((now - shownAt) * 1000).rounded())],
                                              toFileNamed: "confirmation-nudge.jsonl")
        }
        let busy = ownerTalking || replyPlaying || synthesizer.isSpeaking
        switch ConfirmationNudge.step(shownAt: shownAt, now: now, spoken: spoken, lastSpokenAt: lastSpokenAt,
                                      pending: isPending(), voiceBusy: busy, voiceAsked: voiceAsked, voiceSpoke: voiceSpoke) {
        case .wait: break
        case .done:
            // Out of nudges (or answered): stop the clock, but let a line just begun finish.
            timer?.invalidate()
            timer = nil
        case .speak(let nudge):
            spoken += 1
            lastSpokenAt = now
            let text = ConfirmationNudge.line(for: nudge, pick: Int.random(in: 0..<1000))
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
            synthesizer.speak(utterance)
            print("🔔 card nudge (\(nudge)): \(text)")
            MeasurementLogFile.appendJSONLine(["event": "nudge", "nudge": "\(nudge)", "text": text,
                                               "cardAgeMs": Int(((now - shownAt) * 1000).rounded())],
                                              toFileNamed: "confirmation-nudge.jsonl")
        }
    }
}
