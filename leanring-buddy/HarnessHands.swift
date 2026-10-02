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

    /// Whether a real click follows an `AXPress`: only after one the app
    /// REFUSED. A press that went in (or timed out, which may still have worked)
    /// and showed nothing is reported notObserved — a click after it would be a
    /// second activation of whatever the press did unseen (review of H1,
    /// 2026-10-02: a toggle flipped back, a "Next" pressed twice).
    static func clickFollowsPress(error: AXError) -> Bool {
        afterPress(error: error) == .clickNow
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
        /// Inside the target, but under a control of its own: a button, link,
        /// field or password box, or a name the kernel would ask or refuse about.
        case activeInsideTarget
    }

    /// One element between the hit and the target, as read on the way up.
    struct HitChainNode: Equatable {
        let role: String
        var subrole: String? = nil
        var subroleReadFailed = false
        /// Title, description, or a static text's value — never a field's.
        var name: String? = nil
        var publishesPress = false
    }

    /// Roles a click lands ON rather than through: what the click would act on
    /// instead of the target the kernel judged.
    static let activeRoles: Set<String> = AccessibilityElementNode.textInputRoles.union([
        "AXButton", "AXLink", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor",
        "AXDisclosureTriangle", "AXSecureTextField", "AXMenuItem", "AXSwitch"])

    /// Whether a click may pass through `node` to the target (review of H1,
    /// 2026-10-02: a card group's centre may be its "Buy now" child). Not a
    /// control, not what may be a password box, and no word the kernel refuses
    /// or asks about. Publishing AXPress is active only when the target publishes
    /// none (review 2026-10-02: an "Order #42" group whose centre is an unlabelled
    /// clickable icon): Chromium gives text inside a button AXPress (its
    /// click-ancestor verb, per Chromium's source, not measured here), so inside a
    /// pressable target that rule would refuse every real click on a web button.
    static func isInert(_ node: HitChainNode, targetPublishesPress: Bool) -> Bool {
        guard targetPublishesPress || !node.publishesPress, !activeRoles.contains(node.role), !(node.subrole.map(ActionSafetyKernel.navigationalPressSubroles.contains) ?? false),
              !AccessibilityElementNode.mightBeSecure(role: node.role, subrole: node.subrole, subroleReadFailed: node.subroleReadFailed,
                                                      namedByValue: false) else { return false }
        guard let name = node.name?.lowercased(), !name.isEmpty else { return true }
        return !ActionSafetyKernel.irreversibleTitleKeywords.contains(where: name.contains)
            && !ActionSafetyKernel.destructiveTitleKeywords.contains(where: name.contains)
            && ActionSafetyKernel.confirmPhrase(in: name) == nil
    }

    /// The hit, relative to the target, from the chain read walking up from it:
    /// `chain[0]` is the hit, and the walk stopped at the target (`reachedTarget`).
    static func relation(hitChain chain: [HitChainNode], reachedTarget: Bool, targetPublishesPress: Bool) -> HitRelation {
        guard reachedTarget else { return .otherElementSameApp }
        if chain.isEmpty { return .target }
        return chain.allSatisfy { isInert($0, targetPublishesPress: targetPublishesPress) } ? .insideTarget : .activeInsideTarget
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
        case .activeInsideTarget:
            return HandsRefusal(code: "clickTargetObscured",
                                message: "a control of its own sits inside the element at that point, so a click there would press it instead; nothing was clicked")
        }
    }

    /// Everything a posted click needs, in order: the target's app still in
    /// front (the owner may have switched since the request was read), then the hit.
    static func postRefusal(frontmostIsTarget: Bool, hit: HitRelation) -> HandsRefusal? {
        guard frontmostIsTarget else { return frontmostChangedRefusal }
        return hitRefusal(hit)
    }

    static let frontmostChangedRefusal = HandsRefusal(
        code: "frontmostChanged", message: "the app is no longer in front, so input would land in another app; nothing more was posted")

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

    /// Web content takes keystrokes first, never the AX write: `--hands-probe`
    /// 2026-10-02 (Chrome, its own page) — a forced AX write came back
    /// performFailed in every page input, keystrokes landed in every one
    /// (contenteditable included), and the write tried first cost ~3 s per
    /// `type` (3.4-3.7 s against 0.4 s forced keystrokes). Native fields keep
    /// the write first: it replaces, keystrokes only insert.
    static func typeStartsWithKeystrokes(forced: TypeMethod?, inWebContent: Bool) -> Bool {
        forced == .keystrokes || (forced == nil && inWebContent)
    }

    /// Safari and its web apps (`com.apple.Safari.WebApp.<UUID>` — LinkedIn on
    /// this Mac), and anything shipping a Chromium framework: Chrome-family
    /// browsers name it "<Product> Framework.framework", Electron "Electron
    /// Framework.framework". ponytail: a name suffix, not a Chromium check; a
    /// non-web app with such a framework only gets keystrokes first, which are
    /// still verified by the field's own value.
    static func isWebHost(bundleIdentifier: String?, frameworkNames: [String]) -> Bool {
        if let bundleIdentifier, bundleIdentifier == "com.apple.Safari" || bundleIdentifier.hasPrefix("com.apple.Safari.WebApp.") {
            return true
        }
        return frameworkNames.contains { $0.hasSuffix(" Framework.framework") }
    }

    /// Return, Tab and the like are keys that act (submit, move focus), not text.
    /// v1 types none of them (design: "No Return/Enter in v1").
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
    }

    /// Why keystrokes may not be posted into the field, or nil. Checked right
    /// before posting; secure input and focus are checked again per chunk.
    /// `frontmostIsTarget`: the field's app is the one in front NOW — its own
    /// focused element survives deactivation, so focus alone would type into
    /// whatever came forward (review of H1, 2026-10-02). `ownerIdle`: no input of
    /// the owner's for `ownerIdleSeconds`, our own discounted. `caretLocation` /
    /// `valueLengthUTF16`: an insert goes at the END — a focusing click leaves
    /// the caret where it landed, mid-text.
    static func keystrokeRefusal(text: String, mode: TypeMode, valueLengthBefore: Int?, secureInputOn: Bool,
                                 focusedMightBeSecure: Bool, focusedIsTarget: Bool, selectionLength: Int?,
                                 frontmostIsTarget: Bool, ownerIdle: Bool, caretLocation: Int?, valueLengthUTF16: Int?) -> HandsRefusal? {
        if secureInputOn {
            return HandsRefusal(code: "handOver", message: "secure typing is on — a password is the owner's to type; no keystrokes were posted")
        }
        if focusedMightBeSecure {
            return HandsRefusal(code: "secureField", message: ActionSafetyKernel.unreadableSubroleTypeRefusalReason)
        }
        if !frontmostIsTarget { return frontmostChangedRefusal }
        if !ownerIdle {
            return HandsRefusal(code: "ownerActive",
                                message: "the owner is using the keyboard or mouse, so keystrokes could mix with theirs; none were posted")
        }
        if containsControlCharacters(text) {
            return HandsRefusal(code: "controlCharacters",
                                message: "the text holds Return, Tab or another control character; keystrokes never send those in v1")
        }
        // One key event carries at most 20 UTF-16 units; a longer character would stop the text halfway.
        if text.contains(where: { $0.utf16.count > maximumChunkUTF16 }) {
            return HandsRefusal(code: "characterTooLong", message: "a character in the text is too long for one key event; none were posted")
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
        if mode == .insert, let caretLocation, let valueLengthUTF16, caretLocation != valueLengthUTF16 {
            return HandsRefusal(code: "caretNotAtEnd",
                                message: "the caret is inside the existing text and could not be moved to its end; none were posted")
        }
        return nil
    }

    /// Why typing stops before the next chunk, or nil. Read before EVERY chunk,
    /// the first included: the owner may switch apps, click away or take the
    /// keyboard, or a password box may take focus, and the rest must not follow.
    static func chunkStopReason(secureInputOn: Bool, frontmostIsTarget: Bool, focusIsOnTarget: Bool, ownerIdle: Bool) -> String? {
        if secureInputOn { return "handOver" }
        if !frontmostIsTarget { return "frontmostChanged" }
        if !focusIsOnTarget { return "focusMoved" }
        if !ownerIdle { return "ownerActive" }
        return nil
    }

    /// Posts `chunks` in order, asking `stopReason` (given the chunk's index)
    /// before each one; stops at the first reason or failed post.
    static func postChunks(_ chunks: [String], stopReason: (Int) -> String?, post: (String) -> Bool)
        -> (charactersPosted: Int, stoppedBecause: String?) {
        var posted = 0
        for (index, chunk) in chunks.enumerated() {
            if let reason = stopReason(index) { return (posted, reason) }
            guard post(chunk) else { return (posted, "eventCreationFailed") }
            posted += chunk.count
        }
        return (posted, nil)
    }

    /// How long the owner must have left the keyboard and mouse alone.
    static let ownerIdleSeconds = 1.0
    /// How long `type` waits for that before refusing: the push-to-talk key's
    /// own release lands about a second before a voice call types.
    static let ownerIdleWaitSeconds = 2.0
    /// Our post and the system's counter of it differ by scheduling only.
    static let ownInputToleranceSeconds = 0.15

    /// Idle long enough, or the latest input is our own: every idle counter
    /// resets on synthetic input too (CLAUDE.md, 2026-10-02), so a focusing
    /// click or the previous chunk must not read as the owner.
    static func ownerIsIdle(secondsSinceLastInput: Double, secondsSinceOurLastPost: Double?, required: Double = ownerIdleSeconds) -> Bool {
        if secondsSinceLastInput >= required { return true }
        guard let ours = secondsSinceOurLastPost else { return false }
        return secondsSinceLastInput + ownInputToleranceSeconds >= ours
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
        return valueLengthAfter == valueLengthBefore + typedCount ? valueGrewEvidence : nil
    }
    /// The field itself, re-read after the keys, grew by exactly the text: the effect,
    /// observed — so `type` reports it confirmed without the fingerprint poll.
    static let valueGrewEvidence = "the field's value grew by the text's length"

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
              // "https://bank.com%40evil.example/" is the credentials trick spelled in percent-escapes.
              !host.contains("@"), !(components.percentEncodedHost ?? "").lowercased().contains("%40"),
              let url = components.url else { return nil }
        return url
    }

    /// The owner's own machine or network: a page there can be a router's admin
    /// screen or a dev server's "delete everything" route, so it is asked about.
    /// Addresses are parsed as the system parses them (`inet_aton`, `inet_pton`),
    /// so every spelling of loopback counts (review 2026-10-02): `localhost.`,
    /// `127.1`, `2130706433`, `0x7f000001`, `::ffff:127.0.0.1`.
    static func isPrivateHost(_ host: String) -> Bool {
        var host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        func privateV4(_ first: UInt8, _ second: UInt8) -> Bool {
            switch (first, second) {
            case (127, _), (10, _), (0, _), (192, 168), (169, 254), (172, 16...31): return true
            default: return false
            }
        }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }   // network order
            return privateV4(bytes[0], bytes[1])
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }   // fe80::/10, link-local
        if bytes[0] & 0xfe == 0xfc { return true }                       // fc00::/7, unique local
        // ::, ::1, and IPv4 mapped (::ffff:a.b.c.d) or compatible (::a.b.c.d): the IPv4 rules.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == bytes[11], bytes[10] == 0 || bytes[10] == 0xff {
            return privateV4(bytes[12], bytes[13])
        }
        return false
    }

    /// The kernel's judgement of an address, as of a control's name: an
    /// irreversible word in its path, query or fragment refuses ("/checkout/buy?…"),
    /// a destructive or publishing one, or a private host, asks on a card.
    static func openURLDecision(_ url: URL) -> SafetyDecision {
        let words = urlWords(url)
        if let keyword = ActionSafetyKernel.irreversibleTitleKeywords.first(where: { keyword in
            " \(words) ".contains(" \(keyword) ") }) {
            return .refuse(reason: ActionSafetyKernel.irreversibleRefusalReason(keyword: keyword))
        }
        if let phrase = ActionSafetyKernel.destructiveTitleKeywords.first(where: { " \(words) ".contains(" \($0) ") })
            ?? ActionSafetyKernel.confirmPhrase(in: words) {
            return .requireConfirmation(reason: "\(ActionSafetyKernel.destructiveActionReasonPrefix)\(phrase)", destructive: true)
        }
        if let host = url.host, isPrivateHost(host) {
            return .requireConfirmation(reason: "the page is on this Mac or its local network (\(host)), where a page can change settings", destructive: false)
        }
        return .allow
    }

    /// An address's path, query and fragment as the kernel's words: percent-escapes
    /// decoded twice, as before (a malformed escape keeps the text — it used to
    /// empty it, and an empty string matched no keyword), camelCase split
    /// (`/api/deleteAll` -> "api delete all"), every non-alphanumeric a space.
    static func urlWords(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var text = [components?.percentEncodedPath, components?.percentEncodedQuery, components?.percentEncodedFragment]
            .compactMap { $0 }.joined(separator: " ")
        for _ in 0..<2 { text = text.removingPercentEncoding ?? text }
        return text
            .replacingOccurrences(of: #"(\p{Ll})(\p{Lu})"#, with: "$1 $2", options: .regularExpression)
            .lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
    }

    /// What the audit line keeps of an address: scheme, host and path. A query
    /// or fragment can carry a search, a token or an email address.
    static func auditableURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? (url.host ?? "")
    }

    /// The page's host is the one asked for: equal, or one is a subdomain of
    /// the other once "www." is set aside (linkedin.com -> www.linkedin.com/feed).
    static func hostMatches(page: String, requested: String) -> Bool {
        func bare(_ host: String) -> String {
            let lower = host.lowercased()
            return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        let (page, requested) = (bare(page), bare(requested))
        return page == requested || page.hasSuffix("." + requested) || requested.hasSuffix("." + page)
    }

    /// openURL's verification from the last reads: `confirmed` only when the
    /// page's own AXURL names the host; `browserReacted` when the browser came
    /// forward with a new or retitled window but published no readable URL;
    /// `pageHostDiffers` when it did and named another host.
    static func openURLVerification(evidence: String?, pageHost: String?, requestedHost: String) -> String {
        guard evidence != nil else { return "notObserved" }
        guard let pageHost else { return "browserReacted" }
        return hostMatches(page: pageHost, requested: requestedHost) ? "confirmed" : "pageHostDiffers"
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
    /// After the browser reacts, how long its page's address gets to name the host.
    static let openURLHostGraceSeconds = 1.5

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

    /// A field inside a web page: the app is a web host, or an `AXWebArea`
    /// holds the field (a WebKit view in a native app — Mail's compose body).
    static func isWebContent(_ element: AXUIElement, application: NSRunningApplication?) -> Bool {
        let frameworks = application?.bundleURL.flatMap { url in
            try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path)
        } ?? []
        if isWebHost(bundleIdentifier: application?.bundleIdentifier, frameworkNames: frameworks) { return true }
        var current: AXUIElement? = element
        for _ in 0..<ancestorWalkLimit {
            guard let node = current else { return false }
            var role: AnyObject?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success, role as? String == "AXWebArea" { return true }
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
        // Up from the hit to the target, reading what each element between them is.
        let targetPublishesPress = AccessibilityTreeWalker.copyActionNames(from: target).contains(kAXPressAction)
        var chain: [HitChainNode] = []
        var current: AXUIElement? = hit
        for _ in 0..<ancestorWalkLimit {
            guard let node = current else { break }
            if CFEqual(node, target) { return relation(hitChain: chain, reachedTarget: true, targetPublishesPress: targetPublishesPress) }
            chain.append(hitChainNode(node))
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return relation(hitChain: chain, reachedTarget: false, targetPublishesPress: targetPublishesPress)
    }

    /// Role, subrole and name of one element on the way up — never a field's value.
    static func hitChainNode(_ element: AXUIElement) -> HitChainNode {
        func string(_ attribute: String) -> (String?, AXError) {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return (value as? String, error)
        }
        let role = string(kAXRoleAttribute).0 ?? "AXUnknown"
        let (subrole, subroleError) = string(kAXSubroleAttribute)
        let name = string(kAXTitleAttribute).0 ?? string(kAXDescriptionAttribute).0
            ?? (role == "AXStaticText" ? string(kAXValueAttribute).0 : nil)
        return HitChainNode(role: role, subrole: subrole, subroleReadFailed: AccessibilityElementNode.subroleReadFailed(subroleError), name: name,
                            publishesPress: AccessibilityTreeWalker.copyActionNames(from: element).contains(kAXPressAction))
    }

    /// The target's app is in front: the system-wide read, or — when that gives
    /// no answer (Chromium before its accessibility is on) — the app's own
    /// `AXFrontmost`. No answer from either is not a yes.
    static func targetIsFrontmost(_ processIdentifier: pid_t) -> Bool {
        if let frontmost = AccessibilityTreeWalker.focusedApplication() { return frontmost.processIdentifier == processIdentifier }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(application, kAXFrontmostAttribute as CFString, &value) == .success && value as? Bool == true
    }

    /// When we last posted input, so the owner-idle check can discount it.
    final class OwnInputClock: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPostedUptime: TimeInterval?
        func mark() { lock.lock(); lastPostedUptime = ProcessInfo.processInfo.systemUptime; lock.unlock() }
        var secondsSinceLastPost: Double? {
            lock.lock(); defer { lock.unlock() }
            return lastPostedUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
        }
    }
    static let ownInput = OwnInputClock()

    /// The owner idle now (`ownerIsIdle`), from the HID system's own counter.
    static func ownerIsIdleNow() -> Bool {
        let anyInput = CGEventType(rawValue: UInt32.max)!
        return ownerIsIdle(secondsSinceLastInput: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput),
                           secondsSinceOurLastPost: ownInput.secondsSinceLastPost)
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
        ownInput.mark()
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        up.post(tap: .cghidEventTap)
        ownInput.mark()
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
        ownInput.mark()
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
        if let refusal = postRefusal(frontmostIsTarget: targetIsFrontmost(processIdentifier),
                                     hit: hitRelation(atTopLeft: topLeft, target: element, processIdentifier: processIdentifier)) {
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
        let valueBefore = AccessibilityTypePerformer.stringValue(of: element)
        let valueLengthBefore = valueBefore?.count
        let valueLengthUTF16 = valueBefore?.utf16.count
        // An insert goes at the end: move a caret the focusing click left mid-text, then read where it is.
        if mode == .insert, let valueLengthUTF16, let range = AccessibilityTypePerformer.selectedRange(of: element),
           range.length == 0, range.location != valueLengthUTF16 {
            var end = CFRange(location: valueLengthUTF16, length: 0)
            if let endValue = AXValueCreate(.cfRange, &end) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, endValue)
            }
        }
        let selection = AccessibilityTypePerformer.selectedRange(of: element)
        // The push-to-talk key's release is the owner's input too: give it a moment.
        let ownerIdle = waitUntil(seconds: ownerIdleWaitSeconds) { ownerIsIdleNow() }
        if let refusal = keystrokeRefusal(
            text: text, mode: mode, valueLengthBefore: valueLengthBefore, secureInputOn: secureInput().isOn,
            focusedMightBeSecure: focusedMightBeSecure(processIdentifier: processIdentifier),
            focusedIsTarget: focusIsOn(element, processIdentifier: processIdentifier),
            selectionLength: selection.map { $0.length },
            frontmostIsTarget: targetIsFrontmost(processIdentifier), ownerIdle: ownerIdle,
            caretLocation: selection.map { $0.location }, valueLengthUTF16: valueLengthUTF16
        ) { return .refused(refusal) }

        let chunks = keystrokeChunks(text)
        let startedAt = Date()
        let (charactersPosted, stoppedBecause) = postChunks(chunks, stopReason: { index in
            if index > 0 { Thread.sleep(forTimeInterval: interChunkDelaySeconds) }
            return chunkStopReason(secureInputOn: secureInput().isOn, frontmostIsTarget: targetIsFrontmost(processIdentifier),
                                   focusIsOnTarget: focusIsOn(element, processIdentifier: processIdentifier), ownerIdle: ownerIsIdleNow())
        }, post: postUnicode)
        if charactersPosted == 0, let stoppedBecause {
            return .refused(stoppedBecause == "frontmostChanged" ? frontmostChangedRefusal
                            : HandsRefusal(code: stoppedBecause, message: "typing stopped before the first key (\(stoppedBecause)); nothing was typed"))
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

    /// Nodes looked at for the page's `AXWebArea`: Chromium puts it a few
    /// levels under the window, beside the tab strip and toolbar.
    static let webAreaSearchLimit = 400

    /// The host of the page in `window`: its first `AXWebArea`'s `AXURL`, or nil.
    static func pageHost(inWindow window: AXUIElement) -> String? {
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < webAreaSearchLimit {
            let node = queue.removeFirst()
            visited += 1
            var role: AnyObject?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" {
                var address: AnyObject?
                guard AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &address) == .success else { return nil }
                return ((address as? URL) ?? (address as? String).flatMap(URL.init(string:)))?.host
            }
            var children: AnyObject?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] { queue += children }
        }
        return nil
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
