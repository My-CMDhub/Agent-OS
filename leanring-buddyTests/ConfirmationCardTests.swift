//
//  ConfirmationCardTests.swift
//  leanring-buddyTests
//
//  The approval card's pure parts: where it sits under the notch (with and
//  without a hardware notch), which chime it plays and when it stays silent,
//  and that every line a ticket binds has a place on the card. Whether it
//  actually grows out of the notch on screen is a live check, not this.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct ConfirmationCardTests {

    // MARK: Geometry

    /// The card's top-left rect in global AppKit space.
    private func appKitRect(_ local: CGRect, in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + local.minX, y: panel.maxY - local.maxY, width: local.width, height: local.height)
    }

    @Test func onANotchedScreenTheCardStartsAsTheNotchAndHangsBelowIt() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = JarvisNotchGeometry.resolve(screenFrame: screen, safeAreaTop: 32, auxiliaryTopLeftWidth: 663.5,
                                                auxiliaryTopRightWidth: 663.5, menuBarHeight: 32)
        let card = ConfirmationCardGeometry(notch: notch)
        let panel = card.panelFrame(contentHeight: 300)

        // It starts at the notch's own position and size.
        #expect(appKitRect(card.collapsedFrame, in: panel) == notch.anchor)
        #expect(panel.maxY == screen.maxY)
        #expect(panel.midX == notch.anchor.midX)
        // The tab's text sits under the camera housing, never across it.
        #expect(card.tabSize.height > notch.anchor.height)
        #expect(card.tabSize.width > notch.anchor.width)
        // The card hangs below the tab, centred on the notch, inside the screen.
        let cardFrame = card.cardFrame(height: 200)
        #expect(cardFrame.minY >= card.tabFrame.maxY)
        #expect(appKitRect(cardFrame, in: panel).midX == notch.anchor.midX)
        #expect(screen.contains(panel))
    }

    @Test func withoutANotchTheCardStartsAsTheHangingPillOnThatScreen() {
        // A second display, right of the laptop, no notch, 25 pt menu bar.
        let screen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let notch = JarvisNotchGeometry.resolve(screenFrame: screen, safeAreaTop: 0, auxiliaryTopLeftWidth: nil,
                                                auxiliaryTopRightWidth: nil, menuBarHeight: 25)
        let card = ConfirmationCardGeometry(notch: notch)
        let panel = card.panelFrame(contentHeight: 300)
        let collapsed = appKitRect(card.collapsedFrame, in: panel)

        #expect(card.collapsedSize == JarvisNotchGeometry.noNotchCompactSize)
        #expect(collapsed.midX == screen.midX)
        #expect(collapsed.maxY == screen.maxY - 25 - JarvisNotchGeometry.noNotchGap)
        #expect(panel.maxY == collapsed.maxY)
        #expect(card.tabSize == ConfirmationCardGeometry.noNotchTabSize)
        #expect(screen.contains(panel))
    }

    @Test @MainActor func noClickCanCountBeforeTheCardHasStoppedGrowing() {
        // The settle clock outlasts the spring, so even a click the hit-test let
        // through mid-growth is refused as too early.
        #expect(ConfirmationCardWindowManager.growSeconds < HarnessConfirmations.ApprovalInput.minimumRowSettledSeconds)
        #expect(ConfirmationCardWindowManager.reduceMotionFadeSeconds < HarnessConfirmations.ApprovalInput.minimumRowSettledSeconds)
    }

    // MARK: Sound

    private func ticket(_ id: String, destructive: Bool = false) -> HarnessConfirmations.Ticket {
        var ticket = HarnessConfirmations.Ticket(
            id: id, createdAt: Date(), verb: "press", rawTarget: "Delete", target: "\"Delete\"", text: nil, mode: nil,
            appName: "\"Finder\"", bundleIdentifier: "com.apple.finder", reason: "r", status: .pending)
        ticket.isDestructive = destructive
        return ticket
    }

    @Test func aNewCardChimesOnceAndADestructiveQuestionSoundsDifferent() {
        #expect(ConfirmationCardWindowManager.chime(pending: [ticket("a")], announced: [], cardWasPresented: false) == .permission)
        #expect(ConfirmationCardWindowManager.chime(pending: [ticket("a", destructive: true)], announced: [],
                                                    cardWasPresented: false) == .destructive)
        // Any new destructive question makes the whole card's chime the serious one.
        #expect(ConfirmationCardWindowManager.chime(pending: [ticket("a"), ticket("b", destructive: true)], announced: [],
                                                    cardWasPresented: false) == .destructive)
    }

    @Test func aCardReplacedInPlaceOrReShownForTheSameTicketIsSilent() {
        // Already up: a ticket added or swapped in place makes no sound.
        #expect(ConfirmationCardWindowManager.chime(pending: [ticket("a"), ticket("b")], announced: ["a"],
                                                    cardWasPresented: true) == nil)
        // Shown again for a ticket it already announced.
        #expect(ConfirmationCardWindowManager.chime(pending: [ticket("a")], announced: ["a"], cardWasPresented: false) == nil)
        #expect(ConfirmationCardWindowManager.chime(pending: [], announced: [], cardWasPresented: false) == nil)
    }

    @Test func theChimesAreSoftDistinctAndUnlikeTheTicks() {
        let permission = ConfirmationChime.permission.samples
        let destructive = ConfirmationChime.destructive.samples
        let peak = { (samples: [Float]) in Double(20 * log10(samples.map(abs).max() ?? 0)) }
        #expect(abs(peak(permission) - Double(ConfirmationChime.peakDecibels)) < 0.01)
        #expect(abs(peak(destructive) - Double(ConfirmationChime.peakDecibels)) < 0.01)
        #expect(permission != destructive)
        // Lower, and falling where the ordinary one rises.
        let (p1, p2) = ConfirmationChime.permission.noteHertz
        let (d1, d2) = ConfirmationChime.destructive.noteHertz
        #expect(p2 > p1 && d2 < d1 && max(d1, d2) < min(p1, p2))
        // Several times longer than either tick, and below the ticks' 1.5 kHz floor.
        let seconds = Double(permission.count) / JarvisNotchTick.sampleRate
        #expect(seconds > 4 * JarvisNotchTick.press.durationSeconds)
        #expect(max(p1, p2) < 1_500)
    }

    // MARK: One source for the card

    @Test @MainActor func everyKindOfLineHasASectionOnTheCard() {
        let sections = ConfirmationPromptView.cardSections
        #expect(Set(sections) == Set(HarnessConfirmations.CardLine.Kind.allCases))
        #expect(sections.count == HarnessConfirmations.CardLine.Kind.allCases.count)
    }

    @Test func thePreviewWhereAndEffectRowsComeFromTheBoundLines() {
        let typing = HarnessConfirmations.Shape(verb: "type", bundleIdentifier: "com.apple.mail", rawTarget: "Body",
                                                text: "Shipped slice 1b", mode: "insert", withinNamed: "Drafts")
        let lines = HarnessConfirmations.cardLines(for: typing, appName: "Mail")
        let byKind = { (kind: HarnessConfirmations.CardLine.Kind) in lines.filter { $0.kind == kind }.map(\.text) }
        #expect(byKind(.verb) == ["Type"])
        #expect(byKind(.preview) == ["\"Shipped slice 1b\""])
        #expect(byKind(.place) == ["\"Mail\" \u{203A} \"Drafts\" \u{203A} \"Body\""])
        #expect(byKind(.qualifier) == ["app id \"com.apple.mail\""])
        #expect(byKind(.effect) == ["Inserts the text above into \"Body\""])
        // What the ticket binds and the card draws are the same list.
        #expect(HarnessConfirmations.displayLines(for: typing, appName: "Mail") == lines.map(\.text))

        // Each new field moves when only its source moves.
        var replacing = typing; replacing.mode = "replace"
        #expect(HarnessConfirmations.cardLines(for: replacing, appName: "Mail").filter { $0.kind == .effect }.map(\.text)
                == ["Replaces everything in \"Body\" with the text above"])
        let press = HarnessConfirmations.Shape(verb: "press", bundleIdentifier: "com.apple.finder", rawTarget: "Empty Bin")
        #expect(!HarnessConfirmations.cardLines(for: press, appName: "Finder").contains { $0.kind == .preview })
        // Destructive is the kernel's typed flag, and it changes what the owner reads.
        let calm = HarnessConfirmations.displayLines(for: press, appName: "Finder")
        let serious = HarnessConfirmations.displayLines(for: press, appName: "Finder", destructive: true)
        #expect(calm != serious)
        #expect(serious.contains("judged destructive by the safety rules \u{2014} allow once or deny"))
        #expect(!calm.contains { $0.contains("destructive") })

        let confirmations = HarnessConfirmations(rulesStore: ApprovalRulesKeychainStore(serviceName: "\(ApprovalRulesKeychainStore.productionServiceName).test-\(UUID().uuidString)"))
        guard case .opened(let ticket) = confirmations.open(press, appName: "Finder", reason: "r", destructive: true) else {
            Issue.record("expected a ticket"); return
        }
        #expect(ticket.displayLines == serious)
        #expect(ticket.cardLines == HarnessConfirmations.cardLines(for: press, appName: "Finder", destructive: true))
    }

    @Test func aWhereLineTooLongToShowWholeIsRefused() {
        // 150 + 150 fit as two names, not as one WHERE line with the app (318 scalars).
        let shape = HarnessConfirmations.Shape(verb: "press", bundleIdentifier: "com.apple.finder",
                                               rawTarget: String(repeating: "t", count: 150),
                                               withinNamed: String(repeating: "w", count: 150))
        #expect(HarnessConfirmations.openRefusal(for: shape, appName: "Finder", reason: "r", pendingCount: 0)?.code
                == "confirmationTooLongToShow")
    }
}
