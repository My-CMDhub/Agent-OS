//
//  ConfirmationNudgeTests.swift
//  leanring-buddyTests
//
//  The spoken nudge when an approval card appears: its timing rules on an
//  injected clock. Whether the words are actually heard is a live check.
//

import Foundation
import Testing
@testable import Clicky

struct ConfirmationNudgeTests {
    private func step(now: TimeInterval, spoken: Int = 0, lastSpokenAt: TimeInterval? = nil,
                      pending: Bool = true, busy: Bool = false, voiceAsked: Bool = false, voiceSpoke: Bool = false) -> ConfirmationNudge.Step {
        ConfirmationNudge.step(shownAt: 100, now: 100 + now, spoken: spoken, lastSpokenAt: lastSpokenAt.map { 100 + $0 },
                               pending: pending, voiceBusy: busy, voiceAsked: voiceAsked, voiceSpoke: voiceSpoke)
    }

    /// Owner's live test 2026-10-31: this line spoke at 2 s, then the voice asked again after the card was
    /// answered. A card the realtime voice asks about is the voice's: once it speaks, nothing of ours.
    @Test func aCardTheVoiceAskedAboutIsNeverNudgedOnceTheVoiceSpeaks() {
        #expect(step(now: 2, voiceAsked: true) == .wait)
        #expect(step(now: 2, voiceAsked: true, voiceSpoke: true) == .done)
        #expect(step(now: 25, spoken: 0, voiceAsked: true, voiceSpoke: true) == .done)
    }

    /// A voice that stays silent is stood in for, later than a card nobody asked about.
    @Test func aSilentVoiceIsStoodInForAfterItsGrace() {
        #expect(step(now: ConfirmationNudge.voiceGraceSeconds - 0.1, voiceAsked: true) == .wait)
        #expect(step(now: ConfirmationNudge.voiceGraceSeconds, voiceAsked: true) == .speak(.first))
        #expect(step(now: ConfirmationNudge.voiceGraceSeconds, busy: true, voiceAsked: true) == .wait)
        #expect(ConfirmationNudge.voiceGraceSeconds > ConfirmationNudge.quietSeconds)
    }

    @Test func aCardAnsweredWithinTwoSecondsIsNeverNudged() {
        #expect(step(now: 0) == .wait)
        #expect(step(now: 1.9) == .wait)
        #expect(step(now: 1.0, pending: false) == .done)
        #expect(ConfirmationNudge.quietSeconds == 2)
    }

    @Test func theFirstNudgeFollowsTheCardOnce() {
        #expect(step(now: 2) == .speak(.first))
        #expect(step(now: 3, spoken: 1, lastSpokenAt: 2) == .wait)
    }

    @Test func neverOverTheOwnerOrOverItsOwnSentenceButRightAfter() {
        #expect(step(now: 2, busy: true) == .wait)
        #expect(step(now: 9, busy: true) == .wait)
        #expect(step(now: 9.2) == .speak(.first))
        #expect(step(now: 30, spoken: 1, lastSpokenAt: 3, busy: true) == .wait)
    }

    @Test func oneGentleSecondNudgeAtTwentyFiveSecondsAndNeverAThird() {
        #expect(step(now: 24.9, spoken: 1, lastSpokenAt: 2) == .wait)
        #expect(step(now: 25, spoken: 1, lastSpokenAt: 2) == .speak(.second))
        #expect(step(now: 26, spoken: 2, lastSpokenAt: 25) == .done)
        #expect(step(now: 59, spoken: 2, lastSpokenAt: 25) == .done)
        #expect(ConfirmationNudge.secondNudgeSeconds == 25)
    }

    @Test func aLateFirstNudgeIsNotFollowedStraightAway() {
        // The owner talked through the first 30 s: the first nudge is late, and
        // the second keeps its distance from it.
        #expect(step(now: 30) == .speak(.first))
        #expect(step(now: 31, spoken: 1, lastSpokenAt: 30) == .wait)
        #expect(step(now: 30 + ConfirmationNudge.minimumGapSeconds, spoken: 1, lastSpokenAt: 30) == .speak(.second))
    }

    @Test func anAnsweredCardStopsEverything() {
        #expect(step(now: 2, pending: false) == .done)
        #expect(step(now: 25, spoken: 1, lastSpokenAt: 2, pending: false) == .done)
    }

    /// Our own fixed words, varied a little; nothing an app or a model wrote.
    @Test func theWordsAreOursAndVary() {
        for nudge in [ConfirmationNudge.Nudge.first, .second] {
            let lines = ConfirmationNudge.lines(for: nudge)
            #expect(lines.count >= 2)
            #expect(Set(lines).count == lines.count)
            for index in 0..<10 { #expect(lines.contains(ConfirmationNudge.line(for: nudge, pick: index))) }
            #expect(lines.allSatisfy { $0.count <= 60 && $0.lowercased().contains("sir") })
        }
        #expect(ConfirmationNudge.line(for: .first, pick: 0) != ConfirmationNudge.line(for: .first, pick: 1))
    }
}
