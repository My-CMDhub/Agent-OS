//
//  HarnessHands.swift
//  leanring-buddy
//
//  The hands (design 2026-10-02 "hands that work", H1): `click`, the `type`
//  keystroke fallback and `openURL`. Structure aims, real input acts, structure
//  verifies. The decisions here are pure and tested; the CGEvent posting and
//  the few AX reads it needs are the thin impure tail at the bottom. The
//  request flow (kernel, gate, audit) lives in `HarnessServer`.
//
//  Evidence (docs/superpowers/specs/live-scenarios.csv, 2026-10-02): 37 live
//  turns, 21 failed; "AX write failed on a contenteditable", "AX write failed"
//  into Chrome's New Tab box, "no click-to-focus tool", "no open-URL tool".
//

import AppKit
import ApplicationServices
import Foundation

/// How a click was (or may be forced to be) delivered.
enum ClickMethod: String, CaseIterable {
    case axPress
    case click
}

/// How text was (or may be forced to be) entered.
enum TypeMethod: String, CaseIterable {
    case axWrite
    case keystrokes
}

/// A refusal with a wire code, from a pure decision.
struct HandsRefusal: Error, Equatable {
    let code: String
    let message: String
}

enum HarnessHands {

    // MARK: click — pure

    /// The methods a click tries, in order. `AXPress` first when the element
    /// publishes it and is not a text input (pressing a field focuses nothing in
    /// Chromium); a forced method runs alone, and a forced `axPress` on an element
    /// that publishes none is an empty plan — refused, never quietly a click.
    static func clickMethods(publishesPress: Bool, role: String, forced: ClickMethod?) -> [ClickMethod] {
        switch forced {
        case .axPress: return publishesPress ? [.axPress] : []
        case .click: return [.click]
        case nil:
            let textInput = AccessibilityElementNode.textInputRoles.contains(role)
            return publishesPress && !textInput ? [.axPress, .click] : [.click]
        }
    }

    enum AfterPress: Equatable {
        /// The press went in (or timed out, which may still have worked): look first.
        case verify
        /// The app refused the press outright: nothing happened, click now.
        case clickNow
    }

    /// `-25204` is not reliably a failure (Apple: modal processing may exceed the
    /// timeout and still have worked), so it is verified like a success.
    static func afterPress(error: AXError) -> AfterPress {
        error == .success || error == .cannotComplete ? .verify : .clickNow
    }

    /// Controls a second activation would undo. A press that took and changed no
    /// name is still a press; clicking a toggle after it flips it back.
    static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXSwitch"]
    static let toggleSubroles: Set<String> = ["AXSwitch", "AXToggle"]

    /// After a press nobody could see, whether a real click follows.
    static func clickAfterUnverifiedPress(role: String, subrole: String?) -> Bool {
        !toggleRoles.contains(role) && !(subrole.map(toggleSubroles.contains) ?? false)
    }

