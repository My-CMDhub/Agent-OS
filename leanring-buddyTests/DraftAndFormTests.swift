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

    // Item 2: replacing a field's text cards, unless the field is a single-line one in a tab the harness opened.
    @Test func aReplaceInATabTheHarnessOpenedNeedsNoCard() {
        func typing(_ length: Int, opened: Bool) -> ActionSafetyKernel.TypingContext {
            var context = ActionSafetyKernel.TypingContext(mode: .replace, settableAttributes: [kAXValueAttribute as String],
                                                           currentValueLength: length, aimedByFocus: false)
            context.inTabTheHarnessOpened = opened
            return context
        }
        let date = AccessibilityElementNode(role: "AXTextField", subrole: nil, title: "Start date", value: "10 Oct 2026",
                                            frameInAppKitCoordinates: CGRect(x: 100, y: 100, width: 120, height: 24), depth: 1, children: [])
        if case .requireConfirmation = decide(.type, date, draft: false, typing: typing(11, opened: false)) {} else {
            Issue.record("the owner's own tab must still card")
        }
        #expect(decide(.type, date, draft: false, typing: typing(11, opened: true)) == .allow)
        // A document body is never replaced without asking, whoever opened the tab.
        let body = AccessibilityElementNode(role: "AXTextArea", subrole: nil, title: "Body", value: "Dear …",
                                            frameInAppKitCoordinates: CGRect(x: 100, y: 100, width: 300, height: 200), depth: 1, children: [])
        if case .requireConfirmation = decide(.type, body, draft: false, typing: typing(400, opened: true)) {} else {
            Issue.record("a text area must still card")
        }
        let now = Date()
        #expect(HarnessPolicy.tabStillTheHarnesss(openedAt: now.addingTimeInterval(-60), now: now))
        #expect(!HarnessPolicy.tabStillTheHarnesss(openedAt: now.addingTimeInterval(-HarnessServer.openedTabLifetimeSeconds - 1), now: now))
        #expect(!HarnessPolicy.tabStillTheHarnesss(openedAt: nil, now: now))
    }

    // Keystrokes replace only when the whole value is selected first; otherwise they would insert.
    @Test func keystrokesReplaceOnlyAWhollySelectedValue() {
        func refusal(before: Int?, selection: Int?, covers: Bool) -> String? {
            HarnessHands.keystrokeRefusal(text: "17 Oct 2026", mode: .replace, valueLengthBefore: before, secureInputOn: false,
                                          focusedMightBeSecure: false, focusedIsTarget: true, selectionLength: selection,
                                          frontmostIsTarget: true, ownerIdle: true, caretLocation: 0, value: nil,
                                          selectionCoversValue: covers)?.code
        }
        #expect(refusal(before: 11, selection: 11, covers: true) == nil)
        #expect(refusal(before: 11, selection: 4, covers: false) == "replaceNeedsAXWrite")
        #expect(refusal(before: nil, selection: nil, covers: false) == "replaceNeedsAXWrite")
        #expect(refusal(before: 0, selection: 0, covers: false) == nil)
    }
}

extension DraftAndFormTests {

