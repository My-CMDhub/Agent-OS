//
//  HandsReviewTests.swift
//  leanring-buddyTests
//
//  The independent review of the hands change (2026-10-01): a quit that never
//  found Quit, a clean quit reported as failure, a label's words skipped when
//  pressed through its ancestor, typing with no transcript or with a newline,
//  the word lists, the heard check's "no" and "X in Y", scrolling twice or at
//  the end, an insert over the owner's selection, and what a field is called.
//  Pure halves only; fixtures are SYNTHETIC.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct HandsReviewTests {

    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func menuItem(_ path: [String], shortcut: String? = nil) -> [String: Any] {
        ["path": path, "enabled": true, "shortcut": shortcut ?? NSNull(), "hasSubmenu": false]
    }

    // 1. The Apple menu is first in every listing; Quit is in the app's own menu.
    @Test func aQuitIsFoundInTheAppsMenuNotTheAppleMenu() {
        let chrome = [menuItem(["Apple", "About This Mac"]), menuItem(["Apple", "Log Out Owner…"], shortcut: "⇧⌘Q"),
                      menuItem(["Chrome", "Quit Google Chrome"], shortcut: "⌘Q"), menuItem(["File", "Close Tab"], shortcut: "⌘W")]
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "app", items: chrome) == ["Chrome", "Quit Google Chrome"])
        // No ⌘Q published: the first menu that is not the Apple menu.
        let unmarked = [menuItem(["Apple", "Force Quit…"]), menuItem(["TextEdit", "Quit TextEdit"]), menuItem(["File", "Close"])]
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "app", items: unmarked) == ["TextEdit", "Quit TextEdit"])
    }

    // 2. A quit is proved by the app being gone whenever the press was attempted.
    @Test func aQuitIsCheckedWheneverThePressWasAttempted() {
        #expect(RealtimeHandsVerbs.quitWasAttempted(["performed": ["status": "sent"]]))
        // The app tore down mid-press: the call times out or its element dies.
        #expect(RealtimeHandsVerbs.quitWasAttempted(["performed": ["status": "failed", "axErrorRawValue": -25204]]))
        #expect(RealtimeHandsVerbs.quitWasAttempted(["performed": ["status": "failed", "axErrorRawValue": -25202]]))
        // Refused, denied on the card, never pressed: nothing to check.
        #expect(!RealtimeHandsVerbs.quitWasAttempted(["ok": false, "error": "confirmationDenied"]))
        #expect(!RealtimeHandsVerbs.quitWasAttempted(["performed": ["status": "failed", "axErrorRawValue": -25206]]))
        #expect(RealtimeHandsVerbs.quitWaitSeconds >= 8)
        // Still running says so — and claims no save prompt nobody saw.
        let told = RealtimeHandsVerbs.stillRunningMessage(name: "Xcode")
        #expect(told.contains("Xcode") && !told.lowercased().contains("save"))
        #expect(!(JarvisNotchReason.byErrorCode["appStillRunning"] ?? "").contains("save"))
    }

    // 3. A label pressed through its ancestor: the LABEL's words still decide.
    @Test func aLabelsWordsDecideWhenItIsPressedThroughItsAncestor() throws {
        let group = AccessibilityElementNode(role: "AXGroup", subrole: nil, title: "Order #123", value: nil,
                                             frameInAppKitCoordinates: CGRect(x: 0, y: 100, width: 300, height: 60), depth: 1,
                                             children: [], publishedActionNames: [kAXPressAction])
        func decide(_ label: String?) -> SafetyDecision {
            ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: "AXGroup", title: "Order #123", action: .press), resolvedNode: group,
                                        matchCount: 1, visibleBounds: bounds, labelTitle: label)
        }
        #expect(decide(nil) == .allow)
        #expect(decide("Details") == .allow)
        #expect(decide("Delete") == .requireConfirmation(reason: "title suggests a destructive action: delete", destructive: true))
        #expect(decide("Post") == .requireConfirmation(reason: "title suggests a destructive action: post", destructive: true))
        #expect(decide("Buy now") == .refuse(reason: ActionSafetyKernel.irreversibleRefusalReason(keyword: "buy")))
        // The voice line carries the label it aimed at; the harness reads it.
        let label = RealtimeScreenCandidate(name: "Delete", role: "AXStaticText", frame: CGRect(x: 10, y: 110, width: 40, height: 16),
                                            position: "", pressable: false,
                                            pressAncestor: RealtimeScreenPressTarget(name: "Order #123", role: "AXGroup",
                                                                                     frame: CGRect(x: 0, y: 100, width: 300, height: 60)))
        let line = try RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "p", name: "press_element", appName: "com.apple.finder", elementName: "Delete"),
            expectApp: "com.apple.finder",
            screenTarget: RealtimeScreenTarget(candidate: label, point: CGPoint(x: 30, y: 118), app: "com.apple.finder", source: .thisTurn)).get()
        let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
        #expect(request["title"] as? String == "Order #123" && request["labelTitle"] as? String == "Delete")
        guard case .success(let decoded) = HarnessPolicy.decode(line: line) else { Issue.record("labelTitle did not decode"); return }
        #expect(decoded.labelTitle == "Delete")
        guard case .failure(let stray) = HarnessPolicy.decode(line: #"{"verb":"select","title":"x","labelTitle":"Delete"}"#) else {
            Issue.record("labelTitle on a select was accepted"); return
        }
        #expect(stray.code == "invalidField")
    }

    // 4 + 5. Typing and closing need the owner's words; typing never carries a line break.
    @Test func typingAndClosingFailClosedAndNeverTypeAControlCharacter() {
        #expect(RealtimeHeardCheck.refusesWithoutTranscript(toolName: "type_text", namedAppIsRunning: true))
        #expect(RealtimeHeardCheck.refusesWithoutTranscript(toolName: "close", namedAppIsRunning: true))
        #expect(!RealtimeHeardCheck.refusesWithoutTranscript(toolName: "scroll", namedAppIsRunning: true))
        for text in ["ls -la\n", "rm -rf ~\r", "beep\u{7}", "tab\there"] {
            let result = RealtimeOpenAppTool.harnessRequestLine(
                for: RealtimeToolCall(callID: "t", name: "type_text", appName: "com.apple.finder", text: text), expectApp: "com.apple.finder")
            guard case .failure(let refusal) = result else { Issue.record("typed \(text.debugDescription)"); continue }
            #expect(refusal.error == "controlCharacterInText")
        }
        guard case .success = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "t", name: "type_text", appName: "com.apple.finder", text: "hello, world"), expectApp: "com.apple.finder")
        else { Issue.record("plain text was refused"); return }
    }

    // 6. The owner's standing ruling: destructive, publishing, security approvals and sharing toggles -> card.
    @Test func theConfirmListsCoverDestructionPublishingApprovalsAndSharing() {
        func decide(_ title: String, role: String = "AXButton") -> SafetyDecision {
            ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: role, title: title, action: .press),
                                        resolvedNode: AccessibilityElementNode(role: role, subrole: nil, title: title, value: nil,
                                                                               frameInAppKitCoordinates: CGRect(x: 0, y: 100, width: 120, height: 24),
                                                                               depth: 1, children: [], publishedActionNames: [kAXPressAction]),
                                        matchCount: 1, visibleBounds: bounds)
        }
        let asked = ["Request Deletion", "Confirm removal", "Discard Changes", "Unsubscribe", "Sign Out", "Leave Meeting", "Deactivate",
                     "Uninstall", "Revoke", "Disconnect", "Cancel Subscription", "Repost", "Retweet", "Tweet", "Reshare", "Approve",
                     "Authorize", "Authorise", "Allow Access", "Yes, it was me", "Remote Login", "Screen Sharing", "File Sharing",
                     "Remote Management", "Remote Apple Events"]
        for title in asked {
            guard case .requireConfirmation(_, let destructive) = decide(title, role: "AXCheckBox") else {
                Issue.record("\(title) was not asked about"); continue
            }
            #expect(destructive, "\(title)")
        }
        for title in ["Shared", "Posts", "Comments", "Sharing", "Cancel", "Leaves", "Approved Items", "Allow"] {
            #expect(decide(title, role: "AXRow") == .allow, "\(title)")
        }
        for phrase in ActionSafetyKernel.confirmTitlePhrases {
            #expect(!ActionSafetyKernel.irreversibleTitleKeywords.contains(phrase), "\(phrase) is in both lists")
        }
    }

    // 7 + 8. The heard check: "no, Terminal" names Terminal; "open terminal in cursor" is not "open Terminal".
    @Test func noIsNotANegationAndAnAppInsideAnotherIsNotOpened() {
        func app(_ path: String) -> RealtimeVoiceVerbs.AppName {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return RealtimeVoiceVerbs.AppName(name: url.deletingPathExtension().lastPathComponent, url: url, isFileName: true)
        }
        let apps = [app("/Applications/Cursor.app"), app("/System/Applications/Utilities/Terminal.app"), app("/Applications/Google Chrome.app"),
                    app("/Users/o/Applications/LinkedIn.app")]
        let cursor = URL(fileURLWithPath: "/Applications/Cursor.app", isDirectory: true)
        func outcome(_ transcript: String, named: String, tool: String, target: [String] = []) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: named, among: apps, toolName: tool,
                                      targetWords: RealtimeVoiceVerbs.foldedTokens(target.joined(separator: " ")), frontmostApp: cursor).outcome
        }
        #expect(outcome("no, Terminal", named: "Cursor", tool: "press_menu", target: ["View", "Appearance", "Panel"]) == .heardNamedMismatch)
        #expect(outcome("not Terminal", named: "Cursor", tool: "press_menu", target: ["View", "Appearance", "Panel"]) == .noAppHeard)
        #expect(outcome("open terminal in cursor", named: "Terminal", tool: "open_app") == .ambiguousApp)
        #expect(outcome("open the terminal inside cursor", named: "Terminal", tool: "open_app") == .ambiguousApp)
        #expect(outcome("open chrome and open linkedin on chrome", named: "Google Chrome", tool: "open_app") == .match)
    }

    // 9. A scroll moves when the SAME elements move, or the scroll bar does; at the end it says so.
    @Test func aScrollIsJudgedByPositionsAndTheScrollBar() {
        let clockBefore = [(name: "About", frame: CGRect(x: 300, y: 400, width: 100, height: 20)), (name: "12:41", frame: CGRect(x: 1300, y: 880, width: 40, height: 16))]
        let clockAfter = [(name: "About", frame: CGRect(x: 300, y: 400, width: 100, height: 20)), (name: "12:42", frame: CGRect(x: 1300, y: 880, width: 40, height: 16))]
        #expect(!HarnessScroll.change(before: clockBefore, after: clockAfter, direction: .down).moved, "a clock tick is not a scroll")
        let typing = clockBefore + [(name: "Owner is typing…", frame: CGRect(x: 300, y: 100, width: 200, height: 16))]
        #expect(!HarnessScroll.change(before: clockBefore, after: typing, direction: .down).moved, "an indicator appearing is not a scroll")
        // Down: the content goes UP the screen, AppKit y grows.
        let moved = [(name: "About", frame: CGRect(x: 300, y: 600, width: 100, height: 20))]
        #expect(HarnessScroll.change(before: clockBefore, after: moved, direction: .down).moved)
        #expect(HarnessScroll.outcome(moved: true, barBefore: nil, barAfter: nil, direction: .down) == .moved)
        #expect(HarnessScroll.outcome(moved: false, barBefore: 0.4, barAfter: 0.6, direction: .down) == .moved, "the bar moved")
        #expect(HarnessScroll.outcome(moved: false, barBefore: 1, barAfter: 1, direction: .down) == .atEnd)
        #expect(HarnessScroll.outcome(moved: false, barBefore: 0, barAfter: 0, direction: .up) == .atEnd)
        #expect(HarnessScroll.outcome(moved: false, barBefore: 0, barAfter: 0, direction: .down) == .notObserved)
        #expect(HarnessScroll.outcome(moved: false, barBefore: nil, barAfter: nil, direction: .down) == .notObserved)
    }

    // Scenario A3, run 2026-10-02T23-51-05Z: scroll answered ok, "confirmed",
    // while the page's own scroll offset stayed 0. "Moved" must be the content
    // moving the way it was asked to, and nothing weaker.
    @Test func aScrollIsConfirmedOnlyByContentMovingTheWayAsked() {
        let heading = CGRect(x: 300, y: 400, width: 300, height: 30)
        let before = [(name: "The restoration", frame: heading), (name: "Visiting", frame: CGRect(x: 300, y: 200, width: 120, height: 30))]
        // Nothing in view shared: a different window or page, never proof of a scroll.
        let replaced = [(name: "Skills", frame: heading)]
        #expect(!HarnessScroll.change(before: before, after: replaced, direction: .down).moved)
        // Shifted the wrong way (a late layout pushing content down) is not a scroll down.
        let pushedDown = before.map { (name: $0.name, frame: $0.frame.offsetBy(dx: 0, dy: -40)) }
        #expect(!HarnessScroll.change(before: before, after: pushedDown, direction: .down).moved)
        #expect(HarnessScroll.change(before: before, after: pushedDown, direction: .up).moved)
        // Sideways or resized is a re-layout, not a vertical scroll.
        let sideways = before.map { (name: $0.name, frame: $0.frame.offsetBy(dx: 30, dy: 0)) }
        #expect(!HarnessScroll.change(before: before, after: sideways, direction: .down).moved)
        // Two elements sharing a name are never paired with each other's frame.
        let twins = [(name: "Read more", frame: CGRect(x: 300, y: 500, width: 80, height: 16)),
                     (name: "Read more", frame: CGRect(x: 300, y: 300, width: 80, height: 16))]
        #expect(!HarnessScroll.change(before: twins, after: twins, direction: .down).moved, "nothing moved")
        // Live 2026-10-03 00-29-44Z, A3 3/3: a page scrolled 640 pt and nothing in view
        // was shared — the heading that came in sat BELOW the view before. Known
        // before, anywhere in the walk, is what a frame is compared with.
        let below = (name: "The keeper's cat", frame: CGRect(x: 300, y: -300, width: 300, height: 30))
        let cameIn = [(name: "The keeper's cat", frame: CGRect(x: 300, y: 340, width: 300, height: 30))]
        let scrolled = HarnessScroll.change(before: before + [below], after: cameIn, direction: .down,
                                            inViewBefore: Set(before.map(\.name)))
        #expect(scrolled.moved && scrolled.newlyVisible == ["The keeper's cat"])
        #expect(!HarnessScroll.change(before: before + [below], after: cameIn, direction: .up).moved)
        // Probe 2026-10-03 on the mimic article (AX frames, 900-pt display, as AppKit):
        // Chromium clips what scrolled past to the view's top edge, 1 pt tall, still in
        // view. A3 3/3 and B5 read notVerified while the page moved, on "same size".
        let pageBefore = [(name: "Mimic Weekly", frame: CGRect(x: 24, y: 752, width: 130, height: 24)),
                          (name: "The last lighthouse on Sample Point", frame: CGRect(x: 340, y: 619, width: 760, height: 38))]
        let pageAfter = [(name: "Mimic Weekly", frame: CGRect(x: 24, y: 787, width: 130, height: 1)),
                         (name: "The last lighthouse on Sample Point", frame: CGRect(x: 340, y: 787, width: 760, height: 1)),
                         (name: "Visiting", frame: CGRect(x: 340, y: 380, width: 760, height: 28))]
        #expect(HarnessScroll.change(before: pageBefore, after: pageAfter, direction: .down).moved)
        #expect(!HarnessScroll.change(before: pageBefore, after: pageAfter, direction: .up).moved)
        // B5 live 2026-10-03 00:57:17Z, the second scroll (offset 640 -> 1762): what
        // was left in view was headings and their own text, each pair sharing a name,
        // and what had already been clipped to the top edge did not move again.
        let secondBefore = [(name: "Mimic Weekly", frame: CGRect(x: 24, y: 787, width: 130, height: 1)),
                            (name: "The restoration", frame: CGRect(x: 340, y: 600, width: 760, height: 38)),
                            (name: "The restoration", frame: CGRect(x: 340, y: 600, width: 171, height: 38))]
        let secondAfter = [(name: "Mimic Weekly", frame: CGRect(x: 24, y: 787, width: 130, height: 1)),
                           (name: "The restoration", frame: CGRect(x: 340, y: 787, width: 760, height: 1)),
                           (name: "The restoration", frame: CGRect(x: 340, y: 787, width: 171, height: 1))]
        #expect(HarnessScroll.change(before: secondBefore, after: secondAfter, direction: .down).moved)
        // The bar moving the wrong way is not the scroll asked for.
        #expect(HarnessScroll.outcome(moved: false, barBefore: 0.6, barAfter: 0.4, direction: .down) == .notObserved)
        #expect(HarnessScroll.outcome(moved: false, barBefore: 0.6, barAfter: 0.4, direction: .up) == .moved)
    }

    // 10. Insert puts the caret at the end first; a selection still standing is the owner's, and is never typed over.
    @Test func anInsertNeverTypesOverASelection() {
        #expect(AccessibilityTypePerformer.insertRefusal(caretWriteError: .success, selectedRangeAfter: CFRange(location: 12, length: 0)) == nil)
        #expect(AccessibilityTypePerformer.insertRefusal(caretWriteError: .failure, selectedRangeAfter: CFRange(location: 3, length: 0)) == nil)
        #expect(AccessibilityTypePerformer.insertRefusal(caretWriteError: .failure, selectedRangeAfter: CFRange(location: 0, length: 40)) != nil)
        #expect(AccessibilityTypePerformer.insertRefusal(caretWriteError: .success, selectedRangeAfter: CFRange(location: 0, length: 5)) != nil)
        #expect(AccessibilityTypePerformer.insertRefusal(caretWriteError: .success, selectedRangeAfter: nil) != nil, "unreadable is not empty")
    }

    // 11. A field is named by its title, description or placeholder — never its typed value — and found by any of them.
    @Test func aFieldIsNamedAndFoundByItsPlaceholder() {
        let search = AccessibilityElementNode(role: "AXTextField", subrole: nil, title: nil, value: "draft the owner typed", placeholder: "Search people",
                                              frameInAppKitCoordinates: CGRect(x: 100, y: 800, width: 300, height: 24), depth: 2, children: [])
        let window = AccessibilityElementNode(role: "AXWindow", subrole: nil, title: "LinkedIn", value: nil,
                                              frameInAppKitCoordinates: bounds, depth: 0, children: [search])
        #expect(search.fieldLabel?.raw == "Search people")
        guard case .resolved(let found) = ElementActionIntentResolver.resolve(
            ElementActionIntent(role: nil, title: "Search people", action: .type), inTreeRootedAt: window) else {
            Issue.record("the placeholder did not resolve"); return
        }
        #expect(found.role == "AXTextField")
        let listed = HarnessServer.namedElements(in: window).first { $0["role"] as? String == "AXTextField" }
        #expect(listed?["name"] as? String == "Search people" && listed?["nameSource"] as? String == "placeholder")
        // The result says where it typed, from the harness's own read of the field.
        let told = RealtimeHandsVerbs.result([:], call: RealtimeToolCall(callID: "t", name: "type_text", appName: nil, text: "x"), target: nil,
                                             response: ["resolved": ["role": "AXTextField"], "field": ["label": "Search people"]])
        #expect(told["typedInto"] as? String == "field \"Search people\"")
        let bare = RealtimeHandsVerbs.result([:], call: RealtimeToolCall(callID: "t", name: "type_text", appName: nil, text: "x"), target: nil,
                                             response: ["resolved": ["role": "AXTextArea"]])
        #expect(bare["typedInto"] as? String == "the field with keyboard focus")
    }

    /// 2026-10-06: in a chat app Return SENDS. The voice tool refused a line break,
    /// but the harness's own `type` took one from any socket caller and wrote it by
    /// AX. Now no caller's text carries a control character, and no verb or tool
    /// presses a key — Return can only come from the owner's own hands.
    @Test func noTypingPathCarriesReturnAndNoVerbPressesAKey() {
        for text in ["hello\n", "hello\r", "line\r\nnext", "a\u{2028}b", "tab\there"] {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["verb": "type", "target": "focused", "text": text]), as: UTF8.self)
            guard case .failure(let error) = HarnessPolicy.decode(line: line) else { Issue.record("\(text.debugDescription) decoded"); continue }
            #expect(error.code == "invalidField")
        }
        guard case .success = HarnessPolicy.decode(line: #"{"verb":"type","target":"focused","text":"JARVIS test draft"}"#) else {
            Issue.record("one plain line was refused"); return
        }
        #expect(HarnessVerb.allCases.allSatisfy { !$0.rawValue.lowercased().contains("key") })
        #expect(RealtimeVoiceVerbs.allToolNames.allSatisfy { !$0.contains("key") && !$0.contains("return") && !$0.contains("enter") })
        let refused = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "t", name: "type_text", appName: "net.whatsapp.WhatsApp", text: "hi\n"), expectApp: "net.whatsapp.WhatsApp")
        guard case .failure(let refusal) = refused else { Issue.record("the voice tool typed a line break"); return }
        #expect(refusal.error == "controlCharacterInText")
    }
}
