//
//  ActionSafetyKernel.swift
//  leanring-buddy
//
//  Deterministic policy that runs before any action reaches the machine.
//  It knows nothing about models and cannot be argued out of a refusal.
//
//  The default is requireConfirmation, never allow. Anything this kernel does
//  not positively recognise becomes a question for the human.
//

import ApplicationServices
import Foundation

enum SafetyDecision: Equatable {
    case allow
    /// `destructive` is set by the kernel itself, where it decides a question is
    /// about destroying something — never recovered from `reason` afterwards.
    /// Review 2026-09-15: a prefix check on the reason was blind to any layer that
    /// rewrites it (`HarnessAppPolicy.compose` prepends "app policy requires
    /// confirmation for …"), so in a `confirm`-policy app a destructive question
    /// offered "Always" and matched stored rules. A flag travels through a rewrite.
    case requireConfirmation(reason: String, destructive: Bool = false)
    case refuse(reason: String)
}

enum ActionSafetyKernel {

    /// Roles for which a press is ordinary navigation on this machine.
    /// Grows only when a measured case demands it. Owner's ruling 2026-10-01
    /// (Kernel A): the live test of 2026-09-30 put a card in front of Cursor's
    /// "Toggle Agents" group, links and tabs — ordinary controls. What a press
    /// DOES is still judged first, on the words: destructive asks, irreversible
    /// refuses, publishing asks, whatever the role.
    static let navigationalPressRoles: Set<String> = [
        "AXButton", "AXRow", "AXCell", "AXGroup", "AXLink", "AXRadioButton", "AXDisclosureTriangle",
        "AXMenuButton", "AXPopUpButton", "AXCheckBox",
        // Measured 2026-10-08 (smoke S1): Meet's "New meeting" pop-up in Chrome lists
        // "Create a meeting for later" as an AXMenuItem with no AXPress; it was sent to
        // `select` (noSelectableAncestor) or carded "unrecognised role". A menu item is
        // navigation for `menu` already; its words are still judged first.
        "AXMenuItem"
    ]
    /// A tab is a subrole (Chromium and AppKit put it on AXRadioButton, but a role is a convention).
    static let navigationalPressSubroles: Set<String> = ["AXTabButton"]

    /// Roles for which writing a selection is ordinary navigation.
    ///
    /// `AXStaticText` is in here and deliberately not in the press list: a
    /// sidebar row is anonymous, so the element a planner can name is the label
    /// two levels inside it. Selecting changes what is selected — the write
    /// itself cannot activate anything else.
    static let navigationalSelectRoles: Set<String> = ["AXRow", "AXCell", "AXStaticText"]

    /// The only roles that may be typed into. Everything else is refused, not
    /// asked about: a role that does not accept text has no correct answer to
    /// "type this here", so there is nothing for a human to confirm.
    static let typeableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// Roles that publish `AXOpen`. Measured 2026-09-10 on Finder: the file row
    /// publishes only the hover pair, the `AXCell` inside it publishes `AXOpen`.
    /// Deliberately empty: **opening always asks a human.**
    ///
    /// `AXOpen` does not navigate, it *launches whatever the thing is* — a
    /// document, an installer, a script, an application. Double-clicking an
    /// unknown file is how malware runs, and no verification undoes it. So there
    /// is no role for which this kernel calls it ordinary, and every open lands
    /// on `requireConfirmation`.
    ///
    /// The role census that settled it, measured 2026-09-10 on one Finder window
    /// (1,467 nodes): **AXTextField 446 publish AXOpen and all 446 are named**
    /// (the file list), AXCell 11 and **none named** (the sidebar — unreachable
    /// by name anyway), AXStaticText 5 (the path bar). An earlier reading of
    /// mine generalised from the sidebar's anonymous cells and had the roles
    /// backwards; naming the majority role here would only have decided which
    /// launches happen without asking.
    static let navigationalOpenRoles: Set<String> = []

    /// Roles a menu path resolves to. A menu bar item is the top level ("File"),
    /// a menu item is everything below it.
    static let navigationalMenuRoles: Set<String> = ["AXMenuItem", "AXMenuBarItem"]

    /// The one refusal in this kernel that has no confirmed path past it.
    static let secureFieldSubrole = "AXSecureTextField"

