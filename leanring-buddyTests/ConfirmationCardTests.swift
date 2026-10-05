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
        // And the same for Details or a long preview opening: the buttons move,
        // their clocks restart (`aRowsClockRestartsWhenItOrItsWindowMoves`), and the
        // move ends before a click could count.
        #expect(ConfirmationPromptView.expandSeconds < HarnessConfirmations.ApprovalInput.minimumRowSettledSeconds)
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
        // The collapsed card draws exactly the always-visible kinds; Details the rest.
        let kinds = HarnessConfirmations.CardLine.Kind.allCases
        #expect(ConfirmationPromptView.alwaysVisibleSections == kinds.filter { $0.isAlwaysVisible })
        #expect(ConfirmationPromptView.detailSections == kinds.filter { !$0.isAlwaysVisible })
    }

    /// The visibility rule (owner's layout 2026-10-05): Details may hide a line
    /// only if it changes neither what the action does nor what it lands on.
    @Test func everyFieldThatChangesTheActionOrItsTargetIsVisibleWithoutOpeningDetails() {
        let full = HarnessConfirmations.Shape(verb: "type", bundleIdentifier: "com.apple.mail", rawTarget: "Body",
                                              text: "hello", mode: "insert", withinNamed: "Drafts",
                                              nearPoint: CGPoint(x: 10, y: 20), role: "AXTextArea", thenConfirm: true)
        var variants: [String: HarnessConfirmations.Shape] = [:]
        var v = full; v.text = "goodbye"; variants["text"] = v
        v = full; v.mode = "replace"; variants["mode"] = v
        v = full; v.withinNamed = "Bank"; variants["withinNamed"] = v
        v = full; v.thenConfirm = false; variants["thenConfirm"] = v
        variants["verb"] = .init(verb: "press", bundleIdentifier: full.bundleIdentifier, rawTarget: full.rawTarget, text: full.text,
                                 mode: full.mode, withinNamed: full.withinNamed, nearPoint: full.nearPoint, role: full.role, thenConfirm: true)
        variants["rawTarget"] = .init(verb: "type", bundleIdentifier: full.bundleIdentifier, rawTarget: "Subject", text: full.text,
                                      mode: full.mode, withinNamed: full.withinNamed, nearPoint: full.nearPoint, role: full.role, thenConfirm: true)
        // Identity of the element among same-named ones, and the app's id: one
        // click away under Details (the app's NAME is in the question).
        let detailsOnly: Set<String> = ["nearPoint", "role", "bundleIdentifier"]
        // A field added to Shape fails here until it is put on one side.
        #expect(Set(Mirror(reflecting: full).children.compactMap(\.label)) == Set(variants.keys).union(detailsOnly))

        let visible = { (shape: HarnessConfirmations.Shape, app: String?) in
            HarnessConfirmations.cardLines(for: shape, appName: app).filter(\.kind.isAlwaysVisible).map(\.text)
        }
        for (field, variant) in variants {
            #expect(visible(variant, "Mail") != visible(full, "Mail"), "\(field) changes the action but hides behind Details")
        }
        // The app: by name, or by its id when it has none.
        #expect(visible(full, "Notes") != visible(full, "Mail"))
        let otherApp = HarnessConfirmations.Shape(verb: "type", bundleIdentifier: "com.apple.Notes", rawTarget: full.rawTarget,
                                                  text: full.text, mode: full.mode, withinNamed: full.withinNamed,
                                                  nearPoint: full.nearPoint, role: full.role, thenConfirm: true)
        #expect(visible(otherApp, nil) != visible(full, nil))
        // The typed text is visible whole (as the preview line) — the card may
        // shorten it only with a "+N more" that opens the rest.
        #expect(visible(full, "Mail").contains("\"hello\""))
        #expect(visible(full, "Mail").first == "Type this and submit it in \"Mail\"?")
    }

    @Test func aLongTypedTextIsShortenedWithACountNeverCut() {
        let text = String(repeating: "abc ", count: 60)
        let preview = TypedTextPreview(text)
        #expect(text.hasPrefix(preview.head))
        #expect(preview.head.count + preview.hiddenCharacters == text.count)
        #expect(preview.hiddenCharacters > 0)
        let short = TypedTextPreview("hi")
        #expect(short.head == "hi" && short.hiddenCharacters == 0)
    }

    /// The rule an "Always" answer saves reads, in the list, as the card read.
    @Test func anAlwaysRuleIsListedInTheCardsOwnWords() {
        let confirmations = HarnessConfirmations(rulesStore: ApprovalRulesKeychainStore(serviceName: "\(ApprovalRulesKeychainStore.productionServiceName).test-\(UUID().uuidString)"))
        let press = HarnessConfirmations.Shape(verb: "press", bundleIdentifier: "com.apple.TextEdit", rawTarget: "Delete",
                                               withinNamed: "Untitled", role: "AXButton")
        let launch = HarnessConfirmations.Shape(verb: "launch", bundleIdentifier: "com.apple.Terminal", rawTarget: "Terminal")
        guard case .opened(let pressTicket) = confirmations.open(press, appName: "TextEdit", reason: "r", destructive: false),
              case .opened(let launchTicket) = confirmations.open(launch, appName: "Terminal", reason: "r", destructive: false) else {
            Issue.record("expected two tickets"); return
        }
        let line = { (ticket: HarnessConfirmations.Ticket, kind: HarnessConfirmations.CardLine.Kind) in
            ticket.cardLines.first { $0.kind == kind }?.text
        }

        let exact = HarnessConfirmations.ruleSummary(for: HarnessConfirmations.rule(for: pressTicket), appName: "TextEdit")
        #expect(exact.title + "?" == line(pressTicket, .question))
        #expect(exact.title == "Press a control in \"TextEdit\"")
        #expect(exact.place == line(pressTicket, .place))
        #expect(exact.scope == HarnessConfirmations.exactRuleScope)
        #expect(exact.qualifiers.contains("role \"AXButton\""))
        #expect(HarnessConfirmations.alwaysButtonTitle(for: pressTicket).hasSuffix(exact.scope))

        let wholeApp = HarnessConfirmations.ruleSummary(for: HarnessConfirmations.rule(for: launchTicket), appName: "Terminal")
        #expect(wholeApp.title == "Launch \"Terminal\"")
        #expect(wholeApp.title + "?" == line(launchTicket, .question))
        #expect(wholeApp.place == "any target")
        #expect(HarnessConfirmations.alwaysButtonTitle(for: launchTicket).hasSuffix(wholeApp.scope))
        #expect(wholeApp.scope == HarnessConfirmations.wholeAppRuleScope)

        // A pre-2026-09-14 wildcard press rule matches nothing, and says so.
        let stale = HarnessConfirmations.ApprovalRule(bundleIdentifier: "com.apple.finder", verb: "press", target: nil)
        #expect(HarnessConfirmations.ruleSummary(for: stale, appName: "Finder").scope == "matches nothing (old rule)")
    }

    @Test func thePreviewWhereAndEffectRowsComeFromTheBoundLines() {
        let typing = HarnessConfirmations.Shape(verb: "type", bundleIdentifier: "com.apple.mail", rawTarget: "Body",
                                                text: "Shipped slice 1b", mode: "insert", withinNamed: "Drafts")
        let lines = HarnessConfirmations.cardLines(for: typing, appName: "Mail")
        let byKind = { (kind: HarnessConfirmations.CardLine.Kind) in lines.filter { $0.kind == kind }.map(\.text) }
        #expect(byKind(.question) == ["Type this in \"Mail\"?"])
        #expect(byKind(.preview) == ["\"Shipped slice 1b\""])
        #expect(byKind(.place) == ["\"Drafts\" \u{203A} \"Body\""])
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
        // 150 + 150 fit as two names, not as one where line (307 scalars).
        let shape = HarnessConfirmations.Shape(verb: "press", bundleIdentifier: "com.apple.finder",
                                               rawTarget: String(repeating: "t", count: 150),
                                               withinNamed: String(repeating: "w", count: 150))
        #expect(HarnessConfirmations.openRefusal(for: shape, appName: "Finder", reason: "r", pendingCount: 0)?.code
                == "confirmationTooLongToShow")
    }
}
