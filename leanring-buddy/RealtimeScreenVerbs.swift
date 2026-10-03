//
//  RealtimeScreenVerbs.swift
//  leanring-buddy
//
//  `find_on_screen` and `point_at` (owner-approved 2026-09-30): the window's
//  own controls, offered to a voice model the way `find_menu_items` offers menu
//  paths. Measured that day on Cursor: the agent panel had NO menu item, yet
//  the window published 143 pressable elements, 142 of them named — "New Agent
//  (⇧⌘L)" at an exact frame — while the model, guessing from pixels, put it on
//  the wrong side of "Upgrade to Pro".
//
//  The model is a CHOOSER here too. The harness's `snapshot` (forModel) lists
//  every named element of the frontmost window; it is filtered LOCALLY to what
//  the owner can SEE — any role (slice 1b, owner's ruling 2026-09-30: the
//  screenshot already sends everything visible, so hiding a visible name
//  protects nothing; safety is what an ACTION does, the kernel's job) — ranked
//  against the model's words, and offered with a plain role and a coarse
//  position phrase computed here — never a pixel. `point_at` / `press_element`
//  take a name, a position in the screenshot, or "under the pointer" back;
//  local code resolves it to an exact frame from structure.
//
//  Everything acts through `HarnessServer.answer(line:)` via
//  `RealtimeOpenAppTool.dispatch`; nothing here reads AX or draws.
//

import CoreGraphics
import Foundation