    static func navigationalRoles(for action: ElementAction) -> Set<String> {
        switch action {
        case .press: return navigationalPressRoles
        case .select: return navigationalSelectRoles
        case .type: return typeableRoles
        case .open: return navigationalOpenRoles
        case .menu: return navigationalMenuRoles
        // Clicking a field is how a human focuses it, so a text input is navigation too.
        case .click: return navigationalPressRoles.union(AccessibilityElementNode.textInputRoles)
        }
    }

    /// What the kernel needs to know about a typing target that the tree walk
    /// does not carry: what the element says it will let us write, how much text
    /// is already in it, and whether we aimed at it by name or by focus.
    ///
    /// Measured on the live element, one element only — this is four extra IPC
    /// reads on the resolved target, never a per-node cost on the walk.
    struct TypingContext: Equatable {
        let mode: TypeMode
        /// The subset of `AccessibilityTypePerformer.probedAttributes` the
        /// element reported as settable. Asked, because a role is a convention.
        let settableAttributes: Set<String>
        let currentValueLength: Int
        /// True when the target came from `kAXFocusedUIElement` rather than from
        /// a name. The name checks below are then meaningless — System Settings'
        /// search field has no name at all, and the OS, not the app's text, is
        /// what identified it.
        let aimedByFocus: Bool
        /// The field sits in a browser tab the HARNESS opened (`openURL`) within
        /// `HarnessServer.openedTabLifetimeSeconds` — the harness's own record,
        /// never a caller's flag. See the replace rule in `evaluate`.
        var inTabTheHarnessOpened = false
    }

    static func secureFieldRefusalReason(subrole: String) -> String {
        "refusing to type into a secure field (subrole \(subrole)) — the agent does not enter credentials, and this refusal has no confirmed path past it"
    }

    /// The same refusal for a field that is AXSecureTextField by ROLE alone.
    static func secureFieldRefusalReason(role: String) -> String {
        "refusing to type into a secure field (role \(role)) — the agent does not enter credentials, and this refusal has no confirmed path past it"
    }

    /// A text input whose subrole read failed may be a password box: refused,
    /// not guessed (read failures are never absence). Unlike the two above it
    /// may pass on a retry once the app answers.
    static let unreadableSubroleTypeRefusalReason =
        "refusing to type: this text field's subrole could not be read, so it may be a secure field — the agent does not enter credentials"

    /// Whether a refusal says something tried to do a thing it should not, as
    /// opposed to a thing it could not.
    ///
    /// The distinction is what keeps the flight recorder useful. An off-screen
    /// or wrong-role target is the policy working normally and the audit line
    /// explains it completely. A secure field or a label that is not a label is
    /// the shape of an attempt, and that is exactly when the previous twenty
    /// requests are worth having on disk.
    static func isSecurityRefusal(reason: String) -> Bool {
        reason == implausibleNameRefusalReason
            || reason == secureStatusItemRefusalReason
            || reason.hasPrefix("refusing to type into a secure field")
            || reason == unreadableSubroleTypeRefusalReason
            || reason == secureFieldClickRefusalReason
            || reason.hasPrefix(secureFieldCaptureRefusalPrefix)
            || reason.hasPrefix(incompleteCaptureCheckRefusalPrefix)
            || reason.hasPrefix(irreversibleRefusalPrefix)
    }

    /// A click into a password box would hand its focus to us; the pointer refuses
    /// one for the same reason (`HarnessPolicy.pointerRefusal`). The owner clicks it.
    static let secureFieldClickRefusalReason =
        "refusing to click a secure field (or a text field whose subrole could not be read) — a password is the owner's to type"

    static func nonTextRoleRefusalReason(role: String) -> String {
        "role \(role) does not accept text — only \(typeableRoles.sorted().joined(separator: ", ")) may be typed into"
    }

    static func missingSettableAttributeRefusalReason(attribute: String) -> String {
        "element does not publish a settable \(attribute)"
    }

    static func replaceWouldDiscardReason(characterCount: Int) -> String {
        "\(replaceWouldDiscardReasonPrefix)\(characterCount) characters already in the field"
    }

    /// The two questions about destroying something carry `destructive: true`
    /// (see `SafetyDecision`). Owner's ruling 2026-09-14: such a question may be
    /// answered once, never "always" — a rule cannot carry what is selected, so
    /// "always press Delete in Mail" would delete whatever is selected next, forever.
    static let destructiveActionReasonPrefix = "title suggests a destructive action: "
    static let replaceWouldDiscardReasonPrefix = "replace would discard "
    /// The owner's words set draft scope ("stop before saving", "don't send").
    static let draftScopeReasonPrefix = "the owner said to stop before this: "
    /// The words that commit a draft, as whole words of a target's own name.
    static let draftCommitWords: Set<String> = ["send", "save", "schedule", "invite", "post", "publish", "submit", "share"]
    /// Single-line inputs: replacing one discards a value, never a document.
    static let singleLineTextRoles: Set<String> = ["AXTextField", "AXComboBox"]

