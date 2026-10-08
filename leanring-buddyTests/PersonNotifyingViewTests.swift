//
//  PersonNotifyingViewTests.swift
//  leanring-buddyTests
//
//  Owner's ruling 2026-10-08: opening someone's profile on a network that
//  tells them who viewed it reaches a real person, so it asks on a card —
//  through openURL, through a press or click on a link whose own AXURL points
//  there, and inside a read-only task. Pure parts only: whether the live AXURL
//  read finds the link is a live check.
//

import Foundation
import Testing
@testable import Clicky

struct PersonNotifyingViewTests {
    static let profiles = [
        "https://www.linkedin.com/in/jane-doe-123/", "https://linkedin.com/in/jane", "https://au.linkedin.com/in/jane?trk=x",
        "https://www.LinkedIn.com//in/jane/recent-activity/", "http://m.linkedin.com/in/jane", "https://www.linkedin.com/IN/Jane"
    ]
    static let otherLinkedInPages = [
        "https://www.linkedin.com/feed/", "https://www.linkedin.com/search/results/people/?keywords=jane",
        "https://www.linkedin.com/messaging/", "https://www.linkedin.com/", "https://www.linkedin.com/in/",
        "https://www.linkedin.com/jobs/view/123", "https://www.linkedin.com/company/anthropic/", "https://www.linkedin.com/mynetwork/"
    ]
    static let otherHosts = [
        "https://example.com/in/jane", "https://notlinkedin.com/in/jane", "https://linkedin.com.evil.example/in/jane",
        "https://github.com/jane", "https://www.google.com/search?q=linkedin.com/in/jane"
    ]

    private func openURLDecision(_ string: String) -> SafetyDecision {
        let url = URL(string: string)!
        return ActionSafetyKernel.gatingPersonNotifyingView(HarnessHands.openURLDecision(url), url: url)
    }

    @Test func aProfilePageAsksOnACardThroughOpenURL() {
        for profile in Self.profiles {
            guard case .requireConfirmation(let reason, let destructive) = openURLDecision(profile) else {
                Issue.record("\(profile) was not carded")
                continue
            }
            #expect(reason == ActionSafetyKernel.personNotifyingReason(network: "LinkedIn"))
            #expect(!destructive)
        }
    }

    @Test func otherLinkedInPagesAndOtherSitesAreNotCarded() {
        for page in Self.otherLinkedInPages + Self.otherHosts {
            #expect(openURLDecision(page) == HarnessHands.openURLDecision(URL(string: page)!), "\(page) changed")
            #expect(openURLDecision(page) == .allow, "\(page) was carded")
        }
    }

    @Test func aStrongerDecisionIsKeptAndAWeakerOneRaised() {
        let profile = URL(string: Self.profiles[0])!
        #expect(ActionSafetyKernel.gatingPersonNotifyingView(.refuse(reason: "r"), url: profile) == .refuse(reason: "r"))
        guard case .requireConfirmation(let reason, true) = ActionSafetyKernel.gatingPersonNotifyingView(
            .requireConfirmation(reason: "title suggests a destructive action: delete", destructive: true), url: profile) else {
            Issue.record("a destructive question lost its flag")
            return
        }
        #expect(reason.contains("delete") && reason.contains("notif"))
        // A press with no link, or a link elsewhere, is untouched.
        #expect(ActionSafetyKernel.gatingPersonNotifyingView(.allow, url: nil) == .allow)
        #expect(ActionSafetyKernel.gatingPersonNotifyingView(.allow, url: URL(string: Self.otherLinkedInPages[0])!) == .allow)
        #expect(ActionSafetyKernel.personNotifyingView(Self.profiles[0])?.network == "LinkedIn")
        #expect(ActionSafetyKernel.personNotifyingView("not a url") == nil)
    }

    // MARK: The card

    @Test func aProfileLinkCardAsksByTheShownNameAndWarns() {
        let link = "https://www.linkedin.com/in/jane-doe/"
        let shape = HarnessConfirmations.Shape(verb: "press", bundleIdentifier: "com.google.Chrome", rawTarget: "Jane Doe", linkURL: link)
        let lines = HarnessConfirmations.cardLines(for: shape, appName: "Google Chrome")
        let visible = lines.filter(\.kind.isAlwaysVisible)
        #expect(lines.first == .init(kind: .question, text: "Open \"Jane Doe\"\u{2019}s LinkedIn profile?"))
        #expect(visible.contains(.init(kind: .warning, text: HarnessConfirmations.personNotifiedWarning)))
        #expect(HarnessConfirmations.personNotifiedWarning == "They\u{2019}ll be notified you viewed it")
        #expect(visible.contains { $0.kind == .place && $0.text.contains(link) })
        // One displayLines source: the ticket's lines are these.
        #expect(HarnessConfirmations.displayLines(for: shape, appName: "Google Chrome") == lines.map(\.text))
    }

