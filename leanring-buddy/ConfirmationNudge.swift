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

    static func step(shownAt: TimeInterval, now: TimeInterval, spoken: Int, lastSpokenAt: TimeInterval?,
                     pending: Bool, voiceBusy: Bool) -> Step {
        guard pending, spoken < maximumNudges else { return .done }
        let age = now - shownAt
        guard age >= quietSeconds, !voiceBusy else { return .wait }
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
    private let synthesizer = AVSpeechSynthesizer()
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Answered or gone: no more nudges, and a line still being said stops.
    func cardDismissed() {
        timer?.invalidate()
        timer = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let ownerTalking = JarvisNotch.shared.state == .listening
        // The owner's press beats our line: the mic must not hear it.
        if ownerTalking, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let busy = ownerTalking || replyAudioIsPlaying() || synthesizer.isSpeaking
        switch ConfirmationNudge.step(shownAt: shownAt, now: now, spoken: spoken, lastSpokenAt: lastSpokenAt,
                                      pending: isPending(), voiceBusy: busy) {
        case .wait: break
        case .done: cardDismissed()
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