    /// The point a synthetic click aims at: the centre of the part of the element
    /// inside the window (AppKit coordinates). An element half under the window's
    /// edge is clicked where it shows, never at a centre that is off the window.
    static func clickPoint(elementFrame: CGRect, windowFrame: CGRect) -> Result<CGPoint, HandsRefusal> {
        let visible = elementFrame.intersection(windowFrame)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            return .failure(HandsRefusal(code: "targetNotOnScreen",
                                         message: "no part of the element is inside the window; nothing was clicked"))
        }
        return .success(CGPoint(x: visible.midX, y: visible.midY))
    }

    /// What the system hit test found at the click point, relative to the target.
    enum HitRelation: String, Equatable {
        case target, insideTarget, otherElementSameApp, otherApp, harnessItself, unreadable
    }

    /// A synthetic click lands on whatever is drawn at the point, so it is posted
    /// only when that is the element the kernel judged — or something inside it.
    static func hitRefusal(_ relation: HitRelation) -> HandsRefusal? {
        switch relation {
        case .target, .insideTarget: return nil
        case .harnessItself:
            return HandsRefusal(code: "targetIsHarnessItself", message: HarnessServer.harnessItselfMessage)
        case .otherApp:
            return HandsRefusal(code: "clickTargetObscured", message: "another window covers that point; nothing was clicked")
        case .otherElementSameApp:
            return HandsRefusal(code: "clickTargetObscured",
                                message: "something else in the app is drawn over the element at that point; nothing was clicked")
        case .unreadable:
            return HandsRefusal(code: "clickTargetObscured",
                                message: "what is drawn at that point could not be checked; nothing was clicked")
        }
    }

    /// A click's evidence: the window's names changed, or focus moved onto the
    /// element (a field gains focus and nothing else changes). Focus that was
    /// already there proves nothing.
    static func clickEvidence(fingerprintChanged: Bool, focusedBefore: Bool, focusedNow: Bool) -> String? {
        if fingerprintChanged { return "named elements changed" }
        if !focusedBefore && focusedNow { return "focus moved to the element" }
        return nil
    }

    // MARK: type — pure

    enum AfterWrite: Equatable {
        /// The field reads back the text.
        case done
        /// Forced `axWrite` and it did not take: performFailed, as before.
        case failed
        case keystrokes
        case refuse(HandsRefusal)
    }

    /// After the AX write: done, or keystrokes, or neither. Keystrokes only when
    /// nothing suggests the write landed — a field that moved, but not into the
    /// text, may have taken it asynchronously (Finder's write applied late,
    /// 2026-09-10), and typing again would enter it twice. Lengths are nil when
    /// the value could not be read: never read as 0 (read failures are never absence).
    static func afterAXWrite(forced: TypeMethod?, axError: AXError, valueLengthBefore: Int?, valueLengthAfter: Int?,
                             containsText: Bool, typedCount: Int) -> AfterWrite {
        if containsText, axError == .success || valueLengthBefore.map({ valueLengthAfter == $0 + typedCount }) ?? true {
            return .done
        }
        if forced == .axWrite { return .failed }
        let uncertain = HandsRefusal(code: "writeUncertain",
                                     message: "the field may have taken the write without reading back the text; typing again could enter it twice, so nothing more was typed")
        switch (valueLengthBefore, valueLengthAfter) {
        case (nil, nil):
            // A field that publishes no value: only a write the app refused is known not to have landed.
            return axError == .success ? .refuse(uncertain) : .keystrokes
        case (.some, nil):
            return .refuse(HandsRefusal(code: "fieldUnreadable",
                                        message: "the field stopped answering after the write, so whether the text landed is unknown; nothing more was typed"))
        case (nil, .some(let after)):
            return after == 0 ? .keystrokes : .refuse(uncertain)
        case (.some(let before), .some(let after)):
            return after == before ? .keystrokes : .refuse(uncertain)
        }
    }

    /// Return, Tab and the like are keys that act (submit, move focus), not text.
    /// v1 types none of them (design: "No Return/Enter in v1").
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
    }

    /// Why keystrokes may not be posted into the field, or nil. Checked right
    /// before posting; secure input and focus are checked again per chunk.
    static func keystrokeRefusal(text: String, mode: TypeMode, valueLengthBefore: Int?, secureInputOn: Bool,
                                 focusedMightBeSecure: Bool, focusedIsTarget: Bool, selectionLength: Int?) -> HandsRefusal? {
        if secureInputOn {
            return HandsRefusal(code: "handOver", message: "secure typing is on — a password is the owner's to type; no keystrokes were posted")
        }
        if focusedMightBeSecure {
            return HandsRefusal(code: "secureField", message: ActionSafetyKernel.unreadableSubroleTypeRefusalReason)
        }
        if containsControlCharacters(text) {
            return HandsRefusal(code: "controlCharacters",
                                message: "the text holds Return, Tab or another control character; keystrokes never send those in v1")
        }
        // Unreadable is not empty: there may be text a replace would have to remove.
        if mode == .replace, valueLengthBefore != 0 {
            return HandsRefusal(code: "replaceNeedsAXWrite",
                                message: "keystrokes insert; they cannot replace what is already in the field (or could not be read)")
        }
        if !focusedIsTarget {
            return HandsRefusal(code: "fieldNotFocused",
                                message: "keyboard focus is not on the field, so keystrokes would land elsewhere; none were posted")
        }
        // An unreadable selection is not an empty one — unless there is no text to select.
        guard let selectionLength else {
            return valueLengthBefore == 0 ? nil : HandsRefusal(
                code: "selectionUnreadable",
                message: "the field's selection could not be read, so keystrokes might replace selected text; none were posted")
        }
        if selectionLength > 0 {
            return HandsRefusal(code: "selectionNotEmpty",
                                message: "\(selectionLength) characters are selected; keystrokes would replace them, so none were posted")
        }
        return nil
    }

    /// `CGEventKeyboardSetUnicodeString` carries at most 20 UTF-16 units per event.
    static let maximumChunkUTF16 = 20
    /// ponytail: a fixed gap between chunks, generous for a web page's input
    /// handlers; tune it against the probe's contenteditable timings, or make it
    /// adaptive (wait for the value to grow) if a slower field drops characters.
    static let interChunkDelaySeconds = 0.03

    /// The text in chunks of at most `maximum` UTF-16 units, never splitting a
    /// character (a split surrogate pair or emoji types as garbage).
    static func keystrokeChunks(_ text: String, maximum: Int = maximumChunkUTF16) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            if !current.isEmpty, current.utf16.count + character.utf16.count > maximum {
                chunks.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Keystrokes' evidence: the field's value grew by exactly the text, or — for
    /// a field that publishes no value — the window's text changed. A readable
    /// value that did not grow is a failure, whatever else moved.
    static func keystrokeEvidence(valueLengthBefore: Int?, valueLengthAfter: Int?, typedCount: Int,
                                  fingerprintChanged: Bool) -> String? {
        guard let valueLengthBefore, let valueLengthAfter else {
            return fingerprintChanged ? "the window's text changed (the field publishes no readable value)" : nil
        }
        return valueLengthAfter == valueLengthBefore + typedCount ? "the field's value grew by the text's length" : nil
    }

    // MARK: openURL — pure

    static let maximumURLLength = 2048

    /// http/https with a host, nothing else: no `file:`, `javascript:`, `data:`,
    /// no credentials in the URL (`https://bank.com@evil.example`), no
    /// whitespace or control characters.
    static func validatedWebURL(_ string: String) -> URL? {
        guard string.count <= maximumURLLength,
              !string.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }),
              let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// Only an app LaunchServices lists as a web handler may be handed a URL —
    /// "open https://… in Terminal" is not a browser opening a page.
    static func handlesWeb(appURL: URL, webHandlers: [URL]) -> Bool {
        webHandlers.contains { $0.standardizedFileURL.path == appURL.standardizedFileURL.path }
    }

    /// The browser came forward and its front window is new or retitled.
    static func openURLEvidence(frontmost: Bool, windowChanged: Bool, titleBefore: String?, titleAfter: String?) -> String? {
        guard frontmost, let titleAfter else { return nil }
        if windowChanged { return "a new browser window came forward" }
        return titleAfter != titleBefore ? "the front window's title changed" : nil
    }

    static let openURLDeadlineSeconds = 5.0

    // MARK: Impure tail — AX reads and posted input

    /// Parents walked from a hit-tested element looking for the target. Chromium
    /// nests to depth 38; the hit element is a leaf a few levels below its control.
    static let ancestorWalkLimit = 40

    /// Whether `element` is `target` or sits inside it, by identity (`CFEqual`).
    static func isSelfOrDescendant(_ element: AXUIElement, of target: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<ancestorWalkLimit {
            guard let node = current else { return false }
            if CFEqual(node, target) { return true }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    /// What the system draws at a global top-left point, relative to the target.
    static func hitRelation(atTopLeft point: CGPoint, target: AXUIElement, processIdentifier: pid_t) -> HitRelation {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, RealtimeScreenHitTest.messagingTimeoutSeconds)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, let hit else {
            return .unreadable
        }
        var hitProcess: pid_t = 0
        guard AXUIElementGetPid(hit, &hitProcess) == .success else { return .unreadable }
        if hitProcess == getpid() { return .harnessItself }
        guard hitProcess == processIdentifier else { return .otherApp }
        if CFEqual(hit, target) { return .target }
        return isSelfOrDescendant(hit, of: target) ? .insideTarget : .otherElementSameApp
    }

    /// The app's keyboard focus, read live from the app itself.
    static func focusedElement(processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Focus is on the target or inside it (a contenteditable's inner node).
    static func focusIsOn(_ target: AXUIElement, processIdentifier: pid_t) -> Bool {
        focusedElement(processIdentifier: processIdentifier).map { isSelfOrDescendant($0, of: target) } ?? false
    }

    /// Whether the focused element may be a password box — role and subrole
    /// only, never its value; a failed subrole read counts as "may be".
    static func focusedMightBeSecure(processIdentifier: pid_t) -> Bool {
        guard let focused = focusedElement(processIdentifier: processIdentifier) else { return false }
        var role: AnyObject?
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role)
        let subroleError = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        return AccessibilityElementNode.mightBeSecure(role: role as? String ?? "AXUnknown", subrole: subrole as? String,
                                                      subroleReadFailed: AccessibilityElementNode.subroleReadFailed(subroleError),
                                                      namedByValue: true)
    }

    /// Polls `condition` every 50 ms until it holds or `seconds` pass.
    @discardableResult
    static func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return condition()
    }

    /// A left click at a global top-left point (CGEvent's origin, like AX's —
    /// convert AppKit frames with `SyntheticScroller.topLeftCentre`).
    @discardableResult
    static func postClick(atTopLeft point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        // A held modifier must not turn the click into a Cmd-click (new tab) or a Ctrl-click (menu).
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// One chunk as a key down/up pair carrying the text itself, so no keyboard
    /// layout is involved. Modifiers cleared, or a held Cmd makes it a shortcut.
    @discardableResult
    static func postUnicode(_ chunk: String) -> Bool {
        let units = Array(chunk.utf16)
        guard units.count <= maximumChunkUTF16,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: Impure tail — the three acts

    /// The element's frame read live (a walk's copy may be hundreds of ms old), in AppKit coordinates.
    static func liveAppKitFrame(of element: AXUIElement) -> CGRect? {
        AccessibilityTreeWalker.copyFrame(from: element).frame.map {
            AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                $0, primaryDisplayHeightInPoints: CGDisplayBounds(CGMainDisplayID()).height)
        }
    }

    /// The synthetic click, every check first: the element's visible centre, the
    /// hit test there must be this element (or inside it), then the posted click.
    /// Returns the top-left point clicked.
    static func clickElement(_ element: AXUIElement, windowFrame: CGRect, processIdentifier: pid_t) -> Result<CGPoint, HandsRefusal> {
        guard let frame = liveAppKitFrame(of: element) else {
            return .failure(HandsRefusal(code: "frameUnreadable", message: "the element's AXPosition/AXSize could not be read; nothing was clicked"))
        }
        let point: CGPoint
        switch clickPoint(elementFrame: frame, windowFrame: windowFrame) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let centre): point = centre
        }
        let topLeft = SyntheticScroller.topLeftCentre(ofAppKitFrame: CGRect(origin: point, size: .zero),
                                                      primaryDisplayHeightInPoints: CGDisplayBounds(CGMainDisplayID()).height)
        if let refusal = hitRefusal(hitRelation(atTopLeft: topLeft, target: element, processIdentifier: processIdentifier)) {
            return .failure(refusal)
        }
        guard postClick(atTopLeft: topLeft) else {
            return .failure(HandsRefusal(code: "eventCreationFailed", message: "the click event could not be created; nothing was clicked"))
        }
        return .success(topLeft)
    }

    /// How long a focus change gets to show in the app's own focus read.
    static let focusSettleSeconds = 0.5

    /// Focus the field before typing: already focused, else an `AXFocused` write
    /// verified by the app's own focus read (an `AXFocused` read-back is the kind
    /// of answer that has lied in this repo), else a click on it. Never fatal to
    /// the AX write, which needs no focus; keystrokes refuse without it.
    static func focusForTyping(_ element: AXUIElement, windowFrame: CGRect, processIdentifier: pid_t,
                               focusSettable: Bool) -> [String: Any] {
        if focusIsOn(element, processIdentifier: processIdentifier) { return ["method": "alreadyFocused", "focused": true] }
        var report: [String: Any] = ["method": "none", "focused": false]
        if focusSettable {
            let error = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            report["axFocusedErrorRawValue"] = Int(error.rawValue)
            if waitUntil(seconds: focusSettleSeconds, { focusIsOn(element, processIdentifier: processIdentifier) }) {
                report["method"] = "axFocused"
                report["focused"] = true
                return report
            }
        }
        switch clickElement(element, windowFrame: windowFrame, processIdentifier: processIdentifier) {
        case .failure(let refusal):
            report["clickRefused"] = refusal.code
        case .success:
            report["method"] = "click"
            report["focused"] = waitUntil(seconds: focusSettleSeconds) { focusIsOn(element, processIdentifier: processIdentifier) }
        }
        return report
    }

    enum KeystrokeOutcome {
        case refused(HandsRefusal)
        /// Lengths and counts only — never the text.
        case posted(payload: [String: Any], evidence: String?)
    }

    /// How long a field gets to show the keystrokes in its value.
    static let keystrokeVerifySeconds = 1.0

    /// Type `text` as unicode key events into `element`, which must hold keyboard
    /// focus. Secure input and focus are re-checked between chunks: the owner may
    /// click away mid-text, or a password box may take focus, and the rest must
    /// not follow it there.
    static func typeByKeystrokes(_ text: String, mode: TypeMode, into element: AXUIElement, processIdentifier: pid_t,
                                 fingerprintBefore: Set<String>, secureInput: () -> SecureInputState) -> KeystrokeOutcome {
        let valueLengthBefore = AccessibilityTypePerformer.stringValue(of: element)?.count
        if let refusal = keystrokeRefusal(
            text: text, mode: mode, valueLengthBefore: valueLengthBefore, secureInputOn: secureInput().isOn,
            focusedMightBeSecure: focusedMightBeSecure(processIdentifier: processIdentifier),
            focusedIsTarget: focusIsOn(element, processIdentifier: processIdentifier),
            selectionLength: AccessibilityTypePerformer.selectedRange(of: element).map { $0.length }
        ) { return .refused(refusal) }

        let chunks = keystrokeChunks(text)
        let startedAt = Date()
        var charactersPosted = 0
        var stoppedBecause: String?
        for (index, chunk) in chunks.enumerated() {
            if index > 0 {
                Thread.sleep(forTimeInterval: interChunkDelaySeconds)
                if secureInput().isOn { stoppedBecause = "handOver"; break }
                if !focusIsOn(element, processIdentifier: processIdentifier) { stoppedBecause = "focusMoved"; break }
            }
            guard postUnicode(chunk) else { stoppedBecause = "eventCreationFailed"; break }
            charactersPosted += chunk.count
        }
        let postMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)

        var valueLengthAfter: Int?
        var evidence: String?
        waitUntil(seconds: keystrokeVerifySeconds) {
            valueLengthAfter = AccessibilityTypePerformer.stringValue(of: element)?.count
            evidence = keystrokeEvidence(valueLengthBefore: valueLengthBefore, valueLengthAfter: valueLengthAfter,
                                         typedCount: text.count, fingerprintChanged: false)
            return evidence != nil
        }
        // A field with no readable value: the window's text is the only witness.
        if evidence == nil, valueLengthBefore == nil || valueLengthAfter == nil,
           let laterRoot = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?.rootNode {
            evidence = keystrokeEvidence(valueLengthBefore: valueLengthBefore, valueLengthAfter: valueLengthAfter, typedCount: text.count,
                                         fingerprintChanged: AccessibilityDumpRunner.namedElementFingerprint(in: laterRoot) != fingerprintBefore)
        }
        return .posted(payload: [
            "method": TypeMethod.keystrokes.rawValue,
            "status": stoppedBecause == nil ? "sent" : "stopped",
            "stoppedBecause": stoppedBecause ?? NSNull(),
            "chunks": chunks.count,
            "charactersRequested": text.count,
            "charactersPosted": charactersPosted,
            "milliseconds": postMilliseconds,
            "valueLengthBefore": valueLengthBefore ?? NSNull(),
            "valueLengthAfter": valueLengthAfter ?? NSNull()
        ], evidence: evidence)
    }

    struct BrowserWindowRead {
        let frontmost: Bool
        let window: AXUIElement?
        let title: String?
    }

    /// The browser's own answer: is it frontmost, and its focused window and title.
    static func browserWindow(processIdentifier: pid_t) -> BrowserWindowRead {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var frontmost: AnyObject?
        var window: AnyObject?
        AXUIElementCopyAttributeValue(application, kAXFrontmostAttribute as CFString, &frontmost)
        AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window)
        guard let window, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return BrowserWindowRead(frontmost: frontmost as? Bool == true, window: nil, title: nil)
        }
        var title: AnyObject?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return BrowserWindowRead(frontmost: frontmost as? Bool == true, window: (window as! AXUIElement), title: title as? String)
    }

    /// Box for `NSWorkspace.open`'s completion across the blocking wait.
    private final class OpenBox: @unchecked Sendable {
        var application: NSRunningApplication?
        var error: Error?
    }

    /// Hands the URL to the browser and waits for its callback (on a background
    /// queue, so the semaphore cannot deadlock it). Returns the process or why not.
    static func open(_ url: URL, withApplicationAt appURL: URL) -> Result<NSRunningApplication, HandsRefusal> {
        let box = OpenBox()
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { application, error in
            box.application = application
            box.error = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + openURLDeadlineSeconds) == .success else {
            return .failure(HandsRefusal(code: "openFailed", message: "the browser did not answer within \(Int(openURLDeadlineSeconds)) s"))
        }
        guard let application = box.application else {
            return .failure(HandsRefusal(code: "openFailed",
                                         message: box.error.map { String(describing: $0) } ?? "the open returned neither an application nor an error"))
        }
        return .success(application)
    }
}