    /// Refusal reasons as constants, so the probe can classify a decision by
    /// identity rather than by re-typing the sentence and silently missing.
    static let zeroAreaRefusalReason = "listed but not reachable: element has a zero-area frame"
    static let outsideBoundsRefusalReason = "listed but not reachable: element lies outside the visible bounds"

    /// Whether a frame is drawn where a human could reach it — nil when it is.
    /// Shared by the press path and `highlight`, so an outline can never be drawn
    /// round something a press would have refused as off-screen.
    static func unreachableFrameReason(_ frame: CGRect, visibleBounds: CGRect) -> String? {
        guard frame.width > 0, frame.height > 0 else { return zeroAreaRefusalReason }
        // Zero area is only the first disguise. Measured 2026-09-08:
        // AXButton desc="Transfer or Reset" (354, -66, 459, 38) [AXPress] is
        // named, correctly sized and pressable, and scrolled out of its pane.
        // Reachability is the relationship between the frame and what is on
        // screen, not a property of the frame alone.
        guard frame.intersects(visibleBounds) else { return outsideBoundsRefusalReason }
        return nil
    }

    /// The name is the whole identity we act on, and the app wrote it. A label
    /// that is empty, document-length, or carries a newline is not a control's
    /// name — it is content that arrived in a name-shaped field, and letting it
    /// name an action is how app-controlled text becomes an instruction.
    static let implausibleNameRefusalReason = "listed but not usable as a target: the element's name is not a plain label"

    /// Pressing a disabled menu item returns `.success` and does nothing —
    /// measured 2026-09-10 on Finder's "New Folder", which reads
    /// `AXEnabled == false` while focus is in the sidebar. Asking the item
    /// first is what makes `AXError 0` mean anything at all on this path.
    static func menuItemDisabledRefusalReason(name: String) -> String {
        "menu item \(name) is disabled (AXEnabled false) — pressing it would return success and do nothing"
    }

    /// The second refusal with no confirmed path past it, and the only one that
    /// is about the *world* rather than about us.
    ///
    /// Everything else destructive escalates to a question, because a question
    /// has an answer: a human looks at it and decides. These do not, because by
    /// the time anyone could look the thing is already gone. Emptying the bin
    /// has no undo, an erase has no undo, and money that has left an account is
    /// not a state this agent can restore. So the human does not *approve* these
    /// — the human does them, in the app, with their own hands.
    ///
    /// Owner's ruling 2026-09-10, asked for in exactly those terms. It is a real
    /// capability given up: the agent cannot empty a bin even when asked twice.
    /// That is the point — `confirmed: true` records that someone took
    /// responsibility, and no one can take responsibility for a thing they
    /// cannot inspect first.
    ///
    /// Disjoint from `destructiveTitleKeywords` by construction (there is a test),
    /// because a word in both lists would read as "asks a human" while behaving
    /// as "refuses", and the weaker line is the one someone would believe.
    static let irreversibleTitleKeywords = [
        // Emptying the bin. No undo, in any locale spelling.
        "empty trash", "empty bin",
        // Finder's Option-Command-Delete, and the word every app reaches for
        // when it means "not to the bin".
        "delete immediately", "permanently",
        // "Erase All Content and Settings", "Erase Disk", "Erase Free Space".
        // Yes, this also refuses a drawing app's "Eraser" — a false positive
        // here costs one manual click and an argument about it costs a disk.
        "erase",
        // Money. Distinct from the rest only in that the loss is someone
        // else's problem to reverse, and usually cannot be.
        "buy", "pay", "purchase"
    ]

    static let irreversibleRefusalPrefix = "refusing an irreversible action"

    static func irreversibleRefusalReason(keyword: String) -> String {
        "\(irreversibleRefusalPrefix): the title contains \"\(keyword)\" — this has no undo, "
            + "so it has no confirmed path past it either; a human does this one themselves"
    }

