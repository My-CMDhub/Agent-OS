//
//  DraftAndFormTests.swift
//  leanring-buddyTests
//
//  S2 (Google Calendar, 2026-10-08/10): a Save in draft scope asks on a card,
//  and a field in a tab the harness itself opened may be replaced without one.
//  Pure decisions only; the live run is the evidence for the AX half.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct DraftAndFormTests {

    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func node(_ role: String, _ title: String?, actions: [String] = [kAXPressAction]) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: title, value: nil, elementDescription: nil,
                                 frameInAppKitCoordinates: CGRect(x: 100, y: 100, width: 120, height: 24), depth: 1, children: [],
                                 publishedActionNames: actions)
    }

    private func decide(_ action: ElementAction, _ target: AccessibilityElementNode, draft: Bool,
                        typing: ActionSafetyKernel.TypingContext? = nil, label: String? = nil) -> SafetyDecision {
        ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: target.role, title: target.title?.raw ?? "", action: action),
                                    resolvedNode: target, matchCount: 1, visibleBounds: bounds, typing: typing,
                                    menuItemEnabled: action == .menu ? true : nil, labelTitle: label, draftScope: draft)
    }

    // Item 4: the owner said "stop before saving or sending" — Save, Send, Schedule, Invite ask, by the target's own name.
    @Test func aCommitWordInDraftScopeAsksOnACardThatCannotBeAlways() {
        for title in ["Save", "Send invitation", "Schedule send", "Invite guests", "Post"] {
            for action in [ElementAction.press, .click] {
                guard case .requireConfirmation(let reason, let destructive) = decide(action, node("AXButton", title), draft: true) else {
                    Issue.record("\(title) \(action) did not ask"); continue
                }
                #expect(destructive, "Allow once and Deny only, never an Always rule")
                #expect(reason.hasPrefix(ActionSafetyKernel.draftScopeReasonPrefix))
            }
        }
        // A menu item and a label pressed through its ancestor are judged too.
        if case .requireConfirmation = decide(.menu, node("AXMenuItem", "Save"), draft: true) {} else { Issue.record("menu Save") }
        if case .requireConfirmation = decide(.press, node("AXGroup", "Event actions"), draft: true, label: "Save") {} else { Issue.record("label Save") }
        // Outside draft scope Save is ordinary; inside it, words that merely contain a commit word are not one.
        #expect(decide(.press, node("AXButton", "Save"), draft: false) == .allow)
        #expect(decide(.press, node("AXButton", "Saved items"), draft: true) == .allow)
        #expect(decide(.press, node("AXButton", "More options"), draft: true) == .allow)
    }

    @Test func draftScopeIsReadFromTheWireAndOnlyEverAddsAQuestion() throws {
        guard case .success(let on) = HarnessPolicy.decode(line: #"{"verb":"press","title":"Save","draftScope":true}"#),
              case .success(let off) = HarnessPolicy.decode(line: #"{"verb":"press","title":"Save"}"#) else {
            Issue.record("decode failed"); return
        }
        #expect(on.draftScope)
        #expect(!off.draftScope)
    }

    // The agent loop's draft judge now hands the press to the harness, flagged, so the kernel can card it.
    @Test func theDraftGuardFlagsEveryRequestForTheKernel() {
        let seen = LineBox()
        let guarded = AgentLoop.draftGuardedAnswer { line in seen.lines.append(line); return "{\"ok\":true}" }
        #expect(guarded("{\"verb\":\"press\",\"title\":\"Save\"}") == "{\"ok\":true}")
        let request = try? JSONSerialization.jsonObject(with: Data((seen.lines.first ?? "").utf8)) as? [String: Any]
        #expect(request?["draftScope"] as? Bool == true)
        #expect(request?["title"] as? String == "Save")
    }

}

final class LineBox: @unchecked Sendable { var lines: [String] = [] }
