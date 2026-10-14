//
//  SubmitTypedEntryTests.swift
//  leanring-buddyTests
//
//  Owner's ruling 2026-10-13: submitting what was typed (type + AXConfirm) needs no
//  card in the owner's own organiser apps, a card elsewhere, and a send card
//  (Allow once / Deny) where it reaches other people. Live 2026-10-13: Calendar's
//  quick entry and a new Reminders row commit only on Return. Pure parts only.
//

import ApplicationServices
import Foundation
import Testing
@testable import Clicky

struct SubmitTypedEntryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    /// The kernel's own answer for typing into a field, before the submit rule.
    private func typed(subrole: String? = nil) -> SafetyDecision {
        let field = AccessibilityElementNode(role: "AXTextField", subrole: subrole, title: "New Event", value: nil,
                                             frameInAppKitCoordinates: CGRect(x: 100, y: 100, width: 300, height: 24), depth: 2,
                                             children: [], publishedActionNames: ["AXShowMenu", "AXConfirm"])
        return ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: nil, title: "New Event", action: .type), resolvedNode: field, matchCount: 1,
            visibleBounds: bounds,
            typing: .init(mode: .insert, settableAttributes: [kAXSelectedTextAttribute], currentValueLength: 0, aimedByFocus: false))
    }

    private func submitted(in bundle: String?, subrole: String? = nil) -> SafetyDecision {
        ActionSafetyKernel.gatingSubmit(typed(subrole: subrole), thenConfirm: true, bundleIdentifier: bundle)
    }

    @Test func anOrganiserAppSubmitsWithNoCard() {
        #expect(typed() == .allow)
        for bundle in ["com.apple.iCal", "com.apple.reminders", "com.apple.Notes", "com.apple.clock"] {
            #expect(submitted(in: bundle) == .allow, "\(bundle)")
        }
    }

    @Test func aThirdPartyAppAsksOnACardThatMayOfferAlways() {
        for bundle in ["com.todesktop.230313mzl4w4u92", "com.figma.Desktop", nil] as [String?] {
            guard case .requireConfirmation(_, let destructive) = submitted(in: bundle) else {
                Issue.record("\(bundle ?? "nil") was not carded"); continue
            }
            #expect(!destructive, "\(bundle ?? "nil")")
        }
    }

    /// G12 2026-10-15: a Font Book search commit was carded and denied. Apple's own apps reach no one —
    /// except those that send, and those that run code or hold credentials.
    @Test func applesOwnAppsSubmitWithNoCardExceptThoseThatSendOrRunCode() {
        for bundle in ["com.apple.FontBook", "com.apple.TextEdit", "com.apple.finder", "com.apple.systempreferences"] {
            #expect(submitted(in: bundle) == typed(subrole: nil), "\(bundle)")
        }
        for bundle in ["com.apple.Terminal", "com.apple.ScriptEditor2", "com.apple.Passwords"] {
            #expect(submitted(in: bundle) == .requireConfirmation(reason: "submitting what was typed runs it", destructive: true), "\(bundle)")
        }
        #expect(submitted(in: "com.apple.FaceTime") == .requireConfirmation(reason: "submitting what was typed sends it to other people",
                                                                          destructive: true))
    }

    /// G12 2026-10-15: re-typing Font Book's search was carded "replace would discard 9 characters".
    @Test func replacingASearchQueryNeedsNoCardButAFieldsTextStillDoes() {
        func replace(subrole: String?) -> SafetyDecision {
            let field = AccessibilityElementNode(role: "AXTextField", subrole: subrole, title: "Search", value: nil,
                                                 frameInAppKitCoordinates: CGRect(x: 100, y: 100, width: 300, height: 24), depth: 2,
                                                 children: [], publishedActionNames: ["AXConfirm"])
            return ActionSafetyKernel.evaluate(
                intent: ElementActionIntent(role: nil, title: "Search", action: .type), resolvedNode: field, matchCount: 1, visibleBounds: bounds,
                typing: .init(mode: .replace, settableAttributes: [kAXValueAttribute], currentValueLength: 9, aimedByFocus: false))
        }
        #expect(replace(subrole: "AXSearchField") == .allow)
        #expect(replace(subrole: nil) == .requireConfirmation(reason: ActionSafetyKernel.replaceWouldDiscardReason(characterCount: 9), destructive: true))
    }

    @Test func whereItReachesPeopleItIsASendAllowedOnceOnly() {
        for bundle in ["com.apple.mail", "com.apple.MobileSMS", "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
                       "org.mozilla.firefox", "com.microsoft.edgemac", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
                       "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.microsoft.teams2", "us.zoom.xos"] {
            #expect(submitted(in: bundle) == .requireConfirmation(reason: "submitting what was typed sends it to other people",
                                                                destructive: true), "\(bundle)")
        }
        let card = HarnessConfirmations.Shape(verb: "type", bundleIdentifier: "com.apple.mail", rawTarget: "Body", text: "hi",
                                              mode: "insert", thenConfirm: true)
        #expect(HarnessConfirmations.destructiveWarning(for: card) == "Sends it \u{2014} other people may see it")
        let calendar = HarnessConfirmations.Shape(verb: "type", bundleIdentifier: "com.apple.iCal", rawTarget: "New Event", text: "hi",
                                                  mode: "replace", thenConfirm: true)
        #expect(HarnessConfirmations.destructiveWarning(for: calendar) == "Replaces everything in this field")
    }

    @Test func aSecureFieldStaysRefusedAndNoSubmitChangesNothing() {
        guard case .refuse = submitted(in: "com.apple.iCal", subrole: "AXSecureTextField") else {
            Issue.record("a password field was not refused"); return
        }
        #expect(submitted(in: "com.apple.mail", subrole: "AXSecureTextField") == typed(subrole: "AXSecureTextField"))
        #expect(ActionSafetyKernel.gatingSubmit(.allow, thenConfirm: false, bundleIdentifier: "com.apple.mail") == .allow)
        // A question already destructive keeps its flag and gains the reason.
        #expect(ActionSafetyKernel.gatingSubmit(.requireConfirmation(reason: "r", destructive: true), thenConfirm: true,
                                                bundleIdentifier: "com.figma.Desktop")
                == .requireConfirmation(reason: "r; submitting what was typed in an app whose commit is unknown", destructive: true))
    }

    @Test func submitIsTheHarnessesThenConfirmAndNeverImplied() throws {
        func request(_ call: RealtimeToolCall) throws -> [String: Any] {
            let line = try RealtimeOpenAppTool.harnessRequestLine(for: call, expectApp: "com.apple.iCal", screenTarget: nil).get()
            return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let parsed = RealtimeToolCall.parsed(callID: "t", name: "type_text", arguments: ["app": "Calendar", "text": "JARVIS test meeting", "submit": true])
        #expect(parsed.submit)
        #expect(try request(parsed)["thenConfirm"] as? Bool == true)
        let plain = RealtimeToolCall.parsed(callID: "t", name: "type_text", arguments: ["app": "Calendar", "text": "JARVIS test meeting"])
        #expect(!plain.submit)
        #expect(try request(plain)["thenConfirm"] == nil)
        #expect(!RealtimeToolCall.parsed(callID: "p", name: "press_element", arguments: ["name": "Send", "submit": true]).submit)
        // E03 2026-10-15: a bare line break with submit is told how commit works, never sent.
        let blank = RealtimeToolCall.parsed(callID: "t", name: "type_text", arguments: ["app": "Calendar", "text": "\n", "submit": true])
        if case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(for: blank, expectApp: "com.apple.iCal", screenTarget: nil) {
            #expect(refusal.error == "submitNeedsText")
        } else { Issue.record("a blank submit reached the harness") }
        // The harness's AXConfirm outcome reaches the tool result, where a receipt reads it.
        let confirm: [String: Any] = ["published": true, "axErrorRawValue": 0, "milliseconds": 12]
        let told = RealtimeHandsVerbs.result([:], call: parsed, target: nil, response: ["confirm": confirm])
        #expect((told["confirm"] as? [String: Any])?["axErrorRawValue"] as? Int == 0)
        #expect(RealtimeHandsVerbs.result([:], call: plain, target: nil, response: [:])["confirm"] == nil)
    }
}
