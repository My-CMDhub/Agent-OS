//
//  JarvisNotchTests.swift
//  leanring-buddyTests
//
//  The notch's pure parts: the state machine against the contract's table,
//  the error-code -> plain-reason map, the geometry with and without a
//  hardware notch, the mic level scale and the two ticks. Whether the panel
//  draws, stays click-through and leaves the frontmost app alone is proven by
//  `--voice-tool-probe`, not here.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct JarvisNotchTests {

    // MARK: State machine

    @Test func aVerifiedOpenRunsListeningThinkingIntentProofIdle() {
        var state = JarvisNotchState.idle
        let events: [JarvisNotchEvent] = [
            .hotkeyDown, .hotkeyUp, .toolCall(title: "System Settings"),
            .harnessAnswered(ok: true, subject: "System Settings", error: nil), .holdElapsed
        ]
        var names: [String] = []
        for event in events {
            state = state.next(on: event) ?? state
            names.append(state.name)
        }
        #expect(names == ["listening", "thinking", "intent", "proof", "idle"])
    }

    @Test func proofComesOnlyFromAnOkAnswerAfterAnIntent() {
        let ok = JarvisNotchEvent.harnessAnswered(ok: true, subject: "Finder", error: nil)
        #expect(JarvisNotchState.intent(title: "Finder").next(on: ok) == .proof(subject: "Finder"))
        #expect(JarvisNotchState.needsYou.next(on: ok) == .proof(subject: "Finder"))
        // No intent on screen, no proof: a late answer after a new press or after idle moves nothing.
        for state: JarvisNotchState in [.idle, .listening, .thinking, .didntTake(reason: "x")] {
            #expect(state.next(on: ok) == nil)
        }
        let failed = JarvisNotchEvent.harnessAnswered(ok: false, subject: "Figma", error: "notFound")
        #expect(JarvisNotchState.intent(title: "Figma").next(on: failed) == .didntTake(reason: "no app by that name"))
    }

    @Test func aTicketHoldsNeedsYouUntilItIsAnswered() {
        let intent = JarvisNotchState.intent(title: "Terminal")
        #expect(intent.next(on: .confirmationRequired) == .needsYou)
        #expect(JarvisNotchState.needsYou.holdSeconds == nil)
        #expect(JarvisNotchState.needsYou.next(on: .holdElapsed) == nil)
        #expect(JarvisNotchState.needsYou.next(on: .harnessAnswered(ok: false, subject: "Terminal", error: "confirmationDenied"))
                == .didntTake(reason: "you declined on the card"))
        #expect(JarvisNotchState.thinking.next(on: .confirmationRequired) == nil)
    }

    @Test func eventsOutsideTheirStateAreIgnored() {
        #expect(JarvisNotchState.thinking.next(on: .hotkeyUp) == nil)
        #expect(JarvisNotchState.listening.next(on: .toolCall(title: "x")) == nil)
        #expect(JarvisNotchState.thinking.next(on: .firstAudioWithoutTool) == .idle)
        #expect(JarvisNotchState.intent(title: "x").next(on: .firstAudioWithoutTool) == nil)
        #expect(JarvisNotchState.proof(subject: "x").next(on: .turnEnded) == nil)
        #expect(JarvisNotchState.intent(title: "x").next(on: .turnEnded) == .idle)
        // A press always wins, whatever is showing.
        #expect(JarvisNotchState.proof(subject: "x").next(on: .hotkeyDown) == .listening)
    }

    @Test func shapesHoldsAndAnnouncementsMatchTheContract() {
        #expect(JarvisNotchState.idle.shape == .idle)
        #expect(JarvisNotchState.listening.shape == .compact)
        #expect(JarvisNotchState.thinking.shape == .compact)
        #expect(JarvisNotchState.intent(title: "x").shape == .expanded)
        #expect(JarvisNotchState.proof(subject: "x").holdSeconds == 1.8)
        #expect(JarvisNotchState.didntTake(reason: "x").holdSeconds == 2.5)
        #expect(JarvisNotchState.intent(title: "Opening Finder\u{2026}").title == "Opening Finder\u{2026}")
        #expect(JarvisNotchState.proof(subject: "System Settings").detail == " \u{2014} verified")
        // VoiceOver: proof, needs you, didn't take — never listening, thinking or intent.
        #expect(JarvisNotchState.listening.announcement == nil)
        #expect(JarvisNotchState.thinking.announcement == nil)
        #expect(JarvisNotchState.intent(title: "x").announcement == nil)
        #expect(JarvisNotchState.proof(subject: "Finder").announcement == "Finder verified")
        #expect(JarvisNotchState.needsYou.announcement != nil)
        #expect(JarvisNotchState.didntTake(reason: "x").announcement != nil)
    }

    // MARK: Reason map

    @Test func everyReasonFitsTheLine() {
        for reason in Array(JarvisNotchReason.byErrorCode.values) + [JarvisNotchReason.fallback] {
            #expect(!reason.isEmpty)
            #expect(reason.count <= JarvisNotchReason.maximumLength, "\(reason)")
        }
        #expect(JarvisNotchReason.plain(forErrorCode: "notFound") == "no app by that name")
        #expect(JarvisNotchReason.plain(forErrorCode: "somethingNew") == JarvisNotchReason.fallback)
        #expect(JarvisNotchReason.plain(forErrorCode: nil) == JarvisNotchReason.fallback)
    }

    // MARK: Geometry

    /// A 14" MacBook Pro at default scale: 1512x982 pt, a 32 pt menu bar, the
    /// notch 185 pt wide between two 663.5 pt auxiliary areas.
    @Test func withANotchThePillGrowsOutOfIt() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let geometry = JarvisNotchGeometry.resolve(screenFrame: screen, safeAreaTop: 32, auxiliaryTopLeftWidth: 663.5,
                                                   auxiliaryTopRightWidth: 663.5, menuBarHeight: 32)
        #expect(geometry.hasNotch)
        #expect(geometry.anchor == CGRect(x: 663.5, y: 950, width: 185, height: 32))
        #expect(geometry.pillSize(.idle) == CGSize(width: 185, height: 32))
        #expect(geometry.pillSize(.compact) == CGSize(width: 185 + 68, height: 32))
        #expect(geometry.pillSize(.expanded) == CGSize(width: 185 + 300, height: 62))
        // Top edge on the screen's top edge, centred on the notch.
        #expect(geometry.panelFrame.maxY == 982)
        #expect(geometry.panelFrame.midX == 756)
        #expect(geometry.panelFrame.width >= geometry.pillSize(.expanded).width)
    }

    @Test func withoutANotchThePillHangsUnderTheMenuBar() {
        // A second display to the right, origin not zero.
        let screen = CGRect(x: 1512, y: -100, width: 1920, height: 1080)
        let geometry = JarvisNotchGeometry.resolve(screenFrame: screen, safeAreaTop: 0, auxiliaryTopLeftWidth: nil,
                                                   auxiliaryTopRightWidth: nil, menuBarHeight: 24)
        #expect(!geometry.hasNotch)
        #expect(geometry.anchor.midX == screen.midX)
        #expect(geometry.anchor.maxY == screen.maxY - 24 - JarvisNotchGeometry.noNotchGap)
        #expect(geometry.pillSize(.idle) == .zero)
        #expect(geometry.pillSize(.compact) == JarvisNotchGeometry.noNotchCompactSize)
        #expect(geometry.panelFrame.maxY == geometry.anchor.maxY)
        // Auxiliary areas that leave no gap are not a notch.
        let noGap = JarvisNotchGeometry.resolve(screenFrame: screen, safeAreaTop: 24, auxiliaryTopLeftWidth: 960,
                                                auxiliaryTopRightWidth: 960, menuBarHeight: 24)
        #expect(!noGap.hasNotch)
    }

    // MARK: Level

    @Test func levelMapsDecibelsOntoTheBars() {
        #expect(JarvisNotchLevel.normalised(rms: 0) == 0)
        #expect(JarvisNotchLevel.normalised(rms: pow(10, -60 / 20)) == 0)
        #expect(abs(JarvisNotchLevel.normalised(rms: pow(10, -30 / 20)) - 0.5) < 0.001)
        #expect(JarvisNotchLevel.normalised(rms: 1) == 1)
        // A full-scale square wave has RMS 1.
        var square = Data()
        for index in 0..<100 {
            let sample: Int16 = index % 2 == 0 ? 32_767 : -32_767
            withUnsafeBytes(of: sample.littleEndian) { square.append(contentsOf: $0) }
        }
        #expect(abs(JarvisNotchLevel.rms(pcm16: square) - 1) < 0.001)
        #expect(JarvisNotchLevel.rms(pcm16: Data()) == 0)
    }

    // MARK: Ticks

    @Test func ticksAreShortSoftAndPitchedTheRightWay() {
        func peakDecibels(_ samples: [Float]) -> Float { 20 * log10(samples.map(abs).max() ?? 0) }
        /// Zero crossings per sample over a stretch — a pitch proxy.
        func crossingRate(_ samples: ArraySlice<Float>) -> Double {
            Double(zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count) / Double(samples.count)
        }
        for tick in JarvisNotchTick.allCases {
            let samples = tick.samples
            let milliseconds = Double(samples.count) / JarvisNotchTick.sampleRate * 1000
            #expect((40...70).contains(milliseconds))
            #expect(abs(peakDecibels(samples) - tick.peakDecibels) < 0.1)
        }
        #expect(JarvisNotchTick.press.peakDecibels == -24)
        #expect(JarvisNotchTick.release.peakDecibels < JarvisNotchTick.press.peakDecibels)
        let press = JarvisNotchTick.press.samples, release = JarvisNotchTick.release.samples
        #expect(crossingRate(press[(press.count / 2)...]) > crossingRate(press[..<(press.count / 2)]))
        #expect(crossingRate(release[(release.count / 2)...]) < crossingRate(release[..<(release.count / 2)]))
    }
}