    /// Words that make an action worth *asking* about regardless of role — all
    /// of them reversible, or at least inspectable before the fact.
    static let destructiveTitleKeywords = [
        "delete", "remove", "send", "reset",
        // Menu-bar words. This check has always mattered; on a menu bar it
        // matters most, because "Move to Bin" and "Quit" are two items away
        // from anything. "Move to Bin" is spelled out rather than adding
        // "bin", which is a substring of "Combine All Windows".
        //
        // Deliberately NOT here: "close". Closing a window is the ordinary
        // inverse of opening one — it is what makes a menu test reversible —
        // and adding it would put a question in front of every window close.
        "trash", "quit", "empty", "eject", "log out", "shut down",
        "move to bin"
    ]

    /// Phrases asked about like the list above (`destructive: true`: answered
    /// once, never "always"), matched as WHOLE words in order — a sidebar's
    /// "Shared", a tab's "Posts" or "Comments" are navigation — and never for
    /// `type`: typing into "Add a comment" publishes nothing, pressing Post does.
    /// Owner's standing ruling (2026-09-30/10-01): destructive or publishing ->
    /// a card; the review of 2026-10-01 added the rest.
    static let confirmTitlePhrases = [
        // Publishing: the owner's words in front of other people.
        "post", "publish", "share", "submit", "reply", "comment", "repost", "retweet", "tweet", "reshare",
        // Destructive words the substring list above does not reach.
        "deletion", "removal", "discard", "unsubscribe", "sign out", "leave", "deactivate", "uninstall", "revoke",
        "disconnect", "cancel subscription",
        // Security approvals: a "yes" someone else is waiting for.
        "approve", "authorize", "authorise", "allow access", "yes it was me",
        // System Settings sharing and remote-access switches.
        "remote login", "screen sharing", "file sharing", "remote management", "remote apple events"
    ]

    /// The first confirm phrase `title` holds as whole words, in order.
    static func confirmPhrase(in title: String) -> String? {
        let words = title.lowercased().split { !$0.isLetter }.map(String.init)
        return confirmTitlePhrases.first { phrase in
            let wanted = phrase.split(separator: " ").map(String.init)
            return words.count >= wanted.count && (0...(words.count - wanted.count)).contains { Array(words[$0..<($0 + wanted.count)]) == wanted }
        }
    }

    /// Focus: the only verb here that is not evaluated by `evaluate`.
    ///
    /// It has no `ElementActionIntent`, no published action to require and no
    /// role to recognise — the target is a window, not a control — so running
    /// it through the main path would mean inventing an intent to satisfy
    /// checks that do not apply to it. Two rules do apply, and they are the two
    /// that are about *us* rather than about the action:
    ///
    ///   - more than one window matching is a question, never a coin flip, for
    ///     the same reason it is everywhere else in this kernel;
    ///   - a title is app-written text, and a name that is not a plain label is
    ///     content that arrived in a name-shaped field.
    ///
    /// Nothing else. Focus destroys nothing, and its inverse is one click on
    /// the app the caller was told it came from — a kernel that asked a human
    /// to confirm bringing a window forward would make the harness unusable,
    /// and an operator who has to answer a pointless question ten times a
    /// minute stops reading the question.
    static func evaluateFocus(windowTitle: UntrustedText?, matchCount: Int) -> SafetyDecision {
        guard matchCount == 1 else {
            return .refuse(reason: "\(matchCount) windows match that title")
        }
        if let windowTitle, !windowTitle.isPlausibleControlLabel {
            return .refuse(reason: implausibleNameRefusalReason)
        }
        return .allow
    }

    // MARK: Person-notifying views (owner's ruling 2026-10-08)

    /// A page whose network tells the person "who viewed your profile": opening
    /// it reaches a real person, even in a read-only task, so it asks on a card —
    /// through openURL and through a press or click on a link whose own AXURL
    /// points there. Data, not logic: another network is one more row (its host,
    /// and the first path component of its profile pages).
    struct PersonNotifyingView: Equatable {
        let network: String
        let host: String
        let firstPathComponent: String
    }

    static let personNotifyingViews: [PersonNotifyingView] = [
        PersonNotifyingView(network: "LinkedIn", host: "linkedin.com", firstPathComponent: "in")
    ]