nonisolated enum RealtimeScreenVerbs {
    /// The pointer's hold before it fades when nothing is speaking about it
    /// (a socket caller); the voice loop holds it while the reply plays.
    static let pointHoldSeconds = 2.5
    /// Enough for a settings sidebar and its page; short enough to read.
    static let maximumScreenCandidates = 15
    /// Longer than this is a sentence of the page, not a label you point at.
    static let documentLengthCharacters = 80

    /// The plain word the model hears for a role. Every role is offered
    /// (owner's ruling 2026-09-30: the screenshot already shows it; visibility,
    /// not role, is the line); this only names it.
    static func roleWord(role: String, subrole: String? = nil) -> String {
        if subrole == "AXTabButton" { return "tab" }
        switch role {
        case "AXButton", "AXMenuButton": return "button"
        case "AXCheckBox": return "toggle"
        case "AXRadioButton": return "tab"
        case "AXPopUpButton": return "pop-up menu"
        case "AXLink": return "link"
        case "AXDisclosureTriangle": return "disclosure arrow"
        case "AXStaticText": return "text"
        case "AXRow", "AXCell", "AXOutlineRow": return "row"
        case "AXHeading": return "heading"
        case "AXImage": return "image"
        case "AXGroup": return "group"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return "field"
        case "AXTab", "AXTabGroup": return "tab"
        case "AXMenuItem": return "menu item"
        default: return "element"
        }
    }

    /// Text inputs whose AXValue is what the owner typed: that value is never a
    /// name to offer (a field's own title or description still is).
    static let textInputRoles = AccessibilityElementNode.textInputRoles

    /// Nouns every app puts on everything. They rank only as part of the
    /// query's exact name or phrase, never on their own (live 2026-09-30:
    /// "Models tab" pointed at the status bar's "Cursor Tab").
    static let genericUINouns: Set<String> = ["tab", "tabs", "button", "buttons", "option", "options", "settings", "setting",
                                              "menu", "menus", "panel", "panels", "item", "items", "icon", "icons", "link", "section"]

    /// How near a named neighbour must be to be worth naming, centre to centre.
    static let neighbourReachPoints: CGFloat = 200

    /// Names the trace records as "<private>": paths, file names, quoted
    /// selections. Logging only — the offer itself is judged by visibility.
    static func isPrivateName(_ name: String) -> Bool {
        if RealtimeVoiceVerbs.quotesSomething(name) || name.hasPrefix("~/") { return true }
        if name.split(separator: "/").filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1 { return true }
        return name.range(of: #"\w\.[A-Za-z][A-Za-z0-9]{0,5}\b"#, options: .regularExpression) != nil
    }

    // MARK: The offer (pure)

    /// The display a `snapshot`'s window is mostly on (`windowFrame`, AppKit),
    /// and the part of the window on it; nil with no window frame — then
    /// nothing is offered, because nothing can be checked.
    /// `screenshotDisplay`: the display the model's screenshot showed — then
    /// only what is on it (review 2026-09-30), whichever display the window favours.
    static func visibleWindow(fromSnapshotResponse response: [String: Any], screens: [CGRect],
                              screenshotDisplay: CGRect? = nil) -> (display: CGRect, visible: CGRect)? {
        guard let window = frame(response["windowFrame"]) else { return nil }
        if let screenshotDisplay {
            let visible = window.intersection(screenshotDisplay)
            return visible.isEmpty ? nil : (screenshotDisplay, visible)
        }
        guard let index = CompanionScreenCaptureUtility.bestDisplayIndex(for: window, among: screens) else { return nil }
        return (screens[index], window.intersection(screens[index]))
    }

    /// Pressable means it publishes AXPress. Chromium publishes AXScrollToVisible
    /// and AXShowMenu on nearly everything, so "any action" meant nothing.
    static func publishesPress(_ element: [String: Any]) -> Bool {
        ((element["actions"] as? [String]) ?? []).contains("AXPress")
    }

    /// One element of a `forModel` snapshot, as the pool keeps it.
    struct PoolElement {
        let name: String
        let role: String
        let subrole: String?
        let frame: CGRect
        let pressable: Bool
        let parent: Int?
        /// For a label that publishes no action: the nearest named ancestor
        /// that does and holds it (`press_element` presses that).
        var pressAncestor: RealtimeScreenPressTarget? = nil

        /// press_element has something to click (`RealtimeScreenCandidate.clickTarget`).
        var isClickable: Bool {
            RealtimeScreenCandidate(name: name, role: role, frame: frame, position: "", subrole: subrole, pressable: pressable,
                                    pressAncestor: pressAncestor).clickTarget != nil
        }
    }

    /// Every NAMED element the owner can see in the frontmost window, in tree
    /// order, one per name, and how many were hidden (counted, never listed).
    /// Visible means what `highlight` checks — inside the WINDOW, on the display
    /// that window is mostly on (review 2026-09-30). Hidden: secure fields, a
    /// text input's typed value, a document-length name, the window itself. A
    /// label inside a pressable element with its name (or its frame) is that
    /// element, once.
    static func visiblePool(fromSnapshotResponse response: [String: Any], screens: [CGRect], screenshotDisplay: CGRect? = nil)
        -> (pool: [PoolElement], hiddenCount: Int) {
        guard let (_, visible) = visibleWindow(fromSnapshotResponse: response, screens: screens, screenshotDisplay: screenshotDisplay),
              let window = frame(response["windowFrame"]) else { return ([], 0) }
        let elements = response["elements"] as? [[String: Any]] ?? []
        var pool: [PoolElement] = []
        var hidden = 0
        for element in elements {
            guard let role = element["role"] as? String, role != "AXWindow",
                  let frame = frame(element["frame"]), frame != window else { continue }
            let subrole = element["subrole"] as? String
            // The harness lists these with a null name (withheld at the source): counted, never named.
            if AccessibilityElementNode.withholdsName(entry: element) { hidden += 1; continue }
            guard let name = element["name"] as? String, !name.allSatisfy(\.isWhitespace) else { continue }
            if name.count > documentLengthCharacters || !UntrustedText(name).isPlausibleControlLabel {
                hidden += 1
                continue
            }
            // A secret-shaped name is never a target or an offer (scenario C1: a
            // label's value may be a key); the wire's scrub is the second net.
            if !SecretScanner.matches(in: name).isEmpty {
                hidden += 1
                continue
            }
            guard ActionSafetyKernel.unreachableFrameReason(frame, visibleBounds: visible) == nil else { continue }
            let parentIndex = element["parent"] as? Int
            if let parentIndex, elements.indices.contains(parentIndex),
               publishesPress(elements[parentIndex]),
               let parentFrame = self.frame(elements[parentIndex]["frame"]),
               elements[parentIndex]["name"] as? String == name || parentFrame == frame {
                continue
            }
            guard !pool.contains(where: { $0.name == name }) else { continue }
            let pressable = publishesPress(element)
            let windowArea = window.width * window.height
            var ancestor: RealtimeScreenPressTarget?
            var next = parentIndex
            // `HarnessPolicy.controlLabelled`'s path: up to 3 levels, through labels and anonymous groups only.
            var labelPath = HarnessPolicy.labelRoles.contains(role)
            var levels = 0
            while !pressable, ancestor == nil, let index = next, elements.indices.contains(index) {
                let candidate = elements[index]
                levels += 1
                // A label inside a link or button is pressed through it even when nothing
                // publishes AXPress (Chrome in some modes publishes none, 2026-10-03): the
                // role is the witness, as `HarnessPolicy.controlLabelled` judges it — a
                // Google result's heading came back notPressable here while the harness
                // would have retargeted it to its link.
                if let ancestorName = candidate["name"] as? String, let ancestorRole = candidate["role"] as? String, ancestorRole != "AXWindow",
                   publishesPress(candidate)
                    || (labelPath && levels <= HarnessPolicy.labelToControlLevels && HarnessPolicy.labelledControlRoles.contains(ancestorRole)
                        && UntrustedText(ancestorName).isPlausibleControlLabel),
                   let ancestorFrame = self.frame(candidate["frame"]), ancestorFrame.contains(CGPoint(x: frame.midX, y: frame.midY)),
                   // A whole pane is no press target, as it is no snap target.
                   ancestorFrame.width * ancestorFrame.height <= windowArea / 3 {
                    ancestor = RealtimeScreenPressTarget(name: ancestorName, role: ancestorRole, frame: ancestorFrame)
                }
                let candidateRole = candidate["role"] as? String ?? ""
                labelPath = labelPath && (HarnessPolicy.labelRoles.contains(candidateRole)
                                          || (candidateRole == "AXGroup" && (candidate["name"] as? String) == nil))
                next = candidate["parent"] as? Int
            }
            pool.append(PoolElement(name: name, role: role, subrole: subrole, frame: frame, pressable: pressable, parent: parentIndex,
                                    pressAncestor: ancestor))
        }
        return (pool, hidden)
    }

    static func screenOffer(fromSnapshotResponse response: [String: Any], words: String, screens: [CGRect],
                            screenshotDisplay: CGRect? = nil, limit: Int = maximumScreenCandidates) -> RealtimeScreenOffer {
        let (pool, hidden) = visiblePool(fromSnapshotResponse: response, screens: screens, screenshotDisplay: screenshotDisplay)
        var offered = ranked(pool.map(\.name), words: words, limit: limit).map { pool[$0] }
        // A control that IS the name is the answer, not one of two (scenario A4, three
        // runs 2026-10-02: "sign in" offered the button and the sentence "… Sign in to
        // see your feed.", and the voice asked which). Only bare text goes; another
        // control holding the words is still a real choice.
        let query = rankingTokens(words)
        if !query.isEmpty, offered.contains(where: { labelTokens($0.name) == query && $0.isClickable }) {
            offered.removeAll { labelTokens($0.name) != query && !$0.isClickable }
        }
        // A label brings the value beside it (scenario A6: "where is the phone
        // number" offered only "Phone: "; the number shares no word with the question).
        offered = Array(offered.flatMap { element -> [PoolElement] in
            guard let value = valueBeside(element, in: pool), !offered.contains(where: { $0.name == value.name }) else { return [element] }
            return [element, value]
        }.prefix(limit))
        // Neighbours only from what is offered anyway (review 2026-09-30).
        let neighbours = offered.map { (name: $0.name, frame: $0.frame) }
        let display = visibleWindow(fromSnapshotResponse: response, screens: screens, screenshotDisplay: screenshotDisplay)
            .map { [$0.display] } ?? screens
        return RealtimeScreenOffer(
            candidates: offered.map { element in
                RealtimeScreenCandidate(name: element.name, role: element.role, frame: element.frame,
                                        position: positionPhrase(of: element.frame, neighbours: neighbours, screens: display),
                                        subrole: element.subrole, pressable: element.pressable, pressAncestor: element.pressAncestor)
            },
            elementCount: (response["elements"] as? [[String: Any]])?.count ?? 0,
            privacyDroppedCount: hidden,
            listingIncomplete: !((response["walkStopReasons"] as? [String]) ?? []).isEmpty
        )
    }

    /// The names of the text fields the owner can see (the pool: never a password
    /// box, never a typed value): what an unaimed type_text is told to aim at.
    static func visibleTextFieldNames(fromSnapshotResponse response: [String: Any], screens: [CGRect], screenshotDisplay: CGRect? = nil) -> [String] {
        visiblePool(fromSnapshotResponse: response, screens: screens, screenshotDisplay: screenshotDisplay).pool
            .filter { textInputRoles.contains($0.role) }.map(\.name)
    }

    /// The words a query ranks by, and a name's own (its "(⇧⌘L)" shortcut dropped).
    static func rankingTokens(_ words: String) -> [String] {
        RealtimeVoiceVerbs.foldedTokens(words).filter { !RealtimeVoiceVerbs.ignoredQueryWords.contains($0) }
    }

    static func labelTokens(_ name: String) -> [String] {
        rankingTokens(name.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression))
    }

    /// The text right of a label ending in ":" on the same line ("Phone: " ->
    /// "(02) 5550 1234"), within a neighbour's reach; nil for anything else.
    static func valueBeside(_ label: PoolElement, in pool: [PoolElement]) -> PoolElement? {
        guard label.name.trimmingCharacters(in: .whitespaces).hasSuffix(":") else { return nil }
        let row = label.frame
        return pool.filter { other in
            other.name != label.name && abs(other.frame.midY - row.midY) <= row.height / 2
                && other.frame.minX >= row.maxX - 4 && other.frame.minX - row.maxX <= neighbourReachPoints
        }.min { $0.frame.minX < $1.frame.minX }
    }

    /// Indices of `names`, best first, by tier: the query IS the name (4), the
    /// query's words run in order inside it (3), every distinctive query word is
    /// in it (2), some are (1). A generic UI noun counts only in tiers 4 and 3.
    /// Within a tier: more distinctive words matched, more matched as whole
    /// words, a symbol shortcut the name carries ("⌥⌘J"), fewer words (its
    /// shortcut aside), tree order. Matching is the menu
    /// matcher's `tokensMatch`; no match, no candidate.
    static func ranked(_ names: [String], words: String, limit: Int) -> [Int] {
        let queryTokens = rankingTokens(words)
        let distinctive = Set(queryTokens).subtracting(genericUINouns)
        let shortcuts = words.split(separator: " ").map(String.init).filter { $0.contains { "\u{2318}\u{2325}\u{21E7}\u{2303}".contains($0) } }
        guard !queryTokens.isEmpty || !shortcuts.isEmpty else { return [] }
        typealias Score = (tier: Int, matched: Int, whole: Int, shortcut: Int, length: Int, index: Int)
        let scored: [Score] = names.enumerated().compactMap { index, name in
            let tokens = RealtimeVoiceVerbs.foldedTokens(name).filter { !RealtimeVoiceVerbs.ignoredQueryWords.contains($0) }
            let label = labelTokens(name)
            let matched = distinctive.filter { word in tokens.contains { RealtimeVoiceVerbs.tokensMatch(word, $0) } }.count
            // "agent" is a word of "New Agent" but only the start of "AgentPlan".
            let whole = queryTokens.filter(tokens.contains).count
            let shortcut = shortcuts.contains { name.localizedCaseInsensitiveContains($0) } ? 1 : 0
            let phrase = !queryTokens.isEmpty && tokens.count >= queryTokens.count
                && (0...(tokens.count - queryTokens.count)).contains { start in
                    zip(queryTokens, tokens[start...]).allSatisfy { RealtimeVoiceVerbs.tokensMatch($0, $1) }
                }
            let tier = !queryTokens.isEmpty && label == queryTokens ? 4
                : phrase ? 3
                : !distinctive.isEmpty && matched == distinctive.count ? 2
                : matched > 0 || shortcut > 0 ? 1 : 0
            return tier > 0 ? (tier, matched, whole, shortcut, label.count, index) : nil
        }
        return scored.sorted {
            ($0.tier, $0.matched, $0.whole, $0.shortcut, -$0.length, -$0.index) > ($1.tier, $1.matched, $1.whole, $1.shortcut, -$1.length, -$1.index)
        }
            .prefix(limit).map(\.index)
    }

    // MARK: A name on the live screen (pure)

    /// A name as said: case, accents, spacing and punctuation dropped, and a
    /// trailing "(⇧⌘L)" shortcut — "login" is "Log In", "new agent" is
    /// "New Agent (⇧⌘L)", ASCII "wifi" is "Wi‑Fi".
    static func normalisedName(_ name: String) -> String {
        RealtimeVoiceVerbs.foldedTokens(name.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)).joined()
    }

    /// Which of `names` a spoken name means: the exact name if one is, else
    /// every one equal once normalised. Never a partial match — "post" is not
    /// "Start a post"; a miss says notFound and the model searches.
    static func namedMatches(_ name: String, among names: [String]) -> [Int] {
        let exact = names.indices.filter { names[$0] == name }
        if !exact.isEmpty { return exact }
        let wanted = normalisedName(name)
        guard !wanted.isEmpty else { return [] }
        return names.indices.filter { normalisedName(names[$0]) == wanted }
    }

    /// The visible elements of a `forModel` snapshot a spoken name means — the
    /// same pool find_on_screen offers from, so nothing hidden is reachable by name.
    static func liveCandidates(named name: String, fromSnapshotResponse response: [String: Any], screens: [CGRect],
                               screenshotDisplay: CGRect? = nil) -> [RealtimeScreenCandidate] {
        let (pool, _) = visiblePool(fromSnapshotResponse: response, screens: screens, screenshotDisplay: screenshotDisplay)
        let display = visibleWindow(fromSnapshotResponse: response, screens: screens, screenshotDisplay: screenshotDisplay)
            .map { [$0.display] } ?? screens
        return namedMatches(name, among: pool.map(\.name)).map { index in
            let element = pool[index]
            return RealtimeScreenCandidate(name: element.name, role: element.role, frame: element.frame,
                                           position: positionPhrase(of: element.frame, neighbours: [], screens: display),
                                           subrole: element.subrole, pressable: element.pressable, pressAncestor: element.pressAncestor)
        }
    }

    // MARK: A position in the screenshot (pure)

    /// The SMALLEST visible named element holding `point`, no bigger than a
    /// third of the window: structure answering "what is here?". Measured
    /// 2026-09-30 on Claude Desktop, the system-wide AX hit test named the
    /// aimed element for 17 of 43 points inside it — Chromium answers a hit
    /// with a wrapper whose first named ancestor is the whole pane. The walk
    /// behind find_on_screen holds every element the pointer could be sent to,
    /// and the harness resolves the same names, so this is the first rung.
    static func structuralHit(at point: CGPoint, snapshotResponse: [String: Any], screens: [CGRect]) -> RealtimeScreenHit? {
        guard let window = visibleWindow(fromSnapshotResponse: snapshotResponse, screens: screens) else { return nil }
        // Over a password box: refused like the AX path, never its container.
        let overSecure = (snapshotResponse["elements"] as? [[String: Any]] ?? []).contains { element in
            guard AccessibilityElementNode.mightBeSecure(entry: element), let frame = frame(element["frame"]) else { return false }
            return frame.contains(point)
        }
        if overSecure { return .refused(error: "secureField") }
        let windowArea = window.visible.width * window.visible.height
        let pool = visiblePool(fromSnapshotResponse: snapshotResponse, screens: screens).pool
        guard let smallest = pool.enumerated()
            .filter({ $0.element.frame.contains(point) && $0.element.frame.width * $0.element.frame.height <= windowArea / 3 })
            .min(by: { ($0.element.frame.width * $0.element.frame.height, -$0.offset) < ($1.element.frame.width * $1.element.frame.height, -$1.offset) })?
            .element else { return nil }
        return .element(RealtimeScreenCandidate(name: smallest.name, role: smallest.role, frame: smallest.frame,
                                                position: positionPhrase(of: smallest.frame, neighbours: [], screens: [window.display]),
                                                subrole: smallest.subrole, pressable: smallest.pressable, pressAncestor: smallest.pressAncestor),
                        app: snapshotResponse["bundleIdentifier"] as? String)
    }

    /// The key-down screenshot's fraction (0-1, from its top-left) as an AppKit
    /// point on the display it shows; nil off the image.
    static func screenshotPoint(x: Double, y: Double, display: CGRect) -> CGPoint? {
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: display.minX + CGFloat(x) * display.width, y: display.maxY - CGFloat(y) * display.height)
    }

    /// AppKit (bottom-left, y up) to the hit test's global top-left
    /// coordinates, against the PRIMARY display (WindowPositionManager.swift:235).
    static func topLeftPoint(_ point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// From the element the hit test landed on (index 0) up through its
    /// ancestors: the first with a pointable name (not document-length), a
    /// non-trivial frame, and no bigger than a third of the window. A password
    /// box — or a text field whose subrole did not read — on the way refuses.
    static func snap(_ chain: [RealtimeSnapNode], windowFrame: CGRect?) -> RealtimeSnapOutcome {
        let windowArea = windowFrame.map { $0.width * $0.height }
        // The whole chain first (review 2026-09-30): a password box anywhere on
        // the way refuses, and whatever sits INSIDE a text input is typed text —
        // the input itself is the nearest thing that may be named.
        if chain.contains(where: {
            AccessibilityElementNode.mightBeSecure(role: $0.role, subrole: $0.subrole, subroleReadFailed: $0.subroleReadFailed,
                                                   namedByValue: $0.namedByValue)
        }) {
            return .secure
        }
        let firstInput = chain.firstIndex { textInputRoles.contains($0.role) } ?? 0
        for (index, node) in chain.enumerated() where index >= firstInput {
            guard let name = node.name, !name.allSatisfy(\.isWhitespace), name.count <= documentLengthCharacters,
                  UntrustedText(name).isPlausibleControlLabel, node.frame.width >= 4, node.frame.height >= 4 else { continue }
            if let windowArea, node.frame.width * node.frame.height > windowArea / 3 { continue }
            return .element(index)
        }
        return .nothing
    }

    /// "top right, left of 'Toggle Panel (⌘J)'": the third of its screen the
    /// element's centre is in, and the nearest OTHER control in `neighbours`
    /// within reach — pass only controls already offered: a neighbour's name
    /// goes to the model. AppKit coordinates (y up).
    /// ponytail: with two displays the phrase does not say which one.
    static func positionPhrase(of frame: CGRect, neighbours: [(name: String, frame: CGRect)], screens: [CGRect]) -> String {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let screen = screens.first { $0.contains(centre) } ?? screens.first { $0.intersects(frame) } ?? screens.first ?? .zero
        func third(_ value: CGFloat, _ low: CGFloat, _ length: CGFloat) -> Int {
            length > 0 ? min(2, max(0, Int(((value - low) / length) * 3))) : 1
        }
        let column = ["left", "centre", "right"][third(centre.x, screen.minX, screen.width)]
        let row = third(centre.y, screen.minY, screen.height)
        let region = row == 1 ? (column == "centre" ? "centre" : "\(column) side")
            : "\(row == 2 ? "top" : "bottom") \(column)"
        func distance(_ other: CGRect) -> CGFloat { hypot(other.midX - centre.x, other.midY - centre.y) }
        guard let nearest = neighbours.filter({ $0.frame != frame && distance($0.frame) <= neighbourReachPoints })
            .min(by: { distance($0.frame) < distance($1.frame) }) else { return region }
        let dx = centre.x - nearest.frame.midX, dy = centre.y - nearest.frame.midY
        let relation = abs(dx) >= abs(dy) ? (dx < 0 ? "left of" : "right of") : (dy > 0 ? "above" : "below")
        return "\(region), \(relation) '\(nearest.name)'"
    }

    /// `summarise`'s {x, y, w, h}. Read as NSNumber: decoded JSON holds
    /// NSNumber, an in-process dictionary CGFloat, and `as? Double` reads only
    /// the first (the fixture's frames all came back nil). A null component —
    /// the harness's non-finite frame — is no frame.
    static func frame(_ value: Any?) -> CGRect? {
        guard let frame = value as? [String: Any], let x = (frame["x"] as? NSNumber)?.doubleValue,
              let y = (frame["y"] as? NSNumber)?.doubleValue, let width = (frame["w"] as? NSNumber)?.doubleValue,
              let height = (frame["h"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// One offered control. `frame` (AppKit) stays local: it aims the point's
/// `nearPoint` and never reaches the model.
nonisolated struct RealtimeScreenCandidate: Equatable, Sendable {
    let name: String
    /// The AX role, as the harness reported it.
    let role: String
    let frame: CGRect
    /// `RealtimeScreenVerbs.positionPhrase`, computed when offered.
    let position: String
    var subrole: String? = nil
    /// It publishes an action. A label that does not is pressed through
    /// `pressAncestor`, or not at all (`notPressable`).
    var pressable = true
    var pressAncestor: RealtimeScreenPressTarget? = nil

    var roleWord: String { RealtimeScreenVerbs.roleWord(role: role, subrole: subrole) }

    /// What press_element clicks (the harness's `click`): the element itself when
    /// it publishes a press or the kernel takes a click on its role as ordinary
    /// (a field is focused by clicking it — live 2026-10-02 row 23, "no
    /// click-to-focus tool"); else the pressable element holding a label; else
    /// nothing (a bare label is pointed at, never clicked: the kernel would ask).
    var clickTarget: RealtimeScreenPressTarget? {
        let clickable = pressable || ActionSafetyKernel.navigationalRoles(for: .click).contains(role)
            || subrole.map(ActionSafetyKernel.navigationalPressSubroles.contains) == true
        return clickable ? RealtimeScreenPressTarget(name: name, role: role, frame: frame) : pressAncestor
    }

    var jsonObject: [String: Any] { ["name": name, "role": roleWord, "where": position] }

    /// "group \"Models\"": what was actually aimed at, for the model to repeat.
    var described: String { "\(roleWord) \(UntrustedText(name).forDisplay)" }
}

/// What press_element presses for a label that publishes no action.
nonisolated struct RealtimeScreenPressTarget: Equatable, Sendable {
    let name: String
    let role: String
    let frame: CGRect

    var described: String { "\(RealtimeScreenVerbs.roleWord(role: role)) \(UntrustedText(name).forDisplay)" }
}

/// One element on the way up from a hit test (`RealtimeScreenVerbs.snap`), AppKit frame.
nonisolated struct RealtimeSnapNode: Equatable, Sendable {
    let name: String?
    let role: String
    let subrole: String?
    let frame: CGRect
    var subroleReadFailed = false
    var pressable = false
    /// `name` is its AXValue (no title or description).
    var namedByValue = false
}

nonisolated enum RealtimeSnapOutcome: Equatable, Sendable {
    case element(Int)
    case secure
    case nothing
}

/// What a hit test at a point found (`RealtimeScreenHitTest`).
nonisolated enum RealtimeScreenHit: Equatable, Sendable {
    /// Snapped to a named element; `app` is its bundle identifier.
    case element(RealtimeScreenCandidate, app: String?)
    /// Nothing pointable there.
    case nothing
    /// A password box, or Clicky itself.
    case refused(error: String)

    var candidate: RealtimeScreenCandidate? {
        if case .element(let candidate, _) = self { return candidate }
        return nil
    }
    var name: String? { candidate?.name }
}

/// Where point_at / press_element aim: an element (by its exact name and the
/// point inside it), or — pointing only — just a point (`candidate` nil: the
/// approximate ring). `point` is AppKit; `app` the bundle it came from.
nonisolated struct RealtimeScreenTarget: Equatable, Sendable {
    let candidate: RealtimeScreenCandidate?
    let point: CGPoint
    let app: String?
    let source: RealtimeOpenAppTool.OfferSource
}

/// A name looked up on the live screen: the visible elements it means, and the app read.
nonisolated struct RealtimeScreenLookup: Equatable, Sendable {
    let candidates: [RealtimeScreenCandidate]
    let app: String?
}

nonisolated struct RealtimeScreenOffer: Equatable, Sendable {
    let candidates: [RealtimeScreenCandidate]
    /// Elements in the harness's snapshot, before any filtering.
    let elementCount: Int
    /// Named elements hidden (secure fields, typed values, document-length names). Counted, never listed.
    let privacyDroppedCount: Int
    /// The walk hit a limit, so a missing control may simply be unread.
    let listingIncomplete: Bool
}