    // Item 3: Calendar's guest suggestions (live 2026-10-10): typing "ed" lists AXList "ed" holding
    // AXStaticText "edyboyjb35@gmail.com edyboyjb35@gmail.com" — Chromium's role=option. Clicking it carded
    // "unrecognised role AXStaticText". An option is a choice, so it is clicked; its words are still judged.
    @Test func aListboxOptionIsClickedAndItsWordsStillJudged() {
        func text(_ name: String) -> AccessibilityElementNode {
            AccessibilityElementNode(role: "AXStaticText", subrole: nil, title: nil, value: name, elementDescription: nil,
                                     frameInAppKitCoordinates: CGRect(x: 715, y: 448, width: 304, height: 44), depth: 3, children: [],
                                     publishedActionNames: ["AXShowMenu", "AXScrollToVisible"])
        }
        func decide(_ target: AccessibilityElementNode, option: Bool) -> SafetyDecision {
            ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: nil, title: target.displayName?.raw ?? "", action: .click),
                                        resolvedNode: target, matchCount: 1, visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        isListOption: option)
        }
        let contact = text("edyboyjb35@gmail.com edyboyjb35@gmail.com")
        #expect(decide(contact, option: true) == .allow)
        if case .requireConfirmation = decide(contact, option: false) {} else { Issue.record("loose text still asks") }
        if case .requireConfirmation = decide(text("Delete event"), option: true) {} else { Issue.record("an option's words are judged") }

        let list = AccessibilityElementNode(role: "AXList", subrole: nil, title: "ed", value: nil, elementDescription: nil,
                                            frameInAppKitCoordinates: CGRect(x: 715, y: 404, width: 304, height: 88), depth: 2, children: [])
        let group = AccessibilityElementNode(role: "AXGroup", subrole: nil, title: nil, value: nil, elementDescription: nil,
                                             frameInAppKitCoordinates: .zero, depth: 2, children: [])
        let root = AccessibilityElementNode(role: "AXWindow", subrole: nil, title: "Calendar", value: nil, elementDescription: nil,
                                            frameInAppKitCoordinates: .zero, depth: 0, children: [])
        // The guest field holds the caret while its suggestions pop up (security review 2026-10-10: a list is a listbox only so).
        let guestField: () -> String? = { "AXTextField" }
        #expect(HarnessPolicy.isListOption(chain: [root, list, contact], focusedRole: guestField))
        #expect(HarnessPolicy.isListOption(chain: [root, list, group, contact], focusedRole: guestField))
        #expect(!HarnessPolicy.isListOption(chain: [root, group, contact], focusedRole: guestField))
        #expect(!HarnessPolicy.isListOption(chain: [root, list], focusedRole: guestField))
        // Run 725F3AB7: the model pressed the option's own child text ("yboyjb35@gmail.com" beside a bold "ed").
        #expect(HarnessPolicy.isListOption(chain: [root, list, contact, text("yboyjb35@gmail.com")], focusedRole: guestField))
        // ...and through the unnamed wrappers the full tree holds between them (live select, 07:44).
        let wrapper = AccessibilityElementNode(role: "AXGenericElement", subrole: nil, title: nil, value: nil, elementDescription: nil,
                                               frameInAppKitCoordinates: .zero, depth: 3, children: [])
        #expect(HarnessPolicy.isListOption(chain: [root, list, wrapper, contact, wrapper, text("yboyjb35@gmail.com")], focusedRole: guestField))
        let button = AccessibilityElementNode(role: "AXButton", subrole: nil, title: nil, value: nil, elementDescription: nil,
                                              frameInAppKitCoordinates: .zero, depth: 3, children: [])
        #expect(!HarnessPolicy.isListOption(chain: [root, list, button, contact], focusedRole: guestField))
    }

    // Item 3: the AX hit named another process; the window server's mouse hit test is the second witness.
    @Test func aClickIsObscuredOnlyWhenBothWitnessesSaySo() {
        let chrome: pid_t = 605, wispr: pid_t = 650
        #expect(HarnessHands.coveringProcess(axHit: chrome, windowServerHit: chrome, target: chrome) == nil)
        #expect(HarnessHands.coveringProcess(axHit: wispr, windowServerHit: chrome, target: chrome) == nil)
        #expect(HarnessHands.coveringProcess(axHit: wispr, windowServerHit: wispr, target: chrome) == wispr)
        // An unreadable second witness never clears a cover.
        #expect(HarnessHands.coveringProcess(axHit: wispr, windowServerHit: nil, target: chrome) == wispr)
    }
}

extension DraftAndFormTests {

    // Run BCD5ABD3 (2026-10-10): type_text "Guests" listed tab "Guests" and group "Guests" and never the
    // box. The one-per-name pool dropped the AXComboBox inside its same-named tab panel.
    @Test func aFieldNamedLikeItsPanelIsTypedInto() {
        func frameJSON(_ r: CGRect) -> [String: Any] { ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height] }
        func element(_ role: String, _ name: String, _ frame: CGRect, subrole: String? = nil, parent: Int? = nil) -> [String: Any] {
            ["role": role, "subrole": subrole ?? NSNull(), "name": name, "nameIsPlausibleLabel": true, "actions": ["AXShowMenu", "AXScrollToVisible"],
             "nameSource": "title", "parent": parent ?? NSNull(), "frame": frameJSON(frame)]
        }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let snapshot: [String: Any] = ["ok": true, "walkStopReasons": [String](), "windowFrame": frameJSON(screen), "elements": [
            element("AXWindow", "Calendar", screen),
            element("AXRadioButton", "Guests", CGRect(x: 707, y: 554, width: 78, height: 48), subrole: "AXTabButton"),
            element("AXGroup", "Guests", CGRect(x: 699, y: 0, width: 352, height: 554), subrole: "AXTabPanel"),
            element("AXComboBox", "Guests", CGRect(x: 731, y: 508, width: 304, height: 24), parent: 2)
        ]]
        let found = RealtimeScreenVerbs.liveCandidates(named: "Guests", fromSnapshotResponse: snapshot, screens: [screen])
        #expect(found.contains { $0.role == "AXComboBox" })
        #expect(RealtimeScreenVerbs.typingCandidates(found).map(\.role) == ["AXComboBox"])
        // No input among them: unchanged, so the refusal still lists what matched.
        let noInputs = found.filter { $0.role != "AXComboBox" }
        #expect(RealtimeScreenVerbs.typingCandidates(noInputs) == noInputs)
    }
}

final class LineBox: @unchecked Sendable { var lines: [String] = [] }