    /// The row whose profile `url` opens: its host or a subdomain of it (www.,
    /// au., m.), then `/<component>/<someone>`. Path compared without case and
    /// with empty components dropped, so `//IN/jane` counts; `/in/` alone is no one.
    /// ponytail: a shortener (lnkd.in) or a redirect URL is not followed.
    static func personNotifyingView(_ url: URL) -> PersonNotifyingView? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let path = url.path.lowercased().split(separator: "/").map(String.init)
        guard path.count >= 2 else { return nil }
        return personNotifyingViews.first { view in
            (host == view.host || host.hasSuffix("." + view.host)) && path[0] == view.firstPathComponent
        }
    }

    static func personNotifyingView(_ address: String) -> PersonNotifyingView? {
        URL(string: address).flatMap { personNotifyingView($0) }
    }

    static func personNotifyingReason(network: String) -> String {
        "opens a \(network) profile, and \(network) notifies that person it was viewed"
    }

    /// `decision` with the profile rule laid over it: a refusal stays a refusal,
    /// a question keeps its destructive flag and gains the reason, an allow asks.
    static func gatingPersonNotifyingView(_ decision: SafetyDecision, url: URL?) -> SafetyDecision {
        guard let view = url.flatMap({ personNotifyingView($0) }) else { return decision }
        let reason = personNotifyingReason(network: view.network)
        switch decision {
        case .refuse: return decision
        case .requireConfirmation(let existing, let destructive):
            return .requireConfirmation(reason: "\(existing); \(reason)", destructive: destructive)
        case .allow: return .requireConfirmation(reason: reason)
        }
    }

    /// Apps that run arbitrary code or hold credentials. Starting one is asked about.
    static let launchConfirmationBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2",
        "com.apple.Automator", "com.apple.shortcuts", "com.apple.installer",
        "com.apple.keychainaccess", "com.apple.Passwords"
    ]

    /// Launch: deliberately narrower than `AXOpen`, and so allowed where opening
    /// always asks. Its target is an installed application by identity — the
    /// harness resolves a bundle identifier or an exact name in the application
    /// folders and refuses any path — never a file, so it cannot run a script or
    /// a downloaded installer. The full per-app policy is plan item 5, not this verb.
    ///
    /// Bundle identifiers are case-insensitive to LaunchServices, so the match is
    /// too — otherwise "COM.APPLE.TERMINAL" would be a way past the question.
    static func evaluateLaunch(bundleIdentifier: String) -> SafetyDecision {
        if launchConfirmationBundleIdentifiers.contains(where: {
            $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) {
            return .requireConfirmation(
                reason: "launching \(bundleIdentifier) — it runs arbitrary code or holds credentials"
            )
        }
        return .allow
    }

    static let secureFieldCaptureRefusalPrefix = "refusing to capture a region containing a secure field"

    /// A credential manager's status item is refused like a secure field: its
    /// dropdown IS the password list. A constant so the flight recorder's
    /// security rule recognises it — a free-text reason in the harness did not.
    static let secureStatusItemRefusalReason = "refusing to press a credential manager's status item, like a secure field"

    /// Whether a region may be photographed.
    ///
    /// One rule: **this agent does not photograph password fields.** A crop
    /// taken to disambiguate a button is still a picture of everything else in
    /// the rectangle, and a screenshot of a field mid-entry is a credential
    /// leak that no later refusal undoes — the file is already on disk.
    ///
    /// Like the typing refusal, nothing lifts this: `.refuse` has no ticket,
    /// no approval rule and no confirmed branch anywhere (`HarnessServer.gate`).
    /// It is stated here because a reader of this function should not have to
    /// go and check.
    ///
    /// Note what is NOT checked: the field's value. The kernel decides on the
    /// role or subrole alone and never reads the text it is protecting.
    ///
    /// **An incomplete check is a refusal, not a pass.** An empty or partial
    /// element list and a genuinely safe region both produce `.allow` — the
    /// shape this project has been fooled by six times. So the input is not a
    /// list of elements but a record of what was inspected: which windows, and
    /// whether each walk finished. The capture that follows is restricted to
    /// the same one application (`EscalationLadder.captureRegion`), so the
    /// camera sees nothing this did not inspect.
    static func evaluateCapture(_ inspection: CaptureInspection) -> SafetyDecision {
        // First, and even inside a walk that then stopped: a secure field that
        // was seen is refused as one, whatever else went unseen.
        if let secure = inspection.windows.lazy.flatMap(\.nodes).first(where: \.isSecure) {
            let marker = secure.subrole == secureFieldSubrole ? "subrole" : "role"
            return .refuse(reason: "\(secureFieldCaptureRefusalPrefix) (\(marker) \(secureFieldSubrole))")
        }
        if let incomplete = inspection.incompleteReason {
            return .refuse(reason: incomplete)
        }
        return .allow
    }

    static let incompleteCaptureCheckRefusalPrefix =
        "refusing to capture: the secure-field check could not inspect the whole region"

    static func evaluate(
        intent: ElementActionIntent,
        resolvedNode: AccessibilityElementNode,
        matchCount: Int,
        visibleBounds: CGRect,
        typing: TypingContext? = nil,
        menuItemEnabled: Bool? = nil,
        labelTitle: String? = nil,
        draftScope: Bool = false,
        isListOption: Bool = false
    ) -> SafetyDecision {
        // Order matters. Every refusal is checked before any permission.

        // Before everything, including whether the element is even reachable:
        // a password field is refused on sight. There is no state of the world
        // and no `confirmed: true` that makes this an allow, so it is not a
        // question. It is one of exactly two rules this kernel may not be
        // argued out of — see `irreversibleTitleKeywords` for the other.
        // By role OR subrole (review 2026-10-02: a role-only field passed), and
        // a text input whose subrole did not read is refused too — distinctly.
        if case .type = intent.action, resolvedNode.mightBeSecure {
            if resolvedNode.subrole == secureFieldSubrole {
                return .refuse(reason: secureFieldRefusalReason(subrole: secureFieldSubrole))
            }
            if resolvedNode.role == secureFieldSubrole {
                return .refuse(reason: secureFieldRefusalReason(role: secureFieldSubrole))
            }
            return .refuse(reason: unreadableSubroleTypeRefusalReason)
        }
        if case .click = intent.action, resolvedNode.mightBeSecure {
            return .refuse(reason: secureFieldClickRefusalReason)
        }

        // The other rule with no confirmed path past it, and it is checked here
        // — above reachability, above the menu-enabled check — because those
        // are all reasons an action *cannot* run right now, and this is a reason
        // it may never run at all.
        //
        // The ordering is not cosmetic. Measured 2026-09-10: Finder's
        // "Empty Bin…" is `AXEnabled false` while the bin is empty, so the
        // disabled check answered first and the caller was told the item was
        // disabled. That is an invitation to try again in a minute. A refusal
        // that has no path must not read like a temporary one.
        //
        // The same title may also match both keyword lists ("Empty Trash"
        // contains "trash"), so the stronger answer has to be the one reached.
        //
        // `labelTitle`: a label pressed through its pressable ancestor (review
        // 2026-10-01) — "Buy now" inside an "Order #123" group. The press goes to
        // the group, so the group's name is the target, but the words the owner
        // and the model saw are the label's, and they are checked too.
        // A text input is judged by what it is CALLED (title, description,
        // placeholder), not by the text in it (review 2026-10-01).
        let targetName = (AccessibilityElementNode.textInputRoles.contains(resolvedNode.role) ? resolvedNode.fieldLabel : nil)
            ?? resolvedNode.displayName
        let wordCheckedNames = [typing?.aimedByFocus == true ? nil : targetName?.raw, labelTitle].compactMap { $0 }
        if intent.action.irreversibleNamesAreRefused {
            for name in wordCheckedNames {
                let lowercased = name.lowercased()
                if let matchedKeyword = irreversibleTitleKeywords.first(where: { lowercased.contains($0) }) {
                    return .refuse(reason: irreversibleRefusalReason(keyword: matchedKeyword))
                }
            }
        }

        guard matchCount == 1 else {
            return .refuse(reason: "\(matchCount) elements match that title")
        }

        // Both frame checks are about one thing: is this element drawn where a
        // human could reach it. That question only has an answer for something
        // in a window.
        //
        // Measured 2026-09-10 over the harness, Finder, both menus closed:
        //
        //     AXMenuBarItem  "File"               (113, 876, 43, 24)   drawn
        //     AXMenuItem     "New Finder Window"  (  0,   0,  0,  0)   not drawn
        //     AXMenuItem     "Close Window"       (  0,   0,  0,  0)   not drawn
        //
        // The bar item has a real rectangle because it is on screen. The item
        // inside the closed menu is the project's third failure category, not a
        // failed read: AXFrame *succeeds* and answers with a degenerate value,
        // exactly like the sidebar rows that read (0, 0, 0, 0) in 2026-09-07.
        // So the zero-area refusal would refuse every menu item in every app,
        // and it would be right about the frame and wrong about the world.
        //
        // So the frame checks do not run on the menu path — stated as a
        // property of the verb (`targetHasAnOnScreenFrame`), not silently
        // skipped. Everything else the kernel does still applies, and the
        // destructive-word escalation applies harder: a menu bar is where
        // "Empty Trash" and "Quit" live.
        let frame = resolvedNode.frameInAppKitCoordinates
        if intent.action.targetHasAnOnScreenFrame,
           let reason = unreachableFrameReason(frame, visibleBounds: visibleBounds) {
            return .refuse(reason: reason)
        }

        // Only an action has an action name. A property write has no entry in
        // `AXUIElementCopyActionNames` to look for, and whether the attribute is
        // settable is a question for the element at write time — a machine fact
        // the performer establishes, not a policy this kernel can decide.
        if let requiredActionName = intent.action.accessibilityActionName {
            guard resolvedNode.publishedActionNames.contains(requiredActionName) else {
                return .refuse(reason: "element does not publish \(requiredActionName)")
            }
        }

        // The one fact a menu item publishes that decides everything, and the
        // one an AXError cannot tell you afterwards.
        if case .menu = intent.action {
            // No answer means nobody asked, which is our bug and not a
            // question for a human — same rule as a missing typing context.
            guard let menuItemEnabled else {
                return .refuse(reason: "no enabled state was read for this menu item")
            }
            guard menuItemEnabled else {
                return .refuse(reason: menuItemDisabledRefusalReason(
                    name: resolvedNode.displayName?.forDisplay ?? "?"
                ))
            }
        }

        if case .type = intent.action {
            guard typeableRoles.contains(resolvedNode.role) else {
                return .refuse(reason: nonTextRoleRefusalReason(role: resolvedNode.role))
            }
            // No context means nobody asked the element anything, which is our
            // bug and not a question for a human.
            guard let typing else {
                return .refuse(reason: "no typing context was gathered for this element")
            }
            // The role said "text field". This is the element itself agreeing.
            let required = typing.mode.settableAttributeRequired
            guard typing.settableAttributes.contains(required) else {
                return .refuse(reason: missingSettableAttributeRefusalReason(attribute: required))
            }
        }

        // A field aimed at by focus is identified by the OS, not by its name —
        // and the fields that most need typing are anonymous. Measured
        // 2026-09-10: System Settings' search field publishes no title, no
        // description and an empty value.
        if typing?.aimedByFocus != true {
            // A text field may be named only by its placeholder (review 2026-10-01).
            // A field reached through its label is named by it: a web field has no name of its own (live 2026-10-06).
            let typedLabel = intent.action == .type ? labelTitle.map(UntrustedText.init) : nil
            guard let name = targetName ?? typedLabel, name.isPlausibleControlLabel else {
                return .refuse(reason: implausibleNameRefusalReason)
            }
        }
        // Draft scope (owner 2026-10-10): the owner's words said to stop before
        // saving or sending, so a press whose own name commits asks on a card
        // the owner can answer later — Allow once or Deny, never an Always rule.
        // Judged on the target's (and its label's) AX name, never the caller's.
        if draftScope, intent.action == .press || intent.action == .click || intent.action == .menu {
            for name in wordCheckedNames {
                let words = name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                if let word = words.first(where: draftCommitWords.contains) {
                    return .requireConfirmation(reason: "\(draftScopeReasonPrefix)\"\(String(name.prefix(60)))\" would \(word)",
                                                destructive: true)
                }
            }
        }

        // App-written text may only ever make the decision *more* cautious.
        // A keyword here escalates to a question; nothing an app publishes can
        // turn a question into an allow.
        for name in wordCheckedNames {
            let lowercasedTitle = name.lowercased()
            let phrase: String?
            if case .type = intent.action { phrase = nil } else { phrase = confirmPhrase(in: name) }
            if let matchedKeyword = destructiveTitleKeywords.first(where: { lowercasedTitle.contains($0) }) ?? phrase {
                return .requireConfirmation(reason: "\(destructiveActionReasonPrefix)\(matchedKeyword)", destructive: true)
            }
        }

        // Overwriting a document is the worst thing this verb can do, and it is
        // silent — the old text is simply gone. Replacing an *empty* field is
        // not destruction, so it is not asked about.
        // A single-line field in a tab the harness itself opened holds what that
        // page put there (a new event form's default date), not the owner's
        // writing (S2, 2026-10-08: "replace would discard 10 characters" stalled
        // the form). ponytail: a tab opened at an existing item's edit page
        // passes too; its edit commits only on Save, which draft scope cards.
        if let typing, typing.mode == .replace, typing.currentValueLength > 0,
           !(typing.inTabTheHarnessOpened && singleLineTextRoles.contains(resolvedNode.role)) {
            return .requireConfirmation(
                reason: replaceWouldDiscardReason(characterCount: typing.currentValueLength),
                destructive: true
            )
        }

        guard navigationalRoles(for: intent.action).contains(resolvedNode.role)
                || ((intent.action == .press || intent.action == .click)
                    && (resolvedNode.subrole.map(navigationalPressSubroles.contains) == true || isListOption)) else {
            return .requireConfirmation(reason: "unrecognised role \(resolvedNode.role)")
        }

        return .allow
    }
}

