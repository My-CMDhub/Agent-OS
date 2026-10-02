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

    // Review of H1: a click after a press that went in is a second activation.
    @Test func aPressIsLookedAtAndOnlyARefusedPressIsFollowedByAClick() {
        #expect(HarnessHands.afterPress(error: .success) == .verify)
        #expect(HarnessHands.afterPress(error: .cannotComplete) == .verify)     // may have worked (modal callback)
        #expect(HarnessHands.afterPress(error: .actionUnsupported) == .clickNow)
        #expect(HarnessHands.afterPress(error: .invalidUIElement) == .clickNow)
        #expect(!HarnessHands.clickFollowsPress(error: .success))
        #expect(!HarnessHands.clickFollowsPress(error: .cannotComplete))
        #expect(HarnessHands.clickFollowsPress(error: .actionUnsupported))
        #expect(HarnessHands.clickFollowsPress(error: .invalidUIElement))
    }

    // Review of H1 (blocking): a card group's centre may be its own "Buy now" child.
    @Test func aClickPassesOnlyThroughInertElementsToItsTarget() {
        typealias Node = HarnessHands.HitChainNode
        func relation(_ chain: [Node], reachedTarget: Bool = true, targetPublishesPress: Bool = true) -> HarnessHands.HitRelation {
            HarnessHands.relation(hitChain: chain, reachedTarget: reachedTarget, targetPublishesPress: targetPublishesPress)
        }
        #expect(relation([]) == .target)
        // A label inside the button (Chromium's text publishes AXPress too): through.
        #expect(relation([Node(role: "AXStaticText", name: "Log In", publishesPress: true)]) == .insideTarget)
        #expect(relation([Node(role: "AXStaticText", name: "Order #123"), Node(role: "AXGroup")]) == .insideTarget)
        let active: [[Node]] = [
            [Node(role: "AXStaticText", name: "Buy"), Node(role: "AXButton", name: "Buy now")],
            [Node(role: "AXLink", name: "Profile")],
            [Node(role: "AXTextField")],
            [Node(role: "AXTextField", subroleReadFailed: true)],
            [Node(role: "AXGroup", subrole: "AXSecureTextField")],
            [Node(role: "AXStaticText", name: "Buy now")],
            [Node(role: "AXStaticText", name: "Delete draft")],
            [Node(role: "AXGroup", name: "Post")],
            [Node(role: "AXRadioButton", subrole: "AXTabButton", name: "Posts")],
            [Node(role: "AXUnknown", subrole: "AXTabButton", name: "Posts")]
        ]
        for chain in active {
            #expect(relation(chain) == .activeInsideTarget, "\(chain)")
        }
        #expect(HarnessHands.hitRefusal(.activeInsideTarget)?.code == "clickTargetObscured")
        #expect(relation([Node(role: "AXStaticText")], reachedTarget: false) == .otherElementSameApp)
        // Review 2026-10-02: the target "Order #42" group publishes no AXPress, and an
        // unlabelled clickable icon sits at its centre. That icon is what a click acts on.
        let icon = [Node(role: "AXImage", publishesPress: true), Node(role: "AXGroup")]
        #expect(relation(icon, targetPublishesPress: false) == .activeInsideTarget)
        #expect(relation([Node(role: "AXStaticText", name: "Order #42"), Node(role: "AXGroup", publishesPress: true)],
                         targetPublishesPress: false) == .activeInsideTarget)
        #expect(relation([Node(role: "AXStaticText", name: "Order #42"), Node(role: "AXGroup")], targetPublishesPress: false) == .insideTarget)
        // Inside a target that publishes AXPress itself, the Chromium allowance stands.
        #expect(relation(icon, targetPublishesPress: true) == .insideTarget)
    }

    // Review of H1: the click and every keystroke chunk need the target's app still in front.
    @Test func nothingIsPostedOnceAnotherAppIsInFront() {
        #expect(HarnessHands.postRefusal(frontmostIsTarget: false, hit: .target)?.code == "frontmostChanged")
        #expect(HarnessHands.postRefusal(frontmostIsTarget: true, hit: .target) == nil)
        #expect(HarnessHands.postRefusal(frontmostIsTarget: true, hit: .otherApp)?.code == "clickTargetObscured")
        #expect(HarnessHands.chunkStopReason(secureInputOn: false, frontmostIsTarget: true, focusIsOnTarget: true, ownerIdle: true) == nil)
        #expect(HarnessHands.chunkStopReason(secureInputOn: true, frontmostIsTarget: false, focusIsOnTarget: false, ownerIdle: false) == "handOver")
        #expect(HarnessHands.chunkStopReason(secureInputOn: false, frontmostIsTarget: false, focusIsOnTarget: true, ownerIdle: true) == "frontmostChanged")
        #expect(HarnessHands.chunkStopReason(secureInputOn: false, frontmostIsTarget: true, focusIsOnTarget: false, ownerIdle: true) == "focusMoved")
        #expect(HarnessHands.chunkStopReason(secureInputOn: false, frontmostIsTarget: true, focusIsOnTarget: true, ownerIdle: false) == "ownerActive")
        // The owner switches apps after the first chunk: the second is never posted.
        final class Posted { var chunks: [String] = []; var asked: [Int] = [] }
        let posted = Posted()
        let outcome = HarnessHands.postChunks(["hello ", "world ", "again"], stopReason: { index in
            posted.asked.append(index)
            return HarnessHands.chunkStopReason(secureInputOn: false, frontmostIsTarget: index < 1, focusIsOnTarget: true, ownerIdle: true)
        }, post: { posted.chunks.append($0); return true })
        #expect(posted.chunks == ["hello "])
        #expect(posted.asked == [0, 1])                          // asked before the FIRST chunk too
        #expect(outcome.charactersPosted == 6 && outcome.stoppedBecause == "frontmostChanged")
        let refusedAtOnce = HarnessHands.postChunks(["a"], stopReason: { _ in "frontmostChanged" }, post: { _ in Issue.record("posted"); return true })
        #expect(refusedAtOnce.charactersPosted == 0 && refusedAtOnce.stoppedBecause == "frontmostChanged")
        let failed = HarnessHands.postChunks(["a", "b"], stopReason: { _ in nil }, post: { $0 == "a" })
        #expect(failed.charactersPosted == 1 && failed.stoppedBecause == "eventCreationFailed")
    }

    // Our own click or chunk resets every idle counter; the owner's input does not get discounted.
    @Test func theOwnerIsIdleUnlessTheirInputIsNewerThanOurs() {
        #expect(HarnessHands.ownerIsIdle(secondsSinceLastInput: 5, secondsSinceOurLastPost: nil))
        #expect(!HarnessHands.ownerIsIdle(secondsSinceLastInput: 0.2, secondsSinceOurLastPost: nil))
        #expect(HarnessHands.ownerIsIdle(secondsSinceLastInput: 0.2, secondsSinceOurLastPost: 0.25))     // the input was our click
        #expect(!HarnessHands.ownerIsIdle(secondsSinceLastInput: 0.1, secondsSinceOurLastPost: 0.6))     // the owner moved after it
        #expect(HarnessHands.ownerIsIdle(secondsSinceLastInput: 1.0, secondsSinceOurLastPost: 30))
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
                     focusedSecure: Bool = false, focused: Bool = true, selection: Int? = 0, frontmost: Bool = true,
                     idle: Bool = true, caret: Int? = nil, lengthUTF16: Int? = nil) -> String? {
            HarnessHands.keystrokeRefusal(text: text, mode: mode, valueLengthBefore: before, secureInputOn: secure,
                                          focusedMightBeSecure: focusedSecure, focusedIsTarget: focused, selectionLength: selection,
                                          frontmostIsTarget: frontmost, ownerIdle: idle, caretLocation: caret, valueLengthUTF16: lengthUTF16)?.code
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
        // Review of H1: another app in front, the owner typing, a caret mid-text, a character no event can carry.
        #expect(refusal(frontmost: false) == "frontmostChanged")
        #expect(refusal(secure: true, frontmost: false) == "handOver")
        #expect(refusal(frontmost: false, idle: false) == "frontmostChanged")
        #expect(refusal(idle: false) == "ownerActive")
        #expect(refusal(before: 7, caret: 3, lengthUTF16: 7) == "caretNotAtEnd")
        #expect(refusal(before: 7, caret: 7, lengthUTF16: 7) == nil)
        #expect(refusal(mode: .replace, before: 0, caret: 0, lengthUTF16: 0) == nil)
        #expect(refusal("a" + String(repeating: "\u{0301}", count: 25)) == "characterTooLong")
    }

    // Review 2026-10-02: the owner idle is checked before the focusing click, not after it.
    @Test func theOwnerIsIdleBeforeTheFocusingClickAndTheKeys() {
        var steps: [String] = []
        let refused = HarnessHands.idleThenFocusThenType(
            ownerIdle: { steps.append("idle"); return false },
            focus: { steps.append("focus"); return [:] },
            type: { steps.append("type"); return .refused(HandsRefusal(code: "x", message: "x")) })
        #expect(steps == ["idle"] && refused.focus == nil)
        guard case .refused(let refusal) = refused.outcome else { Issue.record("typed while the owner was active"); return }
        #expect(refusal.code == "ownerActive")
        steps = []
        let typed = HarnessHands.idleThenFocusThenType(
            ownerIdle: { steps.append("idle"); return true },
            focus: { steps.append("focus"); return ["method": "click"] },
            type: { steps.append("type"); return .posted(payload: [:], evidence: "e") })
        #expect(steps == ["idle", "focus", "type"] && typed.focus?["method"] as? String == "click")
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

    // H1 probe 2026-10-02: the AX write never took in a Chrome page and cost ~3 s before the keystrokes that did.
    @Test func webFieldsGoStraightToKeystrokesAndNativeFieldsKeepTheWriteFirst() {
        #expect(HarnessHands.typeStartsWithKeystrokes(forced: nil, inWebContent: true))
        #expect(!HarnessHands.typeStartsWithKeystrokes(forced: nil, inWebContent: false))
        #expect(HarnessHands.typeStartsWithKeystrokes(forced: .keystrokes, inWebContent: false))
        #expect(!HarnessHands.typeStartsWithKeystrokes(forced: .axWrite, inWebContent: true))   // the probe's forced write still runs
        #expect(HarnessHands.isWebHost(bundleIdentifier: "com.google.Chrome", frameworkNames: ["Google Chrome Framework.framework"]))
        #expect(HarnessHands.isWebHost(bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                                       frameworkNames: ["Cursor Helper.app", "Electron Framework.framework", "Squirrel.framework"]))
        #expect(HarnessHands.isWebHost(bundleIdentifier: "com.apple.Safari", frameworkNames: []))
        #expect(HarnessHands.isWebHost(bundleIdentifier: "com.apple.Safari.WebApp.3AD71A25-F059-469E-91A4-1A7E10464C02", frameworkNames: []))
        #expect(!HarnessHands.isWebHost(bundleIdentifier: "com.apple.TextEdit", frameworkNames: []))
        #expect(!HarnessHands.isWebHost(bundleIdentifier: "com.apple.mail", frameworkNames: ["Sparkle.framework"]))
        #expect(!HarnessHands.isWebHost(bundleIdentifier: nil, frameworkNames: []))
    }

    // MARK: openURL

    @Test func openURLTakesHttpAndHttpsPagesOnly() {
        for good in ["https://www.linkedin.com/feed/", "http://example.com", "HTTPS://Example.com/a?b=c#d"] {
            #expect(HarnessHands.validatedWebURL(good) != nil, "\(good)")
        }
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "ftp://example.com", "https://", "example.com",
                    "https://bank.example@evil.example/", "https://user:pw@example.com", "https://exa mple.com", "https://example.com/\n",
                    "https://bank.example%40evil.example/", "https://bank.example%40evil.example",
                    "x-apple.systempreferences:com.apple.preference.security", "https://" + String(repeating: "a", count: 2050) + ".com"] {
            #expect(HarnessHands.validatedWebURL(bad) == nil, "\(bad.prefix(60))")
        }
    }

    // Review of H1: an address is judged like a control's name, and the owner's own network is asked about.
    @Test func openURLAsksAboutPrivateHostsAndRefusesIrreversibleAddresses() {
        func decide(_ string: String) -> SafetyDecision? { HarnessHands.validatedWebURL(string).map(HarnessHands.openURLDecision) }
        for page in ["https://www.linkedin.com/feed/", "https://example.com/", "https://www.google.com/search?q=linkedin",
                     "https://fcbarcelona.com/", "https://172.32.0.1/", "https://8.8.8.8/"] {
            #expect(decide(page) == .allow, "\(page)")
        }
        for page in ["http://localhost:3000/", "http://127.0.0.1/", "http://192.168.1.1/admin", "http://10.0.0.1/", "http://172.16.4.2/",
                     "http://169.254.1.1/", "http://printer.local/", "http://[::1]:8080/", "http://app.localhost/"] {
            guard case .requireConfirmation(_, false)? = decide(page) else { Issue.record("\(page) was not asked about"); continue }
        }
        guard case .refuse? = decide("https://shop.example/checkout/buy?item=1") else { Issue.record("buy was not refused"); return }
        guard case .refuse? = decide("https://bank.example/transfer?action=pay") else { Issue.record("pay was not refused"); return }
        guard case .requireConfirmation(_, true)? = decide("https://mail.example/messages/delete?id=4") else { Issue.record("delete not asked"); return }
        guard case .requireConfirmation(_, true)? = decide("https://social.example/compose?then=post") else { Issue.record("post not asked"); return }
        #expect(HarnessHands.auditableURL(URL(string: "https://www.google.com/search?q=my+address#frag")!) == "https://www.google.com/search")
    }

    // Review 2026-10-02: the fragment is words too, camelCase hides them, and loopback has many spellings.
    @Test func openURLReadsEveryWordAndEverySpellingOfThisMac() {
        func decide(_ string: String) -> SafetyDecision? { HarnessHands.validatedWebURL(string).map(HarnessHands.openURLDecision) }
        guard case .refuse? = decide("https://app.example/#/checkout/buy") else { Issue.record("buy in the fragment was not refused"); return }
        for page in ["https://app.example/api/deleteAll", "https://app.example/x?op=removeUser", "https://app.example/#sendNow",
                     // "%25zz" decodes to a malformed "%zz": the old reading emptied the words and allowed it.
                     "https://app.example/delete/%25zz"] {
            guard case .requireConfirmation(_, true)? = decide(page) else { Issue.record("\(page) was not asked"); continue }
        }
        #expect(HarnessHands.urlWords(URL(string: "https://a.example/api/deleteAll?x=1#Top")!) == " api delete all x 1 top")
        for host in ["localhost.", "127.1", "2130706433", "0x7f000001", "::ffff:127.0.0.1", "[::ffff:7f00:1]", "0177.0.0.1", "127.0.0.1.",
                     "::", "::1", "fe80::1", "fd00::1", "::ffff:192.168.1.1"] {
            #expect(HarnessHands.isPrivateHost(host), "\(host)")
        }
        for host in ["8.8.8.8", "example.com", "fcbarcelona.com", "::ffff:8.8.8.8", "2001:4860:4860::8888", "172.32.0.1", "deleteall.example"] {
            #expect(!HarnessHands.isPrivateHost(host), "\(host)")
        }
        for page in ["http://localhost.:3000/", "http://127.1/", "http://2130706433/", "http://0x7f000001/", "http://[::ffff:127.0.0.1]/"] {
            guard case .requireConfirmation(_, false)? = decide(page) else { Issue.record("\(page) was not asked about"); continue }
        }
    }

    // Review of H1: "confirmed" only from the page's own address.
    @Test func openURLIsConfirmedOnlyByThePagesOwnHost() {
        #expect(HarnessHands.openURLVerification(evidence: "x", pageHost: "www.linkedin.com", requestedHost: "linkedin.com") == "confirmed")
        #expect(HarnessHands.openURLVerification(evidence: "x", pageHost: "accounts.google.com", requestedHost: "www.google.com") == "confirmed")
        #expect(HarnessHands.openURLVerification(evidence: "x", pageHost: nil, requestedHost: "linkedin.com") == "browserReacted")
        #expect(HarnessHands.openURLVerification(evidence: "x", pageHost: "evil.example", requestedHost: "linkedin.com") == "pageHostDiffers")
        #expect(HarnessHands.openURLVerification(evidence: nil, pageHost: "linkedin.com", requestedHost: "linkedin.com") == "notObserved")
        #expect(!HarnessHands.hostMatches(page: "notlinkedin.com", requested: "linkedin.com"))
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
        guard case .success(let searched) = decode(#"{"verb":"openURL","url":"https://www.google.com/search?q=secret"}"#) else {
            Issue.record("openURL with a query did not decode"); return
        }
        #expect(HarnessServer.auditTarget(for: searched) == "https://www.google.com/search")
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