    @Test func aNameIsTakenOnlyFromShownTextElseLeftOut() {
        let profile = "https://www.linkedin.com/in/jane-doe/"
        let unnamed: [HarnessConfirmations.Shape] = [
            // openURL's address is the caller's words, not text the app showed.
            .init(verb: "openURL", bundleIdentifier: "com.google.Chrome", rawTarget: profile),
            .init(verb: "press", bundleIdentifier: "com.google.Chrome", rawTarget: "<focused>", linkURL: profile),
            .init(verb: "click", bundleIdentifier: "com.google.Chrome", rawTarget: "View Jane Doe\u{2019}s profile", linkURL: profile)
        ]
        for shape in unnamed {
            let lines = HarnessConfirmations.cardLines(for: shape, appName: "Google Chrome")
            #expect(lines.first == .init(kind: .question, text: "Open a LinkedIn profile?"), "\(shape)")
            #expect(lines.contains(.init(kind: .warning, text: HarnessConfirmations.personNotifiedWarning)))
        }
    }

    @Test func otherPagesKeepTheirOrdinaryCard() {
        for page in Self.otherLinkedInPages + Self.otherHosts {
            let shape = HarnessConfirmations.Shape(verb: "openURL", bundleIdentifier: "com.google.Chrome", rawTarget: page)
            let lines = HarnessConfirmations.cardLines(for: shape, appName: "Google Chrome")
            #expect(lines.first?.text == "Open a page in \"Google Chrome\"?")
            #expect(!lines.contains { $0.kind == .warning })
        }
    }

    @Test func aProfileQuestionIsAnsweredOnceAndNeverByARule() {
        let profile = HarnessConfirmations.Shape(verb: "openURL", bundleIdentifier: "com.google.Chrome", rawTarget: Self.profiles[0])
        let link = HarnessConfirmations.Shape(verb: "press", bundleIdentifier: "com.google.Chrome", rawTarget: "Jane Doe",
                                              linkURL: Self.profiles[0])
        let feed = HarnessConfirmations.Shape(verb: "openURL", bundleIdentifier: "com.google.Chrome", rawTarget: Self.otherLinkedInPages[0])
        #expect(!HarnessConfirmations.allowsAlwaysRule(for: profile, destructive: false))
        #expect(!HarnessConfirmations.allowsAlwaysRule(for: link, destructive: false))
        #expect(HarnessConfirmations.allowsAlwaysRule(for: feed, destructive: false))
        #expect(!HarnessConfirmations.allowsAlwaysRule(for: feed, destructive: true))
    }

    @Test func aTicketForOneProfileLinkDoesNotOpenAnother() {
        let jane = HarnessConfirmations.Shape(verb: "press", bundleIdentifier: "com.google.Chrome", rawTarget: "Jane Doe",
                                              linkURL: "https://www.linkedin.com/in/jane-doe/")
        var other = jane
        other.linkURL = "https://www.linkedin.com/in/someone-else/"
        #expect(HarnessConfirmations.mismatchedField(approved: jane, other) == "linkURL")
        #expect(HarnessConfirmations.mismatchedField(approved: jane, jane) == nil)
    }

    // MARK: The agent loop's read-only layer

    /// A read-only task passes navigation through to the harness, and the harness
    /// cards a profile: so the task reaches a profile only through the card.
    @Test func aReadOnlyTaskReachesAProfileOnlyThroughTheHarnessCard() {
        let open: [String: Any] = ["verb": "openURL", "url": Self.profiles[0]]
        let press: [String: Any] = ["verb": "press", "title": "Jane Doe", "role": "AXLink"]
        #expect(AgentLoop.readOnlyRefusal(open, focusedField: { nil }) == nil)
        #expect(AgentLoop.readOnlyRefusal(press, focusedField: { nil }) == nil)
        guard case .requireConfirmation = openURLDecision(Self.profiles[0]) else {
            Issue.record("the harness would not card it")
            return
        }
    }
}