/// What the secure-field check actually inspected before a capture.
///
/// A value type on purpose, so the decision over it is testable without one
/// AX read. Built by `EscalationLadder.inspectForCapture`.
struct CaptureInspection {
    /// One window of the target app whose frame touches the region.
    struct WindowWalk {
        /// App-written; only ever used to name the window in a refusal.
        var title: UntrustedText? = nil
        /// `AXWindow` for a real window. Finder's desktop is an `AXScrollArea`.
        var role: String? = nil
        /// Every node the walk returned — the whole window, not only the part
        /// inside the region.
        var nodes: [AccessibilityElementNode] = []
        /// Which limits stopped the walk. Empty means it finished.
        var stopReasons: Set<WalkStopReason> = []
        /// Children reads that failed — each one a subtree nobody looked at.
        var subtreesLostToFailedReads = 0
        /// Why the walk never ran, when it threw.
        var failure: String? = nil
    }

    /// The `AXError` raw value when `kAXWindows` could not be read; nil when it
    /// was. A failed read is not "no windows" — it is "unknown windows".
    var windowListReadError: Int32? = nil
    var windows: [WindowWalk] = []

    /// Whether a one-app capture of this region would show anything at all.
    ///
    /// Measured 2026-09-11: Finder with only its desktop "window" (an
    /// `AXScrollArea`) produced an `ok: true` capture that was a **blank white
    /// image with a cursor** — the one-app filter draws no desktop. Minutes
    /// earlier the same situation failed, because ScreenCaptureKit did not list
    /// Finder at all. Same screen, two answers, one of them a success that
    /// describes nothing. Deciding it here, from structure, makes it one answer.
    var containsDrawableWindow: Bool {
        windows.contains { $0.role == kAXWindowRole as String }
    }

