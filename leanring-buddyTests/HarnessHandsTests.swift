//
//  HarnessHandsTests.swift
//  leanring-buddyTests
//
//  The hands (H1, 2026-10-02): `click`, the `type` keystroke fallback and
//  `openURL` — the pure decisions only. Whether a posted click or keystroke
//  lands is proven by `--hands-probe` on its own Chrome window, not here.
//  Fixtures are SYNTHETIC.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct HarnessHandsTests {

    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func node(_ role: String, _ title: String?, subrole: String? = nil, actions: [String] = [kAXPressAction],
                      frame: CGRect = CGRect(x: 100, y: 100, width: 120, height: 24), subroleReadFailed: Bool = false,
                      description: String? = nil) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: subrole, title: title, value: nil, elementDescription: description,
                                 frameInAppKitCoordinates: frame, depth: 1, children: [], publishedActionNames: actions,
                                 subroleReadFailed: subroleReadFailed)
    }

    private func decide(_ action: ElementAction, _ target: AccessibilityElementNode, title: String) -> SafetyDecision {
        ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: target.role, title: title, action: action),
                                    resolvedNode: target, matchCount: 1, visibleBounds: bounds)
    }

    // MARK: click — the kernel

    // A click is judged as a press wherever a press could run at all.
    @Test func aClickGetsThePressJudgementOnEveryPressableTarget() {
        let titles = ["Log In", "Delete", "Post", "Buy now", "Empty Trash", "Settings", "Sign Out", "Line\nbreak", ""]
        let roles = ["AXButton", "AXLink", "AXRow", "AXCheckBox", "AXImage", "AXStaticText"]
        for role in roles {
            for title in titles {
                let target = node(role, title.isEmpty ? nil : title)
                #expect(decide(.click, target, title: title) == decide(.press, target, title: title), "\(role) \(title.debugDescription)")
            }
        }
        // Off screen and zero area are the same refusals too.
        for frame in [CGRect.zero, CGRect(x: 354, y: -66, width: 459, height: 38).offsetBy(dx: 0, dy: -2000)] {
            let target = node("AXButton", "Go", frame: frame)
            #expect(decide(.click, target, title: "Go") == decide(.press, target, title: "Go"))
        }
    }

    // Where they differ, on purpose: no AXPress needed, a field is ordinary, a password box is refused.
    @Test func aClickNeedsNoPressFocusesFieldsAndNeverAPasswordBox() {
        let silentButton = node("AXButton", "Log In", actions: [])
        #expect(decide(.press, silentButton, title: "Log In") == .refuse(reason: "element does not publish AXPress"))
        #expect(decide(.click, silentButton, title: "Log In") == .allow)
        let field = node("AXTextField", nil, actions: [], description: "Username")
        #expect(decide(.click, field, title: "Username") == .allow)
        #expect(decide(.press, node("AXTextField", nil, description: "Username"), title: "Username")
                == .requireConfirmation(reason: "unrecognised role AXTextField"))
        let password = node("AXTextField", nil, subrole: "AXSecureTextField", actions: [], description: "Password")
        let unreadable = node("AXTextField", nil, actions: [], subroleReadFailed: true, description: "Password")
        for target in [password, unreadable, node("AXSecureTextField", nil, actions: [], description: "Password")] {
            #expect(decide(.click, target, title: "Password") == .refuse(reason: ActionSafetyKernel.secureFieldClickRefusalReason))
        }
        #expect(ActionSafetyKernel.isSecurityRefusal(reason: ActionSafetyKernel.secureFieldClickRefusalReason))
        // A tab by subrole, like a press.
        #expect(decide(.click, node("AXUnknownTab", "Posts", subrole: "AXTabButton"), title: "Posts") == .allow)
    }

    // MARK: click — the act

    @Test func clickMethodsPressFirstExceptOnFieldsAndHonourAForcedMethod() {
        #expect(HarnessHands.clickMethods(publishesPress: true, role: "AXButton", forced: nil) == [.axPress, .click])
        #expect(HarnessHands.clickMethods(publishesPress: false, role: "AXButton", forced: nil) == [.click])
        #expect(HarnessHands.clickMethods(publishesPress: true, role: "AXTextField", forced: nil) == [.click])
        #expect(HarnessHands.clickMethods(publishesPress: true, role: "AXTextArea", forced: nil) == [.click])
        #expect(HarnessHands.clickMethods(publishesPress: true, role: "AXButton", forced: .click) == [.click])
        #expect(HarnessHands.clickMethods(publishesPress: true, role: "AXButton", forced: .axPress) == [.axPress])
        // Forced press with nothing to send is an empty plan — refused, never quietly a click.
        #expect(HarnessHands.clickMethods(publishesPress: false, role: "AXButton", forced: .axPress) == [])
    }

    @Test func aPressIsLookedAtUnlessRefusedAndAToggleIsNeverClickedAfterIt() {
        #expect(HarnessHands.afterPress(error: .success) == .verify)
        #expect(HarnessHands.afterPress(error: .cannotComplete) == .verify)     // may have worked (modal callback)
        #expect(HarnessHands.afterPress(error: .actionUnsupported) == .clickNow)
        #expect(HarnessHands.afterPress(error: .invalidUIElement) == .clickNow)
        #expect(HarnessHands.clickAfterUnverifiedPress(role: "AXButton", subrole: nil))
        #expect(HarnessHands.clickAfterUnverifiedPress(role: "AXLink", subrole: nil))
        for role in ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXSwitch"] {
            #expect(!HarnessHands.clickAfterUnverifiedPress(role: role, subrole: nil), "\(role)")
        }
        #expect(!HarnessHands.clickAfterUnverifiedPress(role: "AXButton", subrole: "AXSwitch"))
    }

    @Test func theClickAimsAtTheVisibleCentreAndNeverOffTheWindow() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(HarnessHands.clickPoint(elementFrame: CGRect(x: 100, y: 100, width: 40, height: 20), windowFrame: window)
                == .success(CGPoint(x: 120, y: 110)))
        // Half under the window's bottom edge: the centre of the part that shows.
        #expect(HarnessHands.clickPoint(elementFrame: CGRect(x: 100, y: -10, width: 40, height: 20), windowFrame: window)
                == .success(CGPoint(x: 120, y: 5)))
        for frame in [CGRect.zero, CGRect(x: 900, y: 100, width: 40, height: 20), CGRect(x: 100, y: 600, width: 40, height: 20),
                      CGRect(x: 100, y: 100, width: 0.5, height: 20)] {
            guard case .failure(let refusal) = HarnessHands.clickPoint(elementFrame: frame, windowFrame: window) else {
                Issue.record("\(frame) was clicked"); continue
            }
            #expect(refusal.code == "targetNotOnScreen")
        }
    }

    @Test func aClickIsPostedOnlyWhereTheHitTestFindsTheTarget() {
        #expect(HarnessHands.hitRefusal(.target) == nil)
        #expect(HarnessHands.hitRefusal(.insideTarget) == nil)
        #expect(HarnessHands.hitRefusal(.harnessItself)?.code == "targetIsHarnessItself")
        for relation in [HarnessHands.HitRelation.otherApp, .otherElementSameApp, .unreadable] {
            #expect(HarnessHands.hitRefusal(relation)?.code == "clickTargetObscured", "\(relation)")
        }
    }

    @Test func aClickIsConfirmedByNamesOrByFocusThatArrived() {
        #expect(HarnessHands.clickEvidence(fingerprintChanged: true, focusedBefore: true, focusedNow: true) == "named elements changed")
        #expect(HarnessHands.clickEvidence(fingerprintChanged: false, focusedBefore: false, focusedNow: true) == "focus moved to the element")
        // Focus that was already there proves nothing.
        #expect(HarnessHands.clickEvidence(fingerprintChanged: false, focusedBefore: true, focusedNow: true) == nil)
        #expect(HarnessHands.clickEvidence(fingerprintChanged: false, focusedBefore: false, focusedNow: false) == nil)
    }

    // MARK: type — the fallback

    @Test func keystrokesFollowOnlyAWriteThatProvablyChangedNothing() {
        func after(_ error: AXError = .success, _ before: Int?, _ after: Int?, contains: Bool = false,
                   forced: TypeMethod? = nil, typed: Int = 5) -> HarnessHands.AfterWrite {
            HarnessHands.afterAXWrite(forced: forced, axError: error, valueLengthBefore: before, valueLengthAfter: after,
                                      containsText: contains, typedCount: typed)
        }
        #expect(after(.success, 0, 5, contains: true) == .done)
        #expect(after(.cannotComplete, 0, 5, contains: true) == .done)          // grew by the text: it landed
        #expect(after(.success, 0, 0) == .keystrokes)                           // Chrome's New Tab box, 2026-10-02
        #expect(after(.failure, 3, 3) == .keystrokes)
        #expect(after(.failure, nil, nil) == .keystrokes)                      // no value, and the app refused the write
        #expect(after(.success, nil, 0) == .keystrokes)
        #expect(after(.success, 0, 0, forced: .axWrite) == .failed)            // forced: no fallback
        let uncertain: [(AXError, Int?, Int?)] = [(.success, 3, 4), (.success, nil, nil), (.success, nil, 2), (.cannotComplete, 0, 2)]
        for (error, before, afterLength) in uncertain {
            guard case .refuse(let refusal) = after(error, before, afterLength) else {
                Issue.record("\(error.rawValue) \(String(describing: before)) -> \(String(describing: afterLength)) typed again"); continue
            }
            #expect(refusal.code == "writeUncertain")
        }
        guard case .refuse(let unreadable) = after(.success, 3, nil) else { Issue.record("unreadable after typed again"); return }
        #expect(unreadable.code == "fieldUnreadable")
    }

    @Test func keystrokesAreRefusedInTheOrderThatProtectsTheOwnerFirst() {
        func refusal(_ text: String = "hello", mode: TypeMode = .insert, before: Int? = 0, secure: Bool = false,
                     focusedSecure: Bool = false, focused: Bool = true, selection: Int? = 0) -> String? {
            HarnessHands.keystrokeRefusal(text: text, mode: mode, valueLengthBefore: before, secureInputOn: secure,
                                          focusedMightBeSecure: focusedSecure, focusedIsTarget: focused, selectionLength: selection)?.code
        }
        #expect(refusal() == nil)
        #expect(refusal(before: 7, selection: 0) == nil)
        #expect(refusal(before: nil, selection: 0) == nil)
        #expect(refusal(before: 0, selection: nil) == nil)                     // nothing to have selected
        #expect(refusal(secure: true, focusedSecure: true, focused: false) == "handOver")
        #expect(refusal(focusedSecure: true, focused: false) == "secureField")
        #expect(refusal("a\nb", focused: false) == "controlCharacters")
        #expect(refusal("tab\there") == "controlCharacters")
        #expect(refusal("line\u{2028}two") == "controlCharacters")
        #expect(refusal(mode: .replace, before: 4) == "replaceNeedsAXWrite")
        #expect(refusal(mode: .replace, before: nil) == "replaceNeedsAXWrite")
        #expect(refusal(mode: .replace, before: 0) == nil)
        #expect(refusal(focused: false) == "fieldNotFocused")
        #expect(refusal(before: 7, selection: nil) == "selectionUnreadable")
        #expect(refusal(before: 7, selection: 3) == "selectionNotEmpty")
        // An emoji joiner and an accent are text, not keys.
        #expect(refusal("👩‍💻 café") == nil)
    }

    @Test func keystrokeChunksStayUnderTheEventLimitAndNeverSplitACharacter() {
        let text = "Hello from the hands probe — 👩‍👩‍👧‍👦 and 🇮🇳, then more text to fill several chunks."
        let chunks = HarnessHands.keystrokeChunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.utf16.count <= HarnessHands.maximumChunkUTF16 })
        #expect(HarnessHands.keystrokeChunks("").isEmpty)
        #expect(HarnessHands.keystrokeChunks("abc", maximum: 2) == ["ab", "c"])
        // A character longer than the limit goes alone, whole.
        let family = "👩‍👩‍👧‍👦"
        #expect(HarnessHands.keystrokeChunks("a" + family, maximum: 4) == ["a", family])
    }

    @Test func keystrokesAreConfirmedByTheValueGrowingByTheTextOrByTheTreeWhenThereIsNoValue() {
        #expect(HarnessHands.keystrokeEvidence(valueLengthBefore: 3, valueLengthAfter: 8, typedCount: 5, fingerprintChanged: false) != nil)
        #expect(HarnessHands.keystrokeEvidence(valueLengthBefore: 3, valueLengthAfter: 6, typedCount: 5, fingerprintChanged: true) == nil)
        #expect(HarnessHands.keystrokeEvidence(valueLengthBefore: nil, valueLengthAfter: nil, typedCount: 5, fingerprintChanged: true) != nil)
        #expect(HarnessHands.keystrokeEvidence(valueLengthBefore: 0, valueLengthAfter: nil, typedCount: 5, fingerprintChanged: false) == nil)
    }

    // MARK: openURL

    @Test func openURLTakesHttpAndHttpsPagesOnly() {
        for good in ["https://www.linkedin.com/feed/", "http://example.com", "HTTPS://Example.com/a?b=c#d"] {
            #expect(HarnessHands.validatedWebURL(good) != nil, "\(good)")
        }
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "ftp://example.com", "https://", "example.com",
                    "https://bank.example@evil.example/", "https://user:pw@example.com", "https://exa mple.com", "https://example.com/\n",
                    "x-apple.systempreferences:com.apple.preference.security", "https://" + String(repeating: "a", count: 2050) + ".com"] {
            #expect(HarnessHands.validatedWebURL(bad) == nil, "\(bad.prefix(60))")
        }
    }

    @Test func openURLGoesOnlyToABrowserAndIsConfirmedByAWindowThatChanged() {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let handlers = [URL(fileURLWithPath: "/Applications/Safari.app"), URL(fileURLWithPath: "/Applications/Google Chrome.app/")]
        #expect(HarnessHands.handlesWeb(appURL: chrome, webHandlers: handlers))
        #expect(!HarnessHands.handlesWeb(appURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), webHandlers: handlers))
        #expect(HarnessHands.openURLEvidence(frontmost: true, windowChanged: true, titleBefore: nil, titleAfter: "New Tab") != nil)
        #expect(HarnessHands.openURLEvidence(frontmost: true, windowChanged: false, titleBefore: "Inbox", titleAfter: "LinkedIn") != nil)
        #expect(HarnessHands.openURLEvidence(frontmost: true, windowChanged: false, titleBefore: "Inbox", titleAfter: "Inbox") == nil)
        #expect(HarnessHands.openURLEvidence(frontmost: false, windowChanged: true, titleBefore: nil, titleAfter: "LinkedIn") == nil)
        #expect(HarnessHands.openURLEvidence(frontmost: true, windowChanged: true, titleBefore: nil, titleAfter: nil) == nil)
    }

    // MARK: the wire

    @Test func theNewVerbsDecodeAndRefuseTheirNearMisses() {
        func decode(_ line: String) -> Result<HarnessRequest, HarnessRequestError> { HarnessPolicy.decode(line: line) }
        guard case .success(let click) = decode(#"{"verb":"click","title":"Log In","expectApp":"Google Chrome","method":"click"}"#) else {
            Issue.record("click did not decode"); return
        }
        #expect(click.verb == .click && click.verb.isMutating && click.verb.elementAction == .click)
        #expect(click.forcedClickMethod == .click && click.forcedTypeMethod == nil)
        guard case .success(let typed) = decode(#"{"verb":"type","title":"Email","text":"a","method":"keystrokes"}"#) else {
            Issue.record("type with a method did not decode"); return
        }
        #expect(typed.forcedTypeMethod == .keystrokes)
        guard case .success(let open) = decode(#"{"verb":"openURL","url":"https://www.linkedin.com/","app":"Google Chrome"}"#) else {
            Issue.record("openURL did not decode"); return
        }
        #expect(open.verb.isMutating && open.verb.elementAction == nil)
        #expect(open.url?.absoluteString == "https://www.linkedin.com/" && open.title == "https://www.linkedin.com/" && open.app == "Google Chrome")
        #expect(HarnessServer.auditTarget(for: open) == "https://www.linkedin.com/")
        guard case .success(let atPoint) = decode(#"{"verb":"click","title":"Log In","nearPoint":{"x":1,"y":2},"requireAtPoint":true}"#) else {
            Issue.record("click with requireAtPoint did not decode"); return
        }
        #expect(atPoint.requireAtPoint)

        let refused: [(String, String)] = [
            (#"{"verb":"click"}"#, "missingField"),
            (#"{"verb":"click","title":"x","method":"keystrokes"}"#, "invalidField"),
            (#"{"verb":"type","title":"x","text":"a","method":"click"}"#, "invalidField"),
            (#"{"verb":"press","title":"x","method":"axPress"}"#, "invalidField"),
            (#"{"verb":"openURL"}"#, "missingField"),
            (#"{"verb":"openURL","url":"file:///etc/passwd"}"#, "invalidField"),
            (#"{"verb":"openURL","url":"javascript:alert(1)"}"#, "invalidField"),
            (#"{"verb":"openURL","url":"https://example.com","app":"/Applications/Terminal.app"}"#, "invalidField"),
            (#"{"verb":"press","title":"x","url":"https://example.com"}"#, "invalidField")
        ]
        for (line, code) in refused {
            guard case .failure(let error) = decode(line) else { Issue.record("accepted \(line)"); continue }
            #expect(error.code == code, "\(line)")
        }
    }

    // The kill switch stops the hands; the hand-over stops typing first, never clicking.
    @Test func theKillSwitchStopsTheHandsAndTheHandOverStopsOnlyTyping() {
        for verb in [HarnessVerb.click, .openURL, .type] {
            #expect(HarnessPolicy.killSwitchRefusal(verb: verb, killSwitchPresent: true) != nil, "\(verb)")
        }
        let on = SecureInputState(isOn: true, holderPID: nil, holderName: nil, holderIsFrontmost: nil)
        #expect(HarnessPolicy.handOverRefusal(verb: .type, secureInput: on) != nil)
        #expect(HarnessPolicy.handOverRefusal(verb: .click, secureInput: on) == nil)
        #expect(HarnessPolicy.handOverRefusal(verb: .openURL, secureInput: on) == nil)
    }
}