    /// Why this inspection does not cover the region, or nil when it does.
    ///
    /// No windows at all with a successful list read is complete, not a gap:
    /// the capture is restricted to this one app, so a region none of its
    /// windows touch contains none of its pixels either.
    var incompleteReason: String? {
        let prefix = ActionSafetyKernel.incompleteCaptureCheckRefusalPrefix
        if let code = windowListReadError {
            return "\(prefix) — kAXWindows failed with AXError \(code), so which windows cover it is unknown"
        }
        for (index, window) in windows.enumerated() {
            var gaps: [String] = []
            if let failure = window.failure { gaps.append("could not be walked (\(failure))") }
            gaps += window.stopReasons.map(\.rawValue).sorted()
            if window.subtreesLostToFailedReads > 0 {
                gaps.append("lost \(window.subtreesLostToFailedReads) subtree(s) to failed children reads")
            }
            // Only what might be a password box counts (the shared predicate:
            // a text input, or an AXUnknown named by its value, whose subrole did
            // not read), so a failed subrole read on a button changes nothing —
            // that scoping keeps this rule from refusing every capture of a busy
            // app. A known password box is `evaluateCapture`'s own refusal.
            let unreadableTextFields = window.nodes.filter { $0.mightBeSecure && !$0.isSecure }.count
            if unreadableTextFields > 0 {
                gaps.append("has \(unreadableTextFields) text field(s) whose subrole could not be read, "
                    + "any of which may be a password field")
            }
            guard !gaps.isEmpty else { continue }
            // `forDisplay` already quotes; wrapping it again printed ""title"".
            let name = window.title?.forDisplay ?? "#\(index) (untitled)"
            return "\(prefix) — window \(name) \(gaps.joined(separator: ", "))"
        }
        return nil
    }
}
