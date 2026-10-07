//
//  HarnessServer.swift
//  leanring-buddy
//
//  Slice one of a callable control interface: the harness that already exists
//  as `--ax-select` and friends, reachable by something other than a human
//  holding down a countdown.
//
//  Why a Unix domain socket and not a local HTTP port: a port is a
//  machine-control surface every process on this box can reach and nothing
//  authenticates. A socket file is an ordinary file — mode 0600 in the user's
//  Application Support directory — so the kernel's own permission check is the
//  access control, and it is one we did not have to write.
//
//  Everything here is a thin shell over code that was measured elsewhere:
//  AccessibilityTreeWalker reads, ElementActionIntentResolver aims,
//  ActionSafetyKernel decides, AccessibilityActionPerformer /
//  AccessibilitySelectionPerformer act, ActionVerifier goes and looks. The new
//  parts are the transport, the audit trail, and three refusals.
//

import AppKit
import ApplicationServices
import Darwin
import Foundation

// MARK: - Wire types

/// One line in. Everything past `verb` is optional because `ping` needs none of
/// it and a missing field must be a structured refusal, never a crash.
struct HarnessRawRequest: Decodable {
    let id: String?
    let verb: String
    let title: String?
    let role: String?
    let withinNamed: String?
    let nearPoint: HarnessPoint?
    let dryRun: Bool?
    let confirmed: Bool?
    /// A confirmation ticket id from an earlier `confirmationRequired` response,
    /// answered by the owner in the Clicky panel. See `HarnessConfirmations`.
    let ticket: String?

    /// menu / menus only: the path down the menu bar, e.g. ["File", "New Folder"].
    let path: [String]?
    /// menu only: a status icon instead of a path — identifier, name, or owner.
    let statusItem: String?

    /// windows / focus only: which application, by bundle identifier or name.
    /// Absent means the frontmost one, which is what every other verb assumes.
    let app: String?

    /// Every verb that reads "the frontmost app": refuse unless that app is this
    /// one, by bundle identifier or name. See `HarnessPolicy.appMatches`.
    let expectApp: String?

    // type only
    let text: String?
    let mode: String?
    /// `"focused"`, or absent for the ordinary name-resolved path.
    let target: String?
    let thenConfirm: Bool?

    /// look only: force a rung of the escalation ladder instead of choosing one.
    let tier: String?
    /// press / select / open / type: on a `notFound` or `ambiguous`, come back
    /// with the picture rather than only the offer of one.
    let escalate: Bool?

    /// highlight only: how long the outline stays, and a short caption for it.
    let seconds: Double?
    let label: String?
    /// highlight only: the voice loop's `point_at` — the pointer flies to the
    /// element and marks it by role (`ElementPointer`), instead of the outline.
    let pointer: Bool?
    /// snapshot / menus only: see `HarnessRequest.forModel`.
    let forModel: Bool?
    /// press only: see `HarnessRequest.requireAtPoint`.
    let requireAtPoint: Bool?
    /// highlight + pointer only: see `HarnessRequest.speechHold`.
    let speechHold: Bool?
    /// press only: see `HarnessRequest.labelTitle`.
    let labelTitle: String?
    /// scroll only: up / down / left / right, and how many pages (default 1).
    let direction: String?
    let amount: Double?
    /// openURL only: the http/https page to open (`HarnessHands.validatedWebURL`).
    let url: String?
    /// click (`axPress` / `click`) and type (`axWrite` / `keystrokes`) only: run
    /// that one method and no fallback — how the hands probe measures each.
    let method: String?
    /// visionClick only: the owner's words named a pointer location and the
    /// point is where their mouse was. Honoured only while the mouse is still there.
    let ownerPointed: Bool?
}

struct HarnessPoint: Decodable {
    let x: Double
    let y: Double
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

enum HarnessVerb: String, CaseIterable {
    case ping
    case snapshot
    case press
    case select
    case type
    case open

    /// Press a menu item by its path down the menu bar.
    case menu
    /// List what the menu bar currently offers. Read-only, and its own verb
    /// because a full listing costs 0.3-1.6 s — folding it into `snapshot`
    /// would put that on every read.
    case menus

    /// What windows an application has, and what applications are running.
    /// Read-only, and the applications half costs no AX reads at all.
    case windows
    /// Point the harness at a different window. Every other verb anchors on
    /// whatever the human left in front; this is how a caller moves that anchor.
    case focus

    /// The smallest picture that would let a caller decide, plus the structural
    /// candidates inside it. Read-only — it takes a photograph and changes
    /// nothing — so it survives the kill switch, exactly like `snapshot`.
    case look

    /// Start (or activate) an installed application by bundle identifier or
    /// exact name, and wait until it says it is in front.
    case launch

    /// Every status icon on the menu bar's right side, from every process that
    /// owns one. Read-only, and its own verb because it is a sweep over ~45
    /// processes (1.6 s), not a read of the frontmost app.
    case status

    /// Outline a resolved element on the overlay for a few seconds. Read-only:
    /// it draws on Clicky's own click-through window and sends the target app
    /// nothing, so like `snapshot` it survives the kill switch.
    case highlight

    /// Scroll the frontmost window (or a named / pointed-at area of it).
    case scroll

    /// Press like a human: `AXPress`, or a real left click at the element's
    /// visible centre when that is what works (`HarnessHands`). Kernel as `press`.
    case click

    /// Open an http/https page in the default or a named browser.
    case openURL

    /// The last rung: click what is drawn at a point that AX cannot name, only
    /// when the words OCR reads there are the caller's label (`visionClickResponse`).
    case visionClick

    /// Whether this verb can change the world. The kill switch stops these and
    /// leaves the read-only pair working, so an operator who tripped it can
    /// still look at the machine and find out why.
    var isMutating: Bool {
        switch self {
        case .ping, .snapshot, .menus, .windows, .look, .status, .highlight: return false
        case .press, .select, .type, .open, .menu, .focus, .launch, .scroll, .click, .openURL, .visionClick: return true
        }
    }

    var elementAction: ElementAction? {
        switch self {
        case .press: return .press
        case .select: return .select
        case .type: return .type
        case .open: return .open
        case .click: return .click
        // `menu` acts, but it does not resolve a name in the focused window, so
        // it does not go through the name-resolving path at all. Returning nil
        // here is what keeps the "an acting verb needs a title" rule honest —
        // a menu request carries a path instead.
        //
        // `focus` acts too, and is nil here for the same reason: its target is a
        // window, not a named element inside one, so it never enters the
        // name-resolving path and its kernel check is `evaluateFocus`.
        //
        // `look` is nil for a third reason: it does not act at all. It resolves
        // a name only to find out how many things carry it.
        // `launch` targets an application, not an element: `evaluateLaunch`.
        // `highlight` resolves exactly like a press but performs nothing — see `highlightResponse`.
        // `openURL` targets a page in a browser, not an element: `openURLResponse`.
        // `visionClick` aims at a point, not a name in the tree: `visionClickResponse`.
        case .ping, .snapshot, .menu, .menus, .windows, .focus, .look, .launch, .status, .highlight, .scroll, .openURL, .visionClick: return nil
        }
    }
}

/// A request we refused to even attempt. Distinct from a request we ran and
/// refused on policy — both get logged, and confusing them would hide which.
enum HarnessRequestError: Error, Equatable {
    case malformedJSON(String)
    case unknownVerb(String)
    case missingField(String)

    /// A field that is present, well-typed and not a value we recognise —
    /// `"mode":"overwrite"`, `"target":"whatever"`. Same reason `unknownVerb`
    /// exists: the near-miss is exactly the case where guessing is worst.
    case invalidField(field: String, value: String)

    var code: String {
        switch self {
        case .malformedJSON: return "malformedJSON"
        case .unknownVerb: return "unknownVerb"
        case .missingField: return "missingField"
        case .invalidField: return "invalidField"
        }
    }

    var message: String {
        switch self {
        case .malformedJSON(let detail):
            return "could not parse the line as JSON: \(detail)"
        case .unknownVerb(let verb):
            // Never guess. A near-miss verb that gets helpfully corrected into
            // a press is the whole failure mode this interface exists to avoid.
            return "unknown verb \"\(verb)\" — known verbs: \(HarnessVerb.allCases.map(\.rawValue).joined(separator: ", "))"
        case .missingField(let field):
            return "missing required field \"\(field)\""
        case .invalidField(let field, let value):
            return "field \"\(field)\" does not accept \"\(value)\""
        }
    }
}

/// A decoded, validated request. Having the verb as an enum and the title as a
/// non-optional for the acting verbs means the executor cannot be handed a
/// half-formed command.
struct HarnessRequest: Equatable {
    let id: String
    let verb: HarnessVerb
    let title: String
    let role: String?
    let withinNamed: String?
    let nearPoint: CGPoint?
    let requestedDryRun: Bool?
    let confirmed: Bool

    // type only. Defaulted so every existing construction still reads the same.
    var text: String = ""
    var mode: TypeMode = .insert
    /// Aim at whatever holds keyboard focus instead of resolving a name.
    var aimAtFocus: Bool = false
    /// highlight only: the walked window itself. System Settings publishes its
    /// window with no AXTitle (2026-09-24), so no name can reach it.
    var aimAtWindow: Bool = false
    var thenConfirm: Bool = false

    /// A confirmation ticket the owner answered in-process. nil means none offered.
    var ticket: String? = nil

    /// menu / menus only.
    var path: [String] = []
    /// menu only: press a status icon instead of a path. One target per request.
    var statusItem: String? = nil

    /// windows / focus only. nil means the frontmost application.
    var app: String? = nil

    /// snapshot / press / select / type / open / menu / menus / look. nil means
    /// no expectation — act in whatever is in front, exactly as before.
    var expectApp: String? = nil

    /// look only. nil means "choose the rung".
    var tier: EscalationLadder.Tier? = nil
    /// Acting verbs only: whether a failed resolution should pay for a capture.
    var escalate: Bool = false

    /// highlight only, already clamped and validated by `decode`.
    var highlightSeconds: Double = HarnessPolicy.defaultHighlightSeconds
    var label: String? = nil
    /// highlight only: draw `ElementPointer` instead of the outline.
    var pointer: Bool = false
    /// snapshot / menus only: the voice loop's read, whose names go to a remote
    /// model, so the per-app policy applies (`modelReadRefusal`).
    var forModel: Bool = false
    /// press, and every pointer: refuse unless the resolved element contains
    /// `nearPoint` — a single match skips the resolver's point narrowing, so a
    /// same-named element elsewhere would otherwise be the one acted on.
    var requireAtPoint: Bool = false
    /// highlight + pointer only (`"target":"point"`): no element, just an
    /// approximate ring at `nearPoint`.
    var aimAtPoint: Bool = false
    /// highlight + pointer only: the voice loop's pointer, held while its reply
    /// plays (`ElementPointer.holdWhile`); without it the request's `seconds` hold.
    var speechHold: Bool = false
    /// press only: the name of the label the voice loop aimed at when it presses
    /// that label's pressable ancestor (`title`). The kernel word-checks both.
    var labelTitle: String? = nil
    /// scroll only.
    var scrollDirection: ScrollDirection? = nil
    var scrollPages: Double = 1
    /// click / type only: the one method to run, no fallback (the hands probe).
    var forcedClickMethod: ClickMethod? = nil
    var forcedTypeMethod: TypeMethod? = nil
    /// openURL only, validated by `decode`.
    var url: URL? = nil
    /// visionClick only: see `HarnessRawRequest.ownerPointed`.
    var ownerPointed: Bool = false
}

// MARK: - Pure decision logic
//
// Everything in this section is a pure function of its arguments, which is the
// half of this file a unit test can honestly prove. The cross-process half is
// proven by running it — see the transcript, not the tests.

enum HarnessPolicy {

    /// Roles that label a control without being one.
    static let labelRoles: Set<String> = ["AXHeading", "AXStaticText", "AXImage"]
    /// What a label may stand for: a link or a button.
    static let labelledControlRoles: Set<String> = ["AXLink", "AXButton"]
    /// How far up a label may sit inside its control.
    static let labelToControlLevels = 3

    /// The link or button the last node of `chain` (root ... node) labels, or
    /// nil. Live 2026-10-02: Google puts a result's title in an `AXHeading`
    /// inside the `AXLink`, the name resolved to the heading, and the kernel
    /// asked "unrecognised role AXHeading" about an ordinary link (8 s waiting
    /// on Allow). That heading published AXPress — Chromium's click-ancestor
    /// verb — so "publishes a press" cannot tell label from control; the role can.
    /// Only labels and anonymous wrappers are passed through: a named group or
    /// any other control on the way up is a thing of its own, and stops it.
    /// The control must carry a plausible name of its own. Not AXPress: the
    /// hands probe's Chrome (2026-10-03) published none on ANY element, link and
    /// button included, so the role is the only witness that holds in every mode.
    static func controlLabelled(byLastOf chain: [AccessibilityElementNode]) -> AccessibilityElementNode? {
        guard let label = chain.last, labelRoles.contains(label.role) else { return nil }
        for ancestor in chain.dropLast().reversed().prefix(labelToControlLevels) {
            if labelledControlRoles.contains(ancestor.role) {
                // Named, or the kernel refuses it as implausible — worse than the question it replaces.
                return ancestor.displayName?.isPlausibleControlLabel == true ? ancestor : nil
            }
            guard labelRoles.contains(ancestor.role) || (ancestor.role == "AXGroup" && ancestor.displayName == nil) else { return nil }
        }
        return nil
    }

    /// The text field a label names, for `type` aimed at a label. Generality
    /// suite 2026-10-06: "Save As:" (TextEdit) and Font Book's "Search" resolved
    /// to the AXStaticText beside the field and the kernel refused typing into
    /// it. In order, each only when it picks out one field:
    /// 1. the app's own link (`linked`: AXServesAsTitleForUIElements /
    ///    AXLinkedUIElements on the label, or the field's AXTitleUIElement);
    /// 2. the nearest text input to the label's right on its row, or below it,
    ///    inside the label's own container — two equally near is no answer;
    /// 3. a text input in the window whose title, description or placeholder IS
    ///    the name (a toolbar label sits under its field, so 2 misses it).
    /// The kernel then judges the field like any other (a password box refuses).
    static func fieldLabelled(by label: AccessibilityElementNode, chain: [AccessibilityElementNode], name: String,
                              linked: (AccessibilityElementNode) -> Bool) -> AccessibilityElementNode? {
        guard chain.count >= 2, let window = chain.first else { return nil }
        func inputs(under root: AccessibilityElementNode) -> [AccessibilityElementNode] {
            // A password box is a candidate too (review of 5ceefcf): "Password:" must reach it, and the kernel
            // refuses it — never the nearest plain field, "Password hint".
            (AccessibilityElementNode.textInputRoles.contains(root.role) || root.isSecure ? [root] : []) + root.children.flatMap(inputs(under:))
        }
        let fields = inputs(under: window)
        let tied = fields.filter(linked)
        if tied.count == 1 { return tied[0] }
        let labelFrame = label.frameInAppKitCoordinates
        // AppKit coordinates: "below" is a smaller y.
        let near = inputs(under: chain[chain.count - 2]).compactMap { field -> (AccessibilityElementNode, CGFloat)? in
            let frame = field.frameInAppKitCoordinates
            guard frame.width > 0, frame.height > 0 else { return nil }
            if frame.minY < labelFrame.maxY, frame.maxY > labelFrame.minY, frame.minX >= labelFrame.maxX - 2 {
                return (field, frame.minX - labelFrame.maxX)
            }
            if frame.minX < labelFrame.maxX, frame.maxX > labelFrame.minX, frame.maxY <= labelFrame.minY + 2 {
                return (field, labelFrame.minY - frame.maxY)
            }
            return nil
        }.sorted { $0.1 < $1.1 }
        if let nearest = near.first { return near.count == 1 || near[1].1 - nearest.1 >= 1 ? nearest.0 : nil }
        let named = fields.filter { $0.fieldLabel?.raw == name }
        return named.count == 1 ? named[0] : nil
    }

    /// `fieldLabelled`'s `linked`, read live: the label's own AXServesAsTitleForUIElements and
    /// AXLinkedUIElements once, then each candidate field's AXTitleUIElement (one read per field).
    static func liveLabelLink(_ label: AccessibilityElementNode) -> (AccessibilityElementNode) -> Bool {
        guard let labelElement = label.accessibilityElement else { return { _ in false } }
        func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
            return (value as? [AXUIElement]) ?? []
        }
        let served = elements(labelElement, "AXServesAsTitleForUIElements") + elements(labelElement, "AXLinkedUIElements")
        return { field in
            guard let fieldElement = field.accessibilityElement else { return false }
            if served.contains(where: { CFEqual($0, fieldElement) }) { return true }
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(fieldElement, kAXTitleUIElementAttribute as CFString, &title) == .success,
                  let title, CFGetTypeID(title) == AXUIElementGetTypeID() else { return false }
            return CFEqual(title, labelElement)
        }
    }

    static func decode(line: String) -> Result<HarnessRequest, HarnessRequestError> {
        guard let data = line.data(using: .utf8) else {
            return .failure(.malformedJSON("not valid UTF-8"))
        }

        let raw: HarnessRawRequest
        do {
            raw = try JSONDecoder().decode(HarnessRawRequest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            return .failure(.missingField(key.stringValue))
        } catch {
            return .failure(.malformedJSON(String(describing: error).prefix(200).description))
        }

        guard let verb = HarnessVerb(rawValue: raw.verb) else {
            return .failure(.unknownVerb(raw.verb))
        }

        // "focused" is the only value `target` takes. Anything else is a typo
        // that would otherwise be silently treated as "resolve by name" and aim
        // somewhere the caller did not ask for.
        var aimAtFocus = false
        var aimAtWindow = false
        var aimAtPoint = false
        if let target = raw.target {
            switch target {
            case "focused": aimAtFocus = true
            // Outline only. An acting verb aimed at a whole window would press
            // or type into the window element, which no caller means.
            case "window" where verb == .highlight: aimAtWindow = true
            // The voice loop's approximate ring: a point with nothing to name there.
            case "point" where verb == .highlight && raw.pointer == true && raw.nearPoint != nil: aimAtPoint = true
            default: return .failure(.invalidField(field: "target", value: target))
            }
        }

        // A name is what an acting verb aims with — unless it is aiming by focus,
        // which is the whole point of the focus target.
        if verb.elementAction != nil || verb == .highlight, !aimAtFocus, !aimAtWindow, !aimAtPoint, (raw.title ?? "").isEmpty {
            return .failure(.missingField("title"))
        }

        // A menu path is that verb's whole aim, so an empty one is a missing
        // field rather than "the menu bar itself".
        let path = raw.path ?? []
        var statusItem: String?
        if verb == .menu {
            if let requested = raw.statusItem {
                // Empty is a typo, not "any icon"; and with a path too there
                // would be two targets in one request.
                guard !requested.isEmpty, path.isEmpty else {
                    return .failure(.invalidField(field: "statusItem", value: requested))
                }
                statusItem = requested
            } else if path.isEmpty {
                return .failure(.missingField("path"))
            }
        }

        // `focus` aims with either half: an app (bring Finder forward), a title
        // (raise that window in whatever is already frontmost), or both.
        // Neither is not a default — it is a request to focus nothing.
        if verb == .focus, (raw.app ?? "").isEmpty, (raw.title ?? "").isEmpty {
            return .failure(.missingField("app"))
        }

        // `launch` names an installed application and nothing else. A path could
        // name a script or an installer — exactly what `AXOpen`'s "opening always
        // asks" rule exists for — so a slash is refused, not resolved.
        if verb == .launch {
            guard let app = raw.app, !app.isEmpty else { return .failure(.missingField("app")) }
            guard !app.contains("/") else { return .failure(.invalidField(field: "app", value: app)) }
        }

        // A forced rung, validated the same way `mode` and `target` are: a
        // typo'd tier would otherwise be silently ignored and the caller would
        // get a rung it did not ask for, which is the whole failure mode this
        // interface refuses to have. `"none"` is rejected too — it is the rung
        // that takes no picture, so forcing it is not a request.
        var tier: EscalationLadder.Tier?
        if let requestedTier = raw.tier {
            guard let parsed = EscalationLadder.Tier(rawValue: requestedTier), parsed != .none else {
                return .failure(.invalidField(field: "tier", value: requestedTier))
            }
            tier = parsed
        }

        // An empty expectation is refused, not read as "none": a planner that
        // sends `""` meant to name an app, and silently dropping the guard is
        // the near-miss-turned-default this interface refuses everywhere else.
        if raw.expectApp?.isEmpty == true {
            return .failure(.invalidField(field: "expectApp", value: ""))
        }
        // A status listing spans every process, so an expectation about "the
        // app" has nothing to be checked against — refused, not silently ignored.
        if verb == .status, let expectApp = raw.expectApp {
            return .failure(.invalidField(field: "expectApp", value: expectApp))
        }
        // An empty ticket is a caller that lost the id, not a request without one.
        if raw.ticket?.isEmpty == true {
            return .failure(.invalidField(field: "ticket", value: ""))
        }

        // A caption goes on screen, so it follows the rule for any name we show:
        // an empty, document-length or control-character label is refused, not drawn.
        if let label = raw.label, !UntrustedText(label).isPlausibleControlLabel {
            return .failure(.invalidField(field: "label", value: UntrustedText(label).forDisplay))
        }
        // A pointer is an outline's style, never an acting verb's option.
        if raw.pointer == true, verb != .highlight {
            return .failure(.invalidField(field: "pointer", value: "true"))
        }
        // The pointer aims where the offer saw the control; without the point
        // it cannot tell that control from a same-named one elsewhere.
        if raw.pointer == true, raw.nearPoint == nil {
            return .failure(.missingField("nearPoint"))
        }
        if raw.forModel == true, verb != .snapshot, verb != .menus {
            return .failure(.invalidField(field: "forModel", value: "true"))
        }
        if raw.speechHold == true, verb != .highlight || raw.pointer != true {
            return .failure(.invalidField(field: "speechHold", value: "true"))
        }
        // A label's own words, checked by the kernel beside the ancestor pressed for it.
        if let labelTitle = raw.labelTitle {
            guard verb == .press || verb == .click, UntrustedText(labelTitle).isPlausibleControlLabel else {
                return .failure(.invalidField(field: "labelTitle", value: UntrustedText(labelTitle).forDisplay))
            }
        }
        if raw.requireAtPoint == true {
            // type_text aims like press_element: the named field must be the one at the point.
            guard verb == .press || verb == .type || verb == .click || verb == .select else {
                return .failure(.invalidField(field: "requireAtPoint", value: "true"))
            }
            guard raw.nearPoint != nil else { return .failure(.missingField("nearPoint")) }
        }

        // A direction is the scroll's whole aim; on any other verb it is a typo.
        var scrollDirection: ScrollDirection?
        var scrollPages = 1.0
        if verb == .scroll {
            guard let requested = raw.direction else { return .failure(.missingField("direction")) }
            guard let parsed = ScrollDirection(rawValue: requested) else {
                return .failure(.invalidField(field: "direction", value: requested))
            }
            scrollDirection = parsed
            if let amount = raw.amount {
                guard amount > 0, amount <= HarnessScroll.maximumPages else {
                    return .failure(.invalidField(field: "amount", value: String(amount)))
                }
                scrollPages = amount
            }
        } else if let stray = raw.direction ?? raw.amount.map({ String($0) }) {
            return .failure(.invalidField(field: raw.direction != nil ? "direction" : "amount", value: stray))
        }

        // A forced method belongs to the verb that has it; anywhere else it is a typo.
        var forcedClickMethod: ClickMethod?
        var forcedTypeMethod: TypeMethod?
        if let requested = raw.method {
            switch verb {
            case .click: forcedClickMethod = ClickMethod(rawValue: requested)
            case .type: forcedTypeMethod = TypeMethod(rawValue: requested)
            default: break
            }
            guard forcedClickMethod != nil || forcedTypeMethod != nil else {
                return .failure(.invalidField(field: "method", value: requested))
            }
        }

        // openURL: http/https only — `file:` and `javascript:` are not pages.
        var url: URL?
        if verb == .openURL {
            guard let requested = raw.url, !requested.isEmpty else { return .failure(.missingField("url")) }
            guard let valid = HarnessHands.validatedWebURL(requested) else {
                return .failure(.invalidField(field: "url", value: UntrustedText(requested).forDisplay))
            }
            // Like `launch`: an app by name or bundle identifier, never a path.
            if let app = raw.app, app.contains("/") { return .failure(.invalidField(field: "app", value: app)) }
            url = valid
        } else if let stray = raw.url {
            return .failure(.invalidField(field: "url", value: UntrustedText(stray).forDisplay))
        }

        // visionClick: a point to look at, and the words to read there — or the
        // owner's own pointer. The words go on a card and into the audit, so a
        // plain label only. `ownerPointed` belongs to this verb alone.
        if verb == .visionClick {
            guard raw.nearPoint != nil else { return .failure(.missingField("nearPoint")) }
            let title = raw.title ?? ""
            if title.isEmpty, raw.ownerPointed != true { return .failure(.missingField("title")) }
            if !title.isEmpty, !UntrustedText(title).isPlausibleControlLabel {
                return .failure(.invalidField(field: "title", value: UntrustedText(title).forDisplay))
            }
        } else if raw.ownerPointed == true {
            return .failure(.invalidField(field: "ownerPointed", value: "true"))
        }

        var mode = TypeMode.insert
        if verb == .type {
            guard !(raw.text ?? "").isEmpty else {
                return .failure(.missingField("text"))
            }
            // Return SENDS in a chat composer and runs a command in a terminal: no caller's
            // text may carry a line break, by any typing path (AX write or keystrokes).
            // ponytail: refused everywhere, a multi-line document editor too; allow per role when one needs it.
            guard !HarnessHands.containsControlCharacters(raw.text ?? "") else {
                return .failure(.invalidField(field: "text", value: "a line break or another control character (Return sends a message)"))
            }
            if let requestedMode = raw.mode {
                guard let parsed = TypeMode(rawValue: requestedMode) else {
                    return .failure(.invalidField(field: "mode", value: requestedMode))
                }
                mode = parsed
            }
        }

        return .success(HarnessRequest(
            id: raw.id ?? "",
            verb: verb,
            // The audit line's `target` is the title, and for a menu the path
            // IS the target. One joined string keeps the log readable without
            // a second field only two verbs would ever set.
            title: (verb == .menu || verb == .menus) && !path.isEmpty
                ? path.joined(separator: " > ")
                // openURL's target is its page, so the audit line and a ticket name it.
                : (statusItem ?? url?.absoluteString ?? raw.title ?? ""),
            role: raw.role,
            withinNamed: raw.withinNamed,
            nearPoint: raw.nearPoint?.cgPoint,
            requestedDryRun: raw.dryRun,
            confirmed: raw.confirmed ?? false,
            text: raw.text ?? "",
            mode: mode,
            aimAtFocus: aimAtFocus,
            aimAtWindow: aimAtWindow,
            thenConfirm: raw.thenConfirm ?? false,
            ticket: raw.ticket,
            path: path,
            statusItem: statusItem,
            app: (raw.app?.isEmpty == false) ? raw.app : nil,
            expectApp: raw.expectApp,
            tier: tier,
            escalate: raw.escalate ?? false,
            highlightSeconds: clampedHighlightSeconds(raw.seconds),
            label: raw.label,
            pointer: raw.pointer ?? false,
            forModel: raw.forModel ?? false,
            requireAtPoint: raw.requireAtPoint ?? false,
            aimAtPoint: aimAtPoint,
            speechHold: raw.speechHold ?? false,
            labelTitle: raw.labelTitle,
            scrollDirection: scrollDirection,
            scrollPages: scrollPages,
            forcedClickMethod: forcedClickMethod,
            forcedTypeMethod: forcedTypeMethod,
            url: url,
            ownerPointed: raw.ownerPointed ?? false
        ))
    }

    static let defaultHighlightSeconds = 2.0

    /// The voice loop's pointer, after the resolver: never onto a password box
    /// or what may be one (`AccessibilityElementNode.mightBeSecure`), and only
    /// where the offer saw it. A single match skips the resolver's `nearPoint`
    /// narrowing, so a control that is gone and a same-named one elsewhere would
    /// otherwise be pointed at.
    static func pointerRefusal(resolvedFrame: CGRect, nearPoint: CGPoint?, role: String, subrole: String?,
                               subroleReadFailed: Bool, namedByValue: Bool = false) -> (code: String, message: String)? {
        if AccessibilityElementNode.mightBeSecure(role: role, subrole: subrole, subroleReadFailed: subroleReadFailed,
                                                  namedByValue: namedByValue) {
            return ("secureField", "the element is a secure text field (or a text field whose subrole could not be read); nothing is pointed at")
        }
        return movedRefusal(resolvedFrame: resolvedFrame, nearPoint: nearPoint)
    }

    /// Whether `type` asks the live element its four questions — one of them its
    /// VALUE. Never for what might be a password box (role, subrole, or a text
    /// input whose subrole did not read): the kernel refuses those unread.
    static func readsTypingContext(verb: HarnessVerb, of node: AccessibilityElementNode) -> Bool {
        verb == .type && !node.mightBeSecure
    }

    /// `actResponse`'s look before the kernel — the call site itself, so a test
    /// holds that `value` is never asked of what might be a password box. Also
    /// the `field` the answer carries: what it is called, never its value.
    static func typingContext(verb: HarnessVerb, mode: TypeMode, aimedByFocus: Bool, of node: AccessibilityElementNode,
                              settable: () -> Set<String>, value: () -> String?)
        -> (context: ActionSafetyKernel.TypingContext, field: [String: Any])? {
        guard readsTypingContext(verb: verb, of: node) else { return nil }
        let settableAttributes = settable()
        let valueLength = (value() ?? "").count
        let label = node.fieldLabel?.isPlausibleControlLabel == true ? node.fieldLabel?.raw : nil
        return (ActionSafetyKernel.TypingContext(mode: mode, settableAttributes: settableAttributes,
                                                 currentValueLength: valueLength, aimedByFocus: aimedByFocus),
                ["settableAttributes": settableAttributes.sorted(), "valueLength": valueLength,
                 "mode": mode.rawValue, "label": label ?? NSNull()])
    }

    /// `type`'s own evidence: lengths, and whether the text read back — never
    /// the field's contents (review 2026-10-02: `valueAfter` echoed them onto
    /// the socket and the flight recorder).
    static func typedEvidence(_ outcome: AccessibilityTypePerformer.Outcome, wrote text: String)
        -> (performed: [String: Any], containsText: Bool) {
        let containsText = outcome.valueAfter?.contains(text) ?? false
        return ([
            "status": outcome.error == .success ? "sent" : "failed",
            "attributeWritten": outcome.attributeWritten,
            "axErrorRawValue": outcome.error.rawValue,
            "milliseconds": outcome.milliseconds,
            "valueLengthBefore": outcome.valueLengthBefore,
            "valueLengthAfter": outcome.valueAfter?.count ?? NSNull(),
            "readBackContainsText": containsText
        ], containsText)
    }

    /// `requireAtPoint`'s check, shared by the pointer and press_element.
    /// May an app's names go to the model? The policy file read once, failing
    /// closed: unreadable refuses, missing allows, `refuse` refuses.
    static func policyAllowsModelRead(bundleIdentifier: String?, load: HarnessAppPolicy.Load) -> Bool {
        switch load {
        case .missing: return true
        case .unreadable: return false
        case .loaded(let policy, _): return modelReadRefusal(forModel: true, bundleIdentifier: bundleIdentifier, policy: policy) == nil
        }
    }

    static func movedRefusal(resolvedFrame: CGRect, nearPoint: CGPoint?) -> (code: String, message: String)? {
        guard let nearPoint, resolvedFrame.contains(nearPoint) else {
            return ("elementMoved", "the element with that name is no longer where it was aimed; nothing was done to it")
        }
        return nil
    }

    /// `snapshot` / `menus` with `forModel`: the voice loop's reads, whose names
    /// go to a remote model. A policy `refuse` is "do not touch this app", and
    /// handing its names to a model counts, as a photograph does for `look`.
    /// `confirm` gates acting, not reading. nil policy = no file = allow.
    static func modelReadRefusal(forModel: Bool, bundleIdentifier: String?, policy: HarnessAppPolicy.Policy?) -> String? {
        guard forModel, HarnessAppPolicy.verdict(for: bundleIdentifier, in: policy).0 == .refuse else { return nil }
        return "app policy refuses \(bundleIdentifier ?? "this app") — none of its names were read for the model"
    }

    /// Long enough to see, short enough that a forgotten outline cannot sit over
    /// the owner's work: 0.5-10 s, default 2.
    static func clampedHighlightSeconds(_ requested: Double?) -> Double {
        min(max(requested ?? defaultHighlightSeconds, 0.5), 10)
    }

    /// Whether the app a verb actually read is the one the caller expected.
    ///
    /// Case-insensitive exact equality, and nothing fuzzier. Measured
    /// 2026-09-11: `focus Finder` confirmed, 0.8 s later `menu File > …` read
    /// Claude Desktop's menu bar — which also has "Close Window". A prefix or
    /// contains match here would be a guess about which app to act in.
    static func appMatches(expected: String, bundleIdentifier: String?, name: String?) -> Bool {
        [bundleIdentifier, name].contains { $0?.caseInsensitiveCompare(expected) == .orderedSame }
    }

    /// A request may turn a dry run **on**; it may never turn one off.
    ///
    /// `--harness-dry-run` is an operator's switch on their own machine. If a
    /// caller could clear it, it would not be a switch, it would be a default —
    /// and the caller is the party this whole interface exists to constrain.
    static func effectiveDryRun(requested: Bool?, globalDefault: Bool) -> Bool {
        globalDefault || (requested ?? false)
    }

    static let killSwitchReason =
        "harness kill switch is present (HARNESS_DISABLED) — mutating verbs are refused; ping and snapshot still work"

    /// nil when the verb may proceed.
    static func killSwitchRefusal(verb: HarnessVerb, killSwitchPresent: Bool) -> String? {
        (killSwitchPresent && verb.isMutating) ? killSwitchReason : nil
    }

    /// The login hand-over: while secure input is on a password is being typed,
    /// and it is the owner's to type. `type` and every photograph refuse;
    /// pointing, pressing and reading names (which never carry a password
    /// box's contents) go on. nil when the verb may proceed.
    static func handOverRefusal(verb: HarnessVerb, secureInput: SecureInputState) -> String? {
        guard secureInput.isOn, verb == .type || verb == .look else { return nil }
        return handOverMessage(secureInput)
    }

    static func handOverMessage(_ secureInput: SecureInputState) -> String {
        let holder = secureInput.holderName.map { " in \(UntrustedText($0).forDisplay)" } ?? ""
        return "secure typing is on\(holder) — a password is the owner's to type, so nothing is typed or photographed "
            + "until it is off; pointing still works"
    }

    /// Whether a kernel decision may run with no human involved: only `.allow`.
    ///
    /// `requireConfirmation` is the kernel asking a human, and no human sits on
    /// the socket — so a socket client can never approve its own question.
    /// Owner's ruling 2026-09-12: `"confirmed": true` no longer lifts one. The
    /// field is still decoded and recorded (response and audit line) as what
    /// the caller claimed; approval comes from the owner — a ticket answered in
    /// the Clicky panel, or an approval rule that panel created. See
    /// `HarnessConfirmations` and `HarnessServer.gate`.
    static func executableWithoutAHuman(_ decision: SafetyDecision) -> Bool {
        if case .allow = decision { return true }
        return false
    }

    static func describe(_ decision: SafetyDecision) -> (decision: String, reason: String?) {
        switch decision {
        case .allow: return ("allow", nil)
        case .requireConfirmation(let reason, _): return ("requireConfirmation", reason)
        case .refuse(let reason): return ("refuse", reason)
        }
    }

    /// A title is caller/app text of any length; a 5,000-character one would be
    /// a 5 KB audit line. Same cap as `UntrustedText.forDisplay`, true length kept.
    /// Deliberately raw-but-capped here because JSON encoding is the escaping in the
    /// audit line; the panel uses `forDisplay` because the UI is not JSON.
    static func cappedAuditTarget(_ target: String) -> String {
        guard target.count > UntrustedText.maximumDisplayLength else { return target }
        return String(target.prefix(UntrustedText.maximumDisplayLength)) + "… (\(target.count) chars)"
    }

    static let auditTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// One request, one line, JSON — so the log is greppable and a title
    /// carrying a newline cannot forge a second record.
    ///
    /// `title` is app-facing text a caller supplied; JSON encoding escapes it,
    /// which is the same reason `UntrustedText.forDisplay` exists.
    /// `app` and `session` are the two fields that make an old log readable.
    /// Without `app` a line does not say which program it acted on; without
    /// `session` two runs of the harness interleave in one file and a stale
    /// binary's lines look like this one's.
    static func auditLine(
        at timestamp: Date,
        id: String,
        verb: String,
        target: String?,
        app: String?,
        session: String,
        dryRun: Bool,
        confirmed: Bool,
        kernel: String,
        outcome: String,
        milliseconds: Int,
        frontmostSource: String? = nil,
        frontmostSystemWideError: Int32? = nil,
        /// Who lifted a `requireConfirmation`: `caller` / `owner` / `approvalRule`.
        confirmedBy: String? = nil,
        /// `HarnessPhaseTiming.wireFields` — empty for a request that never acted.
        phases: [String: Any] = [:]
    ) -> String {
        var fields: [String: Any] = [
            "timestamp": auditTimestampFormatter.string(from: timestamp),
            "id": id,
            "verb": verb,
            "target": target.map(cappedAuditTarget) ?? NSNull(),
            "app": app ?? NSNull(),
            "session": session,
            "dryRun": dryRun,
            "confirmed": confirmed,
            "kernel": kernel,
            "outcome": outcome,
            "ms": milliseconds
        ]
        // Whether `app` was read live or off the frozen `NSWorkspace` cache —
        // the only way to count how often a request ran on the cache.
        if let frontmostSource { fields["frontmostSource"] = frontmostSource }
        if let frontmostSystemWideError { fields["frontmostSystemWideError"] = Int(frontmostSystemWideError) }
        if let confirmedBy { fields["confirmedBy"] = confirmedBy }
        fields.merge(phases) { existing, _ in existing }
        // `target` carries typed text: scrubbed like every other on-disk line.
        guard let data = try? JSONSerialization.data(withJSONObject: SecretScanner.scrub(fields), options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"timestamp\":\"\(auditTimestampFormatter.string(from: timestamp))\",\"outcome\":\"auditEncodingFailed\"}"
        }
        return text
    }
}

// MARK: - Observability
//
// The constraint here is that a healthy run costs one array append. Nothing
// polls, nothing times, nothing is written until something is actually wrong —
// because a diagnostic that runs all the time is a diagnostic nobody leaves on.

/// Last-N, and nothing else. Used for the request/response summaries and for
/// the walk durations the slow-walk rule needs a median of.
struct RingBuffer<Element> {
    let capacity: Int
    private(set) var elements: [Element] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }
}

/// Exactly three things are worth waking up for. Each is computed from data the
/// response already carries — no extra reads, no extra clock.
enum HarnessAnomaly: String, Equatable, CaseIterable {
    /// The kernel said the world would change, the write said `.success`, and
    /// the second walk saw nothing. This is the signature of every silent
    /// failure this project has measured.
    case notObservedAfterAllow = "verification notObserved after the kernel allowed"

    /// Any error that is not one of the ordinary refusals. Those are the
    /// harness working; anything else is the harness surprised.
    case unexpectedError = "response error is not an ordinary refusal"

    /// The kernel refused on a security ground — a secure field, or a label
    /// that is not a label. Something tried to do a thing it should not, which
    /// is the one refusal worth twenty requests of context.
    case securityRefusal = "the kernel refused on a security ground"

    /// The per-app policy file exists and cannot be parsed. Every mutating verb
    /// is refused until someone fixes it, so the first one gets the context.
    case policyUnreadable = "the harness policy file is unreadable or malformed"

    /// The walk took more than 3x the recent median. "It went sloppy" is
    /// usually this, and it is invisible in a single line.
    case walkFarSlowerThanRecentMedian = "walk took more than 3x the median of recent walks"
}

enum HarnessObservability {

    /// The refusals that mean the harness is doing its job. An error outside
    /// this set is the interesting kind.
    ///
    /// `invalidField` is here for the same reason `missingField` is: a caller
    /// typing `"mode":"overwrite"` is a bad request, not a sick machine.
    ///
    /// `kernelRefused` is deliberately NOT here. A hard refusal — a secure
    /// field, a non-text role — is rare and is exactly the moment you want the
    /// last twenty requests on disk, because something asked this machine to do
    /// a thing it will not do.
    static let ordinaryRefusalCodes: Set<String> = [
        "killSwitch", "confirmationRequired", "notFound", "ambiguous",
        // A caller re-asking before the owner answered, or after a no, is the
        // ticket flow working — measured 2026-09-14, each re-issue wrote a dump.
        // `confirmationTicketInvalid` stays OUT: a ticket re-aimed at another
        // action is exactly the moment worth twenty requests of context. So do
        // `tooManyPendingConfirmations` and `confirmationTooLongToShow` (review
        // 2026-09-14): a full queue is the signature of someone flooding the card
        // to get a click on the wrong row, and an over-long question is someone
        // probing what the card will draw. Neither happens to an honest planner.
        // `confirmationStale` stays OUT too (2026-09-14): it is the same re-aiming
        // as a mismatched ticket, done with the selection instead of the words —
        // an approval for one item spent while another is selected. The harness
        // itself can move it: `focus` brings another window of the same app forward
        // with no ticket, and a menu action follows the front window (review
        // 2026-09-15) — so the twenty requests before it show which one did.
        "confirmationPending", "confirmationDenied", "confirmationExpired",
        // Secure input on: the owner typing a password is not an anomaly.
        "handOver",
        "dryRun", "unknownVerb", "malformedJSON", "missingField", "invalidField",
        // A kernel refusal is the policy working, and the audit line already
        // says which rule fired. Only a refusal on SECURITY grounds is worth a
        // dump — see `kernelReason` below.
        "kernelRefused",
        // A scroll at the end of its content: an answer, not an anomaly.
        "atEnd",
        // An insert that would have typed over the owner's selection.
        "selectionNotEmpty",
        // The per-app policy refusing a capture is the file doing its job.
        "policyRefused",
        // An app with no ordinary on-screen window — measured 2026-09-11,
        // Finder showing only its desktop — is not listed by ScreenCaptureKit,
        // so the one-app capture refuses. Explained and safe; three dumps of it
        // in one session were a recorder filing the expected as a surprise.
        "applicationNotCapturable",
        // `LockScreenGuard` doing its job. Measured 2026-09-13: a probe left
        // running against a locked screen wrote 12,881 `anomalySuppressed`
        // audit lines naming this rule — one per refusal, each also a line of
        // its own. The first refusal is still in the audit log as `screenIsLocked`.
        "screenIsLocked",
        // `highlight` on a scrolled-out element: the reachability check working.
        "targetNotOnScreen"
        // `targetIsHarnessItself` stays OUT (2026-09-15). The honest way to meet it
        // is the owner's panel being key mid-run, rare and worth seeing; the other
        // way is a caller reaching for our own approval rules, the one moment the
        // twenty requests before it matter. Per-rule-per-app suppression caps a flood.
    ]

    /// Below this many samples the median is noise, and a cold start would fire
    /// the slow-walk rule on the first real walk of the day.
    static let minimumWalkSamples = 5
    static let slowWalkMultiplier = 3

    static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// nil when nothing is wrong. Checked in order of how much each one tells
    /// you: a silent failed write first, an unexpected error next, a slow walk
    /// last.
    static func anomaly(
        kernelDecision: String?,
        kernelReason: String? = nil,
        verificationStatus: String?,
        errorCode: String?,
        walkMilliseconds: Int?,
        recentWalkMilliseconds: [Int]
    ) -> HarnessAnomaly? {
        if verificationStatus == "notObserved", kernelDecision == "allow" {
            return .notObservedAfterAllow
        }
        if let kernelReason, ActionSafetyKernel.isSecurityRefusal(reason: kernelReason) {
            return .securityRefusal
        }
        if errorCode == "policyUnreadable" {
            return .policyUnreadable
        }
        if let errorCode, !ordinaryRefusalCodes.contains(errorCode) {
            return .unexpectedError
        }
        if let walkMilliseconds,
           recentWalkMilliseconds.count >= minimumWalkSamples,
           let median = median(of: recentWalkMilliseconds),
           median > 0,
           walkMilliseconds > median * slowWalkMultiplier {
            return .walkFarSlowerThanRecentMedian
        }
        return nil
    }
}

/// Where a mutating request's time went — resolve, act, verify — for the
/// response and the audit line.
///
/// Why (2026-09-15): 29,708 audit lines put 24% of all harness time in `menu`
/// confirmed (p50 648 / p95 1,700 ms), `launch` ready 1,045, `select` 554 — and
/// every line carried one `ms`, so none of it said whether the cost is finding
/// the target, the AX call, or the verifier's re-walks. Nothing gets optimised
/// until it does.
///
/// Monotonic (`DispatchTime`, uptime), not `Date`: a wall clock can step under
/// NTP mid-request, and a phase is a duration. Each phase truncates to whole ms,
/// so the three can only sum to less than `ms`, never more. A phase that did
/// not run is ABSENT, never 0 — a refusal has none, a `performFailed` has no
/// verify — or a median over the log would be a median of refusals.
struct HarnessPhaseTiming {
    typealias Nanoseconds = UInt64
    static func now() -> Nanoseconds { DispatchTime.now().uptimeNanoseconds }

    private let requestStartedAt: Nanoseconds
    /// The start of whichever phase is running; nil before the action starts and after verification.
    private var phaseStartedAt: Nanoseconds?
    private(set) var resolveMilliseconds: Int?
    private(set) var actMilliseconds: Int?
    private(set) var verifyMilliseconds: Int?
    private(set) var verifyWalks: Int?
    private(set) var verifyPath: String?

    init(requestStartedAt: Nanoseconds = HarnessPhaseTiming.now()) {
        self.requestStartedAt = requestStartedAt
    }

    static func milliseconds(from start: Nanoseconds, to end: Nanoseconds) -> Int {
        end > start ? Int((end - start) / 1_000_000) : 0
    }

    /// Everything until now was resolving: policy, frontmost, walk, kernel, ticket gate, baselines.
    mutating func actionStarting(at instant: Nanoseconds = HarnessPhaseTiming.now()) {
        resolveMilliseconds = Self.milliseconds(from: requestStartedAt, to: instant)
        phaseStartedAt = instant
    }

    mutating func actionReturned(at instant: Nanoseconds = HarnessPhaseTiming.now()) {
        guard let started = phaseStartedAt, actMilliseconds == nil else { return }
        actMilliseconds = Self.milliseconds(from: started, to: instant)
        phaseStartedAt = instant
    }

    mutating func verified(walks: Int, path: String?, at instant: Nanoseconds = HarnessPhaseTiming.now()) {
        guard let started = phaseStartedAt, actMilliseconds != nil else { return }
        verifyMilliseconds = Self.milliseconds(from: started, to: instant)
        verifyWalks = walks
        verifyPath = path
        phaseStartedAt = nil
    }

    /// For a helper that acts and then waits inside one call (`focus`, `launch`)
    /// and reports where its own boundary fell. Its figure is off its own `Date`
    /// clock, so it is clamped to the call — act + verify is exactly the call.
    mutating func actedThenVerified(actMilliseconds reported: Int, walks: Int, path: String?,
                                    at instant: Nanoseconds = HarnessPhaseTiming.now()) {
        guard let started = phaseStartedAt, actMilliseconds == nil else { return }
        let call = Self.milliseconds(from: started, to: instant)
        actMilliseconds = min(max(reported, 0), call)
        verifyMilliseconds = call - (actMilliseconds ?? 0)
        verifyWalks = walks
        verifyPath = path
        phaseStartedAt = nil
    }

    var wireFields: [String: Any] {
        var fields: [String: Any] = [:]
        if let resolveMilliseconds { fields["resolveMs"] = resolveMilliseconds }
        if let actMilliseconds { fields["actMs"] = actMilliseconds }
        if let verifyMilliseconds { fields["verifyMs"] = verifyMilliseconds }
        if let verifyWalks { fields["verifyWalks"] = verifyWalks }
        if let verifyPath { fields["verifyPath"] = verifyPath }
        return fields
    }
}

/// The per-day cap on the `~/Library/Logs/Clicky` audit mirror.
///
/// Measured 2026-09-13: one probe against a locked screen grew that day's
/// mirror to 11,499,814 bytes — 42,031 lines at ~273 bytes — while the main log
/// rotated at 5 MB as designed; nothing bounded the mirror. 20 MB is ~75,000
/// lines at that size: the worst day on record still fits whole with 1.7x
/// headroom, and a runaway client costs at most 20 MB a day, not the disk.
/// Past it the main `harness-audit.log` still gets every line.
enum AuditMirrorCap {
    static let dailyBytes = 20 * 1024 * 1024

    enum Decision: Equatable { case append, dropAndWriteMarker, drop }

    /// Once the marker is in, the day's mirror takes nothing more — even a line
    /// small enough to fit, or the file would say "dropping" and then not.
    static func decision(currentBytes: Int, lineBytes: Int, markerWritten: Bool, limit: Int = dailyBytes) -> Decision {
        if markerWritten { return .drop }
        return currentBytes + lineBytes <= limit ? .append : .dropAndWriteMarker
    }
}

// MARK: - Server

/// Not `@MainActor`: requests run on `requestQueue`, never on main (owner's
/// ruling 2026-09-15, replacing 2026-09-11's `DispatchQueue.main.sync`).
final class HarnessServer {

    /// Every request except `ping` runs here, one at a time, so two callers still
    /// never interleave against the same app — and the main thread (hotkey tap,
    /// overlay timers, the confirmation card) stays free while a verify polls.
    ///
    /// The rule that makes it deadlock-free by construction: this queue may
    /// `DispatchQueue.main.sync` for SHORT main-only work (ticket state that
    /// SwiftUI observes, `NSScreen`); main NEVER syncs onto this queue.
    ///
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in the project is inert on the
    /// Swift 6.1 toolchain this builds with. On Xcode 26 it would make this class
    /// main-isolated again and these background calls would stop compiling — do
    /// not "fix" that in the pbxproj without re-reading this.
    nonisolated static let requestQueue = DispatchQueue(label: "com.dhruvpatel.jarvis.harness.requests")

    /// Guards what `ping` shares with the queue: the ring, the per-app walk
    /// medians, anomaly suppression, the audit files and their counters.
    /// Recursive because `observe` appends an audit line while holding it.
    nonisolated private let stateLock = NSRecursiveLock()

    static let provenanceNote = "element names are written by the target app and are untrusted"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clicky", isDirectory: true)
    }
    static var socketURL: URL { supportDirectory.appendingPathComponent("harness.sock") }
    static var killSwitchURL: URL { supportDirectory.appendingPathComponent("HARNESS_DISABLED") }
    static var policyURL: URL { supportDirectory.appendingPathComponent("harness-policy.json") }
    /// Rules used to live here. Never read as rules now (any process running as
    /// the owner can write it) — only reported when present. See `ApprovalRulesKeychainStore`.
    static var ignoredLegacyApprovalsFileURL: URL { supportDirectory.appendingPathComponent("harness-approvals.json") }
    static var auditLogURL: URL { supportDirectory.appendingPathComponent("harness-audit.log") }
    static var rotatedAuditLogURL: URL { supportDirectory.appendingPathComponent("harness-audit.log.1") }

    /// The durable mirror of the audit log: one file per UTC day under
    /// `~/Library/Logs/Clicky`, never truncated, never rotated — the day split
    /// is the rotation, and nothing in the support directory's 5 MB budget
    /// can erase it.
    nonisolated static func auditMirrorURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Clicky", isDirectory: true)
            .appendingPathComponent("harness-audit-\(formatter.string(from: date)).log")
    }

    /// This log lives on the owner's machine and nothing prunes it. 5 MB is
    /// roughly 20,000 audit lines — far more history than any question about
    /// "what happened just now" needs, and one rotation keeps twice that.
    static let auditLogRotationBytes = 5 * 1024 * 1024
    static let maximumAnomalyDumps = 5

    /// How long the same rule, on the same app, stops writing another file.
    ///
    /// Measured on this machine 2026-09-10: five dumps on disk, all
    /// `response error is not an ordinary refusal`, all System Settings, all
    /// inside **1.7 seconds** — 125 KB describing one cause, and between them
    /// they filled the entire five-file budget, so any *different* anomaly in
    /// that session had nowhere to land. A recorder that evicts its own
    /// variety is worse than a smaller one. The recurrence is not lost: the
    /// audit line still fires every time, as `anomalySuppressed`.
    static let anomalyDumpSuppressionInSeconds: TimeInterval = 60

    /// One per app launch. Two runs of the harness append to the same file, and
    /// without this their lines are indistinguishable — including a stale
    /// binary's, which this project has already been fooled by once.
    static let sessionIdentifier = String(UUID().uuidString.prefix(8))

    /// Matches the listen backlog. Over it a client is told so and closed —
    /// a thread per connection with no cap is a thread per stuck client.
    nonisolated static let maximumConcurrentConnections = 8
    /// A client that connects and sends nothing holds a slot; this is how long.
    nonisolated static let clientReceiveTimeoutInSeconds: Int = 30
    nonisolated static let clientSendTimeoutInSeconds: Int = 2
    nonisolated private let connectionSlots = DispatchSemaphore(value: HarnessServer.maximumConcurrentConnections)

    private let globalDryRun: Bool
    /// The secure-input flag, read per request; a test injects its own.
    var secureInputRead: () -> SecureInputState = SecureInputState.current
    /// Shared with the menu-bar panel: tickets opened here are answered there.
    private let confirmations: HarnessConfirmations

    /// Who lifted a `requireConfirmation` for the request in flight, so every
    /// audit line of that request carries it. Reset per request, like `loadedPolicy`.
    private var currentConfirmedBy: String?
    /// The ticket this request already spent. `focus` asks the gate twice (app
    /// policy, then window); the second asking re-matches this ticket's shape
    /// rather than trusting that someone said yes to something.
    private var consumedTicketID: String?

    /// Mirror writes that failed. Not fatal to a request; counted so `ping` can say so.
    private(set) var auditMirrorFailures = 0
    /// Lines kept out of the day's mirror by `AuditMirrorCap`, marker line excluded.
    private(set) var auditMirrorOverflowLines = 0
    /// Mirror files that already carry this session's cap marker.
    /// ponytail: in memory, so a relaunch on a capped day writes one more marker; read the file's tail if that ever matters.
    private var auditMirrorFilesMarkedAsCapped: Set<String> = []
    /// Resolve / act / verify for the request in flight. Reset per request, like `currentConfirmedBy`.
    private var phaseTiming = HarnessPhaseTiming()

    /// The per-app policy read once by `execute` for the request in flight.
    /// Requests serialise on the main thread, so one slot is enough; nil means
    /// no file on disk.
    private var loadedPolicy: HarnessAppPolicy.Policy?
    private var listeningDescriptor: Int32 = -1

    /// The last 20 request/response summaries, **without** the `elements` array
    /// — that array is the large part of a snapshot and the part that says the
    /// least about a failure. Written out only when an anomaly trips, so the
    /// healthy path costs one array append.
    private var flightRecorder = RingBuffer<[String: Any]>(capacity: 20)

    /// Walk durations, **kept per app**.
    ///
    /// Measured 2026-09-10 with the first version of this, which kept one
    /// buffer: ten walks of TextEdit (5-12 ms) followed by one of System
    /// Settings (152 ms) fired the slow-walk rule and wrote a dump. Nothing was
    /// wrong — System Settings is 20x TextEdit's window and always has been.
    /// A cross-app median measures which app you switched to, and an anomaly
    /// rule that fires on an app switch is one that gets switched off.
    private var recentWalkMillisecondsByApp: [String: RingBuffer<Int>] = [:]

    /// Last time a dump was written, keyed by rule and app. Two entries, not a
    /// ring — the whole point is that repetition is cheap to recognise.
    private var lastAnomalyDumpAt: [String: Date] = [:]

    init(globalDryRun: Bool, confirmations: HarnessConfirmations) {
        self.globalDryRun = globalDryRun
        self.confirmations = confirmations
    }

    var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "clicky-harness/1 app \(short) (\(build))"
    }

    // MARK: Lifecycle

    func start() {
        let path = Self.socketURL.path
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)

        // A socket file outlives the process that made it. Left behind by a
        // crash it is a file bind() will refuse, so the stale one goes first.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            print("❌ harness: socket() failed, errno \(errno)")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            print("❌ harness: socket path too long for sockaddr_un: \(path)")
            close(descriptor)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("❌ harness: bind() failed, errno \(errno)")
            close(descriptor)
            return
        }

        // Filesystem permissions are the access control on this interface, so
        // this line is the whole security model. 0600: this user only.
        chmod(path, 0o600)

        guard listen(descriptor, 8) == 0 else {
            print("❌ harness: listen() failed, errno \(errno)")
            close(descriptor)
            return
        }

        listeningDescriptor = descriptor
        print("""

        ════════════════════════════════════════════════════════════════
        🔌 J.A.R.V.I.S. harness listening
           socket:      \(path)
           mode:        \(globalDryRun ? "DRY RUN (global --harness-dry-run)" : "live")
           kill switch: \(Self.killSwitchURL.path) \(Self.killSwitchIsPresent() ? "PRESENT — mutating verbs refused" : "(absent)")
           audit log:   \(Self.auditLogURL.path)
           try:         nc -U '\(path)'
        ════════════════════════════════════════════════════════════════

        """)

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(on: descriptor)
        }
    }

    nonisolated private func acceptLoop(on descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                print("❌ harness: accept() failed, errno \(errno)")
                return
            }
            // The refusal below is written on this thread; a client that never reads
            // it must not hold the accept loop.
            var sendTimeout = timeval(tv_sec: Self.clientSendTimeoutInSeconds, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            guard connectionSlots.wait(timeout: .now()) == .success else {
                _ = writeLine("{\"ok\":false,\"error\":\"tooManyConnections\",\"message\":\"\(Self.maximumConcurrentConnections) connections are already open\"}", to: client)
                close(client)
                continue
            }
            var receiveTimeout = timeval(tv_sec: Self.clientReceiveTimeoutInSeconds, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
            // A thread per connection, but the *work* is serialised onto the
            // main thread below, so two callers can never interleave against
            // the same app. This only stops a silent client from wedging
            // everyone else.
            // Strong: the server lives as long as the app. A weak capture that
            // found nil would leak the fd and the slot it just took.
            Thread.detachNewThread { self.serve(client) }
        }
    }

    /// The largest single request line accepted. Nothing legitimate comes close:
    /// the biggest verb carries a title, a role and a point.
    nonisolated static let maximumRequestBytes = 1 << 20

    /// Newline-delimited JSON, both directions. A client that disconnects
    /// mid-line loses its own connection and nothing else.
    nonisolated private func serve(_ client: Int32) {
        defer { close(client); connectionSlots.signal() }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let bytesRead = read(client, &buffer, buffer.count)
            if bytesRead == 0 { return }   // peer closed
            if bytesRead < 0 {
                // SO_RCVTIMEO fired. An idle client is fine — a ticket round trip
                // waits on a person, longer than 30 s; a stalled half-line is not.
                if errno == EAGAIN || errno == EWOULDBLOCK, pending.isEmpty { continue }
                return
            }
            pending.append(contentsOf: buffer[0..<bytesRead])

            // A client that never sends a newline would otherwise grow this
            // buffer until the process dies. Same-user access is not a security
            // boundary here — any process running as you can already act as you
            // — but a client stuck in a loop is an ordinary bug, and a harness
            // that can be killed by one is not a harness.
            guard pending.count <= Self.maximumRequestBytes else {
                _ = writeLine(
                    "{\"ok\":false,\"error\":\"requestTooLarge\",\"message\":\"a single request line may not exceed \(Self.maximumRequestBytes) bytes\"}",
                    to: client
                )
                // Still a request someone made of this machine: logged like `malformedJSON`,
                // but AFTER the reply, so the error never waits out another client's verify.
                // Order is no loss: a request in flight already writes its line after later pings.
                Self.requestQueue.async { self.auditUnparsed(outcome: "requestTooLarge", startedAt: Date()) }
                return
            }

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newlineIndex]
                pending = pending[(newlineIndex + 1)...]
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }

                let response = answer(line: line)
                guard writeLine(response, to: client) else { return }
            }
        }
    }

    nonisolated private func writeLine(_ text: String, to client: Int32) -> Bool {
        let payload = Array((text + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { bytes in
                write(client, bytes.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    // MARK: Request handling

    static func killSwitchIsPresent() -> Bool {
        FileManager.default.fileExists(atPath: killSwitchURL.path)
    }

    /// `ping` answers on the connection's own thread; everything else waits its
    /// turn on `requestQueue`. Measured 2026-09-11: a ping sat 2,949 ms behind
    /// another client's 3 s verify — a liveness probe that cannot tell "busy"
    /// from "hung". Ping acts on no app and reads no per-request state, so it
    /// has nothing to interleave with; its audit and ring writes take `stateLock`.
    /// Internal, not private, for `pingAnswersWhileTheRequestQueueIsBusy`.
    nonisolated func answer(line: String) -> String {
        if case .success(let request) = HarnessPolicy.decode(line: line), request.verb == .ping {
            let startedAt = Date()
            let dryRun = HarnessPolicy.effectiveDryRun(requested: request.requestedDryRun, globalDefault: globalDryRun)
            var response = pingResponse(request, dryRun: dryRun, startedAt: startedAt)
            response.merge(HarnessPhaseTiming().wireFields) { existing, _ in existing }
            response["id"] = request.id
            response["provenance"] = Self.provenanceNote
            return Self.encoded(observe(response, verb: request.verb.rawValue, startedAt: startedAt))
        }
        return Self.requestQueue.sync { respond(toLine: line) }
    }

    private func respond(toLine line: String) -> String {
        // A request on main freezes the hotkey and the overlay for its whole
        // verify; this traps the moment that comes back.
        dispatchPrecondition(condition: .onQueue(Self.requestQueue))
        // Names the verb in flight, for MainThreadStallRecorder.
        // "?" until decoded; cleared on the way out so a later stall is not blamed on this request.
        MainThreadStallRecorder.noteHarnessVerb("?")
        defer { MainThreadStallRecorder.noteHarnessVerb(nil) }
        let startedAt = Date()
        return Self.encoded(handle(line: line, startedAt: startedAt))
    }

    nonisolated private static func encoded(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"responseEncodingFailed\"}"
        }
        return text
    }

    private func handle(line: String, startedAt: Date) -> [String: Any] {
        switch HarnessPolicy.decode(line: line) {
        case .failure(let error):
            // A malformed line is still a request someone made of this machine,
            // so it is logged exactly like one that ran.
            auditUnparsed(outcome: error.code, startedAt: startedAt)
            return observe(
                ["ok": false, "id": "", "error": error.code, "message": error.message],
                verb: "?", startedAt: startedAt
            )

        case .success(let request):
            MainThreadStallRecorder.noteHarnessVerb(request.verb.rawValue)
            var response = execute(request, startedAt: startedAt)
            response.merge(phaseTiming.wireFields) { existing, _ in existing }
            response["id"] = request.id
            response["provenance"] = Self.provenanceNote
            return observe(response, verb: request.verb.rawValue, startedAt: startedAt)
        }
    }

    private func auditUnparsed(outcome: String, startedAt: Date) {
        appendAudit(HarnessPolicy.auditLine(
            at: startedAt, id: "", verb: "?", target: nil,
            app: Self.frontmostBundleIdentifier(), session: Self.sessionIdentifier,
            dryRun: globalDryRun, confirmed: false,
            kernel: "n/a", outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt)
        ), at: startedAt)
    }

    /// The whole observability slice, in one place on the way out.
    ///
    /// Every input is already in the response — no second walk, no extra clock,
    /// no state kept beyond two ring buffers.
    private func observe(
        _ response: [String: Any],
        verb: String,
        startedAt: Date
    ) -> [String: Any] {
        var summary = Self.summaryForRing(response)
        summary["_verb"] = verb
        summary["_at"] = HarnessPolicy.auditTimestampFormatter.string(from: startedAt)

        let walkMilliseconds = response["walkMilliseconds"] as? Int
        let walkedApp = (response["bundleIdentifier"] as? String) ?? "unknown"

        // `stateLock` covers the ring and the dictionaries, never a cross-process
        // read or the dump write: `ping` takes it too, and must not wait on an app.
        let (anomaly, recentWalkElements): (HarnessAnomaly?, [Int]) = stateLock.withLock {
            var recentWalks = recentWalkMillisecondsByApp[walkedApp] ?? RingBuffer<Int>(capacity: 20)
            let anomaly = HarnessObservability.anomaly(
                kernelDecision: (response["kernel"] as? [String: Any])?["decision"] as? String,
                kernelReason: (response["kernel"] as? [String: Any])?["reason"] as? String,
                verificationStatus: (response["verification"] as? [String: Any])?["status"] as? String,
                errorCode: response["error"] as? String,
                walkMilliseconds: walkMilliseconds,
                recentWalkMilliseconds: recentWalks.elements
            )
            flightRecorder.append(summary)
            // Appended *after* the check, so a walk is never compared against itself.
            if let walkMilliseconds {
                recentWalks.append(walkMilliseconds)
                recentWalkMillisecondsByApp[walkedApp] = recentWalks
            }
            return (anomaly, recentWalks.elements)
        }

        guard let anomaly else { return response }

        // Same rule, same app, within the window: record that it happened and
        // do not spend 25 KB saying it again. The ring buffer behind a second
        // dump is nearly the same twenty requests anyway.
        // Read once, outside the lock; the dump and the audit line reuse it.
        let frontmostApp = Self.frontmostBundleIdentifier()
        let dumpKey = "\(anomaly.rawValue)|\(frontmostApp ?? "unknown")"
        let now = Date()
        let (suppressed, ringRequests) = stateLock.withLock {
            (lastAnomalyDumpAt[dumpKey].map { now.timeIntervalSince($0) < Self.anomalyDumpSuppressionInSeconds } ?? false,
             flightRecorder.elements)
        }

        var annotated = response
        var outcome = "anomalyNotWritten"
        if suppressed {
            outcome = "anomalySuppressed"
            annotated["anomaly"] = [
                "rule": anomaly.rawValue,
                "dump": NSNull(),
                "suppressed": "same rule and app dumped within the last \(Int(Self.anomalyDumpSuppressionInSeconds))s"
            ]
        } else if let dumpPath = writeAnomalyDump(
            anomaly, app: frontmostApp, walkedApp: walkedApp, recentWalks: recentWalkElements, requests: ringRequests
        ) {
            stateLock.withLock { lastAnomalyDumpAt[dumpKey] = now }
            outcome = "anomaly"
            annotated["anomaly"] = ["rule": anomaly.rawValue, "dump": dumpPath]
        }

        // One audit line naming the rule, on every anomaly including a
        // suppressed one — otherwise the log would say a recurring problem
        // stopped happening the moment we stopped writing files about it.
        appendAudit(HarnessPolicy.auditLine(
            at: now, id: (response["id"] as? String) ?? "", verb: verb,
            target: anomaly.rawValue,
            app: frontmostApp, session: Self.sessionIdentifier,
            dryRun: globalDryRun, confirmed: false,
            kernel: "n/a", outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt)
        ), at: now)
        return annotated
    }

    /// The per-response arrays are most of a response's bytes and none of its
    /// diagnostic value; their counts stay.
    nonisolated static let ringStrippedArrays = ["elements", "items", "windows", "applications", "candidates", "processesFailed"]

    nonisolated static func summaryForRing(_ response: [String: Any]) -> [String: Any] {
        var summary = response
        for key in ringStrippedArrays {
            guard let array = response[key] as? [Any] else { continue }
            summary[key] = nil
            let countKey = key.hasSuffix("s") ? String(key.dropLast()) + "Count" : key + "Count"
            if summary[countKey] == nil { summary[countKey] = array.count }
        }
        return summary
    }

    /// What reaches disk for an anomaly: the ring, scrubbed (`SecretScanner.scrub`)
    /// - a request's target is typed text.
    nonisolated static func anomalyDumpData(_ payload: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: SecretScanner.scrub(payload), options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes the ring buffer out, keeping at most five files. Returns the path
    /// so the response and the audit line can name it.
    private func writeAnomalyDump(
        _ anomaly: HarnessAnomaly,
        app: String?,
        walkedApp: String,
        recentWalks: [Int],
        requests: [[String: Any]]
    ) -> String? {
        let timestamp = HarnessPolicy.auditTimestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.supportDirectory
            .appendingPathComponent("harness-anomaly-\(timestamp).json")

        let payload: [String: Any] = [
            "rule": anomaly.rawValue,
            "session": Self.sessionIdentifier,
            "app": app.map { $0 as Any } ?? NSNull(),
            // The samples the slow-walk rule was comparing against, and which
            // app they belong to — a median is meaningless without both.
            "walkedApp": walkedApp,
            "recentWalkMilliseconds": recentWalks,
            "requests": requests
        ]
        guard let data = Self.anomalyDumpData(payload) else { return nil }

        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        // A new file each time, so an owner-only append is an owner-only create.
        guard Self.append(data, to: url) else { return nil }
        pruneAnomalyDumps()
        return url.path
    }

    private func pruneAnomalyDumps() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.supportDirectory, includingPropertiesForKeys: nil
        )) ?? []
        // Named by ISO timestamp, so lexicographic order is chronological.
        let dumps = contents
            .filter { $0.lastPathComponent.hasPrefix("harness-anomaly-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard dumps.count > Self.maximumAnomalyDumps else { return }
        for stale in dumps.prefix(dumps.count - Self.maximumAnomalyDumps) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Which app a line refers to. Clicky is `LSUIElement`, so it never takes
    /// focus itself — the frontmost app is the one being acted on.
    /// For audit lines and guards only: a guard and what it guards read ONE
    /// answer, so a verb about to walk or capture an app carries that app, never this.
    static func frontmostBundleIdentifier() -> String? {
        AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier
    }

    /// Clicky's own process, by bundle identifier. Every call site already holds
    /// the target's identifier, and the window-list and look fallbacks hold no pid.
    nonisolated static func isHarnessItself(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, let own = Bundle.main.bundleIdentifier else { return false }
        return bundleIdentifier.caseInsensitiveCompare(own) == .orderedSame
    }

    nonisolated static let harnessItselfMessage =
        "the target is Clicky itself — the harness never reads or acts on its own UI (approval rules, quit, toggles)"

    /// The refusal for a request aimed at Clicky itself, or whose `expectApp` is
    /// not the app it just read, already audited — or nil when the verb may go on.
    ///
    /// Self first (review 2026-09-15). While requests ran inside `main.sync`, an
    /// AX call into our own process timed out, because the thread that answers it
    /// was the one waiting. Off main it is answered — and while the menu-bar panel
    /// is key the focused app IS Clicky, so a caller could press "Remove" on an
    /// Always rule or the quit control. Allow stays guarded by its pid-0 check.
    ///
    /// Called with the app the verb is ABOUT TO USE (the snapshot's, the menu
    /// bar's), never a separate lookup: a guard that reads a different answer
    /// from the thing it guards can pass against one app while acting in another.
    /// Without `expectApp` this returns nil and the request runs byte-for-byte
    /// as it did before the field existed.
    ///
    /// `frontmostChanged` is deliberately not an ordinary refusal: focus moving
    /// under a planner trips the flight recorder's `unexpectedError` rule, and
    /// the per-rule-per-app suppression keeps a flood to one file a minute.
    private func frontmostChangedRefusal(
        _ request: HarnessRequest,
        name: String?,
        bundleIdentifier: String?,
        dryRun: Bool,
        startedAt: Date
    ) -> [String: Any]? {
        if Self.isHarnessItself(bundleIdentifier: bundleIdentifier) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "targetIsHarnessItself", startedAt: startedAt)
            return ["ok": false, "error": "targetIsHarnessItself", "message": Self.harnessItselfMessage]
        }
        guard let expected = request.expectApp,
              !HarnessPolicy.appMatches(expected: expected, bundleIdentifier: bundleIdentifier, name: name)
        else { return nil }
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "frontmostChanged", startedAt: startedAt)
        return [
            "ok": false,
            "error": "frontmostChanged",
            "expectedApp": expected,
            "actualApp": [
                "name": name.map { $0 as Any } ?? NSNull(),
                "bundleIdentifier": bundleIdentifier.map { $0 as Any } ?? NSNull()
            ],
            "message": "focus is not on the expected application \(UntrustedText(expected).forDisplay) — "
                + "\(UntrustedText(name ?? bundleIdentifier ?? "unknown").forDisplay) is frontmost, "
                + "so nothing was resolved or performed"
        ]
    }

    private func execute(_ request: HarnessRequest, startedAt: Date) -> [String: Any] {
        phaseTiming = HarnessPhaseTiming()
        let dryRun = HarnessPolicy.effectiveDryRun(
            requested: request.requestedDryRun,
            globalDefault: globalDryRun
        )

        if let handOverReason = HarnessPolicy.handOverRefusal(verb: request.verb, secureInput: secureInputRead()) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "handOver", startedAt: startedAt)
            return ["ok": false, "error": "handOver", "message": handOverReason]
        }

        if let killSwitchReason = HarnessPolicy.killSwitchRefusal(
            verb: request.verb,
            killSwitchPresent: Self.killSwitchIsPresent()
        ) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "killSwitch", startedAt: startedAt)
            return ["ok": false, "error": "killSwitch", "message": killSwitchReason]
        }

        // Read once per request, before a target is even read, and fail closed:
        // a policy file that cannot be parsed must never become "allow".
        loadedPolicy = nil
        currentConfirmedBy = nil
        consumedTicketID = nil
        // `look` is read-only but takes a photograph, and a policy `refuse` is
        // "do not touch this app" — a picture of it counts.
        // A voice read hands names to a remote model, so it asks the policy too.
        // A pointer sent to a bare position photographs the words there to aim (`ocrWord`).
        if request.verb.isMutating || request.verb == .look || request.forModel || request.aimAtPoint {
            switch HarnessAppPolicy.load(from: Self.policyURL) {
            case .loaded(let policy, _): loadedPolicy = policy
            case .missing: break
            case .unreadable(let reason):
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "policyUnreadable", startedAt: startedAt)
                return ["ok": false, "error": "policyUnreadable",
                        "message": "harness policy file is unreadable or malformed — \(reason)"]
            }
        }

        switch request.verb {
        case .ping:
            return pingResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .snapshot:
            return snapshotResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .press, .select, .type, .open, .click:
            return actResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .openURL:
            return openURLResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .menu:
            return request.statusItem != nil
                ? statusItemPressResponse(request, dryRun: dryRun, startedAt: startedAt)
                : menuResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .status:
            return statusResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .menus:
            return menusResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .windows:
            return windowsResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .focus:
            return focusResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .look:
            return lookResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .launch:
            return launchResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .highlight:
            return highlightResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .scroll:
            return scrollResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .visionClick:
            return visionClickResponse(request, dryRun: dryRun, startedAt: startedAt)
        }
    }

    // MARK: snapshot

    private func snapshotResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        // A voice read of a refused app is refused before one of its elements is
        // read (review 2026-09-30), and again below against the app actually walked.
        if request.forModel, let reason = HarnessPolicy.modelReadRefusal(
            forModel: true, bundleIdentifier: AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier, policy: loadedPolicy
        ) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "policyRefused", startedAt: startedAt)
            return ["ok": false, "error": "policyRefused", "message": reason]
        }
        var snapshot: AccessibilityWindowSnapshot
        do {
            snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
        } catch {
            let code = Self.errorCode(for: error)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            return ["ok": false, "error": code, "message": String(describing: error)]
        }

        if let refusal = frontmostChangedRefusal(
            request, name: snapshot.applicationName, bundleIdentifier: snapshot.bundleIdentifier,
            dryRun: dryRun, startedAt: startedAt
        ) { return refusal }

        if let reason = HarnessPolicy.modelReadRefusal(forModel: request.forModel, bundleIdentifier: snapshot.bundleIdentifier,
                                                       policy: loadedPolicy) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "policyRefused", startedAt: startedAt)
            return ["ok": false, "error": "policyRefused", "message": reason]
        }
        // After the policy and expectApp checks, never on Clicky, never on an app the policy refuses:
        // a thin app's first sight (`FirstSightWake`) writes to the app.
        if HarnessAppPolicy.verdict(for: snapshot.bundleIdentifier, in: loadedPolicy).0 != .refuse {
            snapshot = FirstSightWake.wakeIfThin(snapshot)
        }

        guard let rootNode = snapshot.rootNode else {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noRootNode", startedAt: startedAt)
            return ["ok": false, "error": "noRootNode", "message": "the walk produced no root element"]
        }

        let actionable = Self.actionableElements(in: rootNode)
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)

        return [
            "ok": true,
            "application": snapshot.applicationName,
            "bundleIdentifier": snapshot.bundleIdentifier,
            "nodeCount": snapshot.nodeCount,
            "walkMilliseconds": Int(snapshot.walkDurationInSeconds * 1000),
            // Truncation is never hidden. An empty list is the only "these are
            // complete" this interface will ever say.
            "walkStopReasons": snapshot.walkStopReasons.map(\.rawValue).sorted(),
            "focusChangedDuringWalk": snapshot.focusChangedDuringWalk,
            "frontmostSource": snapshot.frontmostSource?.rawValue ?? NSNull(),
            // Nodes with no batched read carry no `selected` / `valueLength`: say so.
            "nodesReadWithoutBatch": snapshot.nodesReadWithoutBatch,
            "actionableCount": actionable.count,
            // The window itself (AppKit): what `highlight` checks reachability
            // against, so a caller offering elements can check the same.
            "windowFrame": Self.frameJSON(rootNode.frameInAppKitCoordinates).frame,
            // forModel: every NAMED element, any role, with its nearest listed
            // ancestor — the voice loop offers what is visible, and a label
            // inside a button is that button (`RealtimeScreenVerbs.visiblePool`).
            "elements": request.forModel ? Self.namedElements(in: rootNode) : actionable.map(Self.summarise),
            "thinTree": snapshot.nodeCount < FirstSightWake.thinTreeNodes,
            "firstSightWake": snapshot.firstSightWake.map { ["nodesBefore": $0.nodesBefore, "nodesAfter": $0.nodesAfter,
                                                             "milliseconds": $0.milliseconds,
                                                             "manualAccessibilityAXError": Int($0.manualAccessibilityError)] } ?? NSNull()
        ]
    }

    /// The plain snapshot's `elements` and `actionableCount`: actionable nodes,
    /// never inside a text input or a secure field (`wireDescendants`).
    static func actionableElements(in rootNode: AccessibilityElementNode) -> [AccessibilityElementNode] {
        rootNode.wireDescendants().filter(\.isActionable)
    }

    /// Pre-order, every node with a name and a non-zero frame that can be SEEN:
    /// `summarise` plus `nameSource` (a text field's AXValue is what the owner
    /// typed), `parent` (index of the nearest listed ancestor) and
    /// `subroleReadFailed`. Review 2026-09-30:
    ///  - seen means inside every AXScrollArea / AXWebArea it scrolls in, not
    ///    just the window: rows scrolled under a toolbar, and the visible-subset
    ///    walk's one-screen margin, are in the tree and not on screen;
    ///  - nothing INSIDE a text input or a secure field is listed: Chromium
    ///    publishes a contenteditable's draft (Cursor's chat box) as child
    ///    AXStaticText, and that is typed text, not a label.
    /// A withheld element (`AccessibilityElementNode.withholdsName`) is listed
    /// with a null name, so a consumer can count it hidden.
    /// `clippedToView` false: off-screen ones too (a scroll's before-picture).
    static func namedElements(in rootNode: AccessibilityElementNode, clippedToView: Bool = true) -> [[String: Any]] {
        var listed: [[String: Any]] = []
        func visit(_ node: AccessibilityElementNode, parent: Int?, clip: CGRect) {
            let frame = node.frameInAppKitCoordinates
            var next = parent
            let isTextInput = RealtimeScreenVerbs.textInputRoles.contains(node.role)
            // A password box is listed even empty and anonymous (name null), so the
            // pointer's `structuralHit` can see it and refuse rather than land on its container.
            if node.displayName != nil || (isTextInput && node.fieldLabel != nil) || node.mightBeSecure,
               frame.width > 0, frame.height > 0,
               !clippedToView || !frame.intersection(clip).isEmpty {
                var entry = summarise(node)
                entry["nameSource"] = node.title != nil ? "title" : node.elementDescription != nil ? "description"
                    : isTextInput && node.placeholder != nil ? "placeholder" : "value"
                entry["parent"] = parent ?? NSNull()
                entry["subroleReadFailed"] = node.subroleReadFailed
                // Done-conditions ("Posts tab selected", "draft present"): a boolean
                // and a COUNT, never the text; absent when not read, never false / 0.
                if let selected = node.selected { entry["selected"] = selected }
                if let valueLength = node.valueLength, !node.mightBeSecure { entry["valueLength"] = valueLength }
                listed.append(entry)
                next = listed.count - 1
            }
            if node.hidesChildrenFromWire { return }
            let scrolls = (node.role == "AXScrollArea" || node.role == "AXWebArea") && frame.width > 0 && frame.height > 0
            let childClip = scrolls ? clip.intersection(frame) : clip
            for child in node.children { visit(child, parent: next, clip: childClip) }
        }
        visit(rootNode, parent: nil, clip: rootNode.frameInAppKitCoordinates)
        return listed
    }

    /// `verification.appeared`: names new since `namesBefore` (the full
    /// fingerprint — change detection must see everything) that this listing
    /// would also send. Post-action evidence passes the same predicate as every
    /// other answer: a draft typed into a label-less field, a contenteditable's
    /// child AXStaticText, a password box revealed by a press are not names.
    /// ponytail: a draft under a contenteditable Chromium publishes as AXGroup /
    /// AXWebArea rather than a text input is still listed — no structural tell.
    static func appearedNames(in laterRoot: AccessibilityElementNode, since namesBefore: Set<String>) -> [String] {
        let listed = Set(namedElements(in: laterRoot).compactMap { ($0["name"] as? String).map { UntrustedText($0).forDisplay } })
        return Array(AccessibilityDumpRunner.namedElementFingerprint(in: laterRoot)
            .subtracting(namesBefore).intersection(listed).sorted().prefix(12))
    }

    /// The wire form of an element — every socket answer that names an element
    /// routes through here, so the name is `listedName`: never a field's
    /// contents, never a password box's bullets. `name` is raw because JSON
    /// encoding is the escaping — but `nameIsPlausibleLabel` travels beside it
    /// so the caller knows whether the app published a label or a document.
    static func summarise(_ node: AccessibilityElementNode) -> [String: Any] {
        let name = node.listedName
        var entry: [String: Any] = [
            "role": node.role,
            "subrole": node.subrole ?? NSNull(),
            "name": name?.raw ?? NSNull(),
            "nameIsPlausibleLabel": name?.isPlausibleControlLabel ?? false,
            "actions": node.publishedActionNames
        ]
        Self.attachFrame(node.frameInAppKitCoordinates, to: &entry)
        return entry
    }

    /// An app-supplied frame can carry NaN or infinity, and `JSONSerialization`
    /// throws on either — the whole response would then encode as
    /// `responseEncodingFailed`. Non-finite components become null and the
    /// entry is flagged, so the caller sees the bad frame instead of nothing.
    nonisolated static func frameJSON(_ rect: CGRect) -> (frame: [String: Any], invalid: Bool) {
        let components: [(String, CGFloat)] = [
            ("x", rect.origin.x), ("y", rect.origin.y), ("w", rect.size.width), ("h", rect.size.height)
        ]
        var frame: [String: Any] = [:]
        var invalid = false
        for (key, value) in components {
            if value.isFinite { frame[key] = value } else { frame[key] = NSNull(); invalid = true }
        }
        return (frame, invalid)
    }

    nonisolated static func pointJSON(_ point: CGPoint) -> (point: [String: Any], invalid: Bool) {
        let (frame, invalid) = frameJSON(CGRect(origin: point, size: CGSize(width: 1, height: 1)))
        return (["x": frame["x"]!, "y": frame["y"]!], invalid)
    }

    nonisolated static func attachFrame(_ rect: CGRect, to entry: inout [String: Any], key: String = "frame") {
        let (frame, invalid) = frameJSON(rect)
        entry[key] = frame
        if invalid { entry["frameInvalid"] = true }
    }

    // MARK: press / select

    /// The per-app layer, composed over the kernel's decision, from the policy
    /// `execute` already loaded for this request.
    private func applyAppPolicy(
        to kernel: SafetyDecision, bundleIdentifier: String?, into response: inout [String: Any]
    ) -> SafetyDecision {
        let (verdict, source) = HarnessAppPolicy.verdict(for: bundleIdentifier, in: loadedPolicy)
        response["policy"] = policyBlock(verdict: verdict, source: source, bundleIdentifier: bundleIdentifier)
        return HarnessAppPolicy.compose(policy: verdict, bundleIdentifier: bundleIdentifier, kernel: kernel)
    }

    private func policyBlock(verdict: HarnessAppPolicy.Verdict, source: String, bundleIdentifier: String?) -> [String: Any] {
        ["verdict": verdict.rawValue, "source": source, "app": (bundleIdentifier ?? NSNull()) as Any]
    }

    // MARK: Confirmation gate

    struct GateResult {
        let executable: Bool
        /// The kernel's word: allow / requireConfirmation / refuse.
        let decision: String
        /// The refusal code when not executable; `allowed` otherwise.
        let outcome: String
        let note: String?
    }

    /// The one place a kernel decision meets the caller's credentials.
    ///
    /// `.requireConfirmation` is a question for a human, and no human sits on
    /// the socket. A request cannot wait for a click either — it holds
    /// `requestQueue`, and every other caller with it. So
    /// the question becomes a ticket the owner answers in the panel, and the
    /// caller re-issues carrying its id. `"confirmed": true` lifts nothing
    /// (owner's ruling 2026-09-12); it is recorded, not believed.
    private func gate(
        _ decision: SafetyDecision,
        request: HarnessRequest,
        appName: String?,
        bundleIdentifier: String?,
        dryRun: Bool,
        bindingSubject: ActionBinding.Subject? = nil,
        into response: inout [String: Any]
    ) -> GateResult {
        let described = HarnessPolicy.describe(decision)
        let result: GateResult

        switch decision {
        case .allow:
            result = GateResult(executable: true, decision: described.decision, outcome: "allowed", note: nil)

        case .refuse(let reason):
            result = GateResult(executable: false, decision: described.decision,
                                outcome: "kernelRefused", note: "refused: \(reason)")

        case .requireConfirmation(let reason, let destructive):
            let shape = Self.confirmationShape(for: request, bundleIdentifier: bundleIdentifier)
            var confirmedBy: String?
            var confirmation: [String: Any] = [:]
            var refusal: (outcome: String, note: String)?

            if let id = request.ticket {
                // The words matched; now the thing. Checked while the ticket is
                // pending OR allowed, so a stale ticket never becomes spendable —
                // and even on a dry run, because a dry run that reported "allowed"
                // for a moved selection would be the one wrong answer here.
                //
                // Ticket state lives on main (SwiftUI and the card observe it), so
                // each read or write of it hops there; the binding's AX reads stay
                // here. Nothing the owner can do between hops helps a stale ticket:
                // stale is terminal, and the spend below is one check-and-set.
                let (peek, approvedBinding) = DispatchQueue.main.sync {
                    (confirmations.consume(ticket: id, shape, spend: false), confirmations.ticket(id: id)?.binding)
                }
                if let bindingSubject, let approved = approvedBinding,
                   peek == .pending || peek == .allowed {
                    let recheck = ActionBinding.recheck(approved, subject: bindingSubject, bundleIdentifier: bundleIdentifier)
                    if let moved = recheck.movedPart {
                        DispatchQueue.main.sync { confirmations.invalidateAsStale(ticket: id, movedPart: moved) }
                    }
                    response["binding"] = ActionBinding.responsePayload(recheck.current, bundleIdentifier: bundleIdentifier,
                                                                        stalePart: recheck.movedPart)
                }
                // A dry run reports what the gate WOULD decide and leaves the
                // ticket unspent — the caller still has its one action.
                switch DispatchQueue.main.sync(execute: { confirmations.consume(ticket: id, shape, spend: !dryRun) }) {
                case .allowed:
                    confirmedBy = "owner"
                    confirmation["ticket"] = id
                    if dryRun { confirmation["dryRun"] = true } else { consumedTicketID = id }
                case .consumed where id == consumedTicketID:
                    // Spent earlier in THIS request, and `consumption` checked the
                    // shape before the flag — so it matched this question too.
                    confirmedBy = "owner"
                    confirmation["ticket"] = id
                case .pending:
                    refusal = ("confirmationPending", "ticket \(id) has not been answered in the Clicky panel yet")
                case .denied:
                    refusal = ("confirmationDenied", "ticket \(id) was denied in the Clicky panel")
                case .expired:
                    refusal = ("confirmationExpired",
                               "ticket \(id) expired after \(Int(HarnessConfirmations.ticketLifetimeInSeconds)) s — re-issue without it to open a new one")
                case .consumed:
                    refusal = ("confirmationTicketInvalid", "ticket \(id) was already spent — one ticket, one action")
                case .unknown:
                    refusal = ("confirmationTicketInvalid", "no ticket \(id) is known to this harness session")
                case .mismatch(let field):
                    refusal = ("confirmationTicketInvalid", "ticket \(id) was issued for a different \(field)")
                case .stale(let field):
                    refusal = ("confirmationStale",
                               "ticket \(id) is stale: the \(field) it was approved for has changed — re-issue without it to ask again")
                }
            } else {
                let consulted = confirmations.rule(for: shape, destructive: destructive)
                var approvalsReport: [String: Any] = [:]
                if let unreadable = consulted.unreadable { approvalsReport["unreadable"] = unreadable }
                // A planted rules file is an attack or a leftover; either way the
                // caller sees that it exists and was not honoured.
                if let ignoredFile = consulted.ignoredFile { approvalsReport["ignoredFile"] = ignoredFile }
                if !approvalsReport.isEmpty { response["approvals"] = approvalsReport }
                if let rule = consulted.rule {
                    confirmedBy = "approvalRule"
                    confirmation["rule"] = [
                        "bundleIdentifier": rule.bundleIdentifier, "verb": rule.verb,
                        "target": (rule.target ?? NSNull()) as Any,
                        "text": (rule.text ?? NSNull()) as Any,
                        "mode": (rule.mode ?? NSNull()) as Any,
                        "withinNamed": (rule.withinNamed ?? NSNull()) as Any,
                        "nearPoint": (rule.nearPoint.map { [$0.x, $0.y] } ?? NSNull()) as Any,
                        "role": (rule.role ?? NSNull()) as Any,
                        "thenConfirm": rule.thenConfirm ?? false
                    ]
                } else {
                    let binding = bindingSubject.map { ActionBinding.capture($0, bundleIdentifier: bundleIdentifier) }
                    if let binding {
                        response["binding"] = ActionBinding.responsePayload(binding, bundleIdentifier: bundleIdentifier)
                    }
                    switch DispatchQueue.main.sync(execute: {
                        confirmations.open(shape, appName: appName, reason: reason, destructive: destructive, binding: binding)
                    }) {
                    case .opened(let ticket):
                        response["ticket"] = ticket.id
                        response["expiresAt"] = HarnessPolicy.auditTimestampFormatter.string(from: ticket.expiresAt)
                        response["message"] = "re-issue this request with \"ticket\": \"\(ticket.id)\" once approved in the Clicky panel"
                        refusal = ("confirmationRequired",
                                   "requires confirmation: \(reason) — ticket \(ticket.id) is waiting in the Clicky panel")
                    case .refused(let code, let message):
                        response["message"] = message
                        refusal = (code, "requires confirmation: \(reason) — no ticket opened: \(message)")
                    }
                }
            }

            if let refusal {
                result = GateResult(executable: false, decision: described.decision,
                                    outcome: refusal.outcome, note: refusal.note)
            } else {
                let by = confirmedBy ?? "owner"
                currentConfirmedBy = by
                confirmation["by"] = by
                response["confirmation"] = confirmation
                result = GateResult(executable: true, decision: described.decision,
                                    outcome: "allowed", note: "confirmed by \(by): \(reason)")
            }
        }

        response["kernel"] = [
            "decision": result.decision,
            "reason": (described.reason ?? NSNull()) as Any,
            "executable": result.executable,
            "note": (result.note ?? NSNull()) as Any
        ]
        return result
    }

    /// The request shape a ticket or rule is matched against: raw strings, so
    /// two titles that `forDisplay` would truncate alike stay distinct.
    nonisolated static func confirmationShape(for request: HarnessRequest, bundleIdentifier: String?) -> HarnessConfirmations.Shape {
        HarnessConfirmations.Shape(
            verb: request.verb.rawValue,
            bundleIdentifier: bundleIdentifier,
            rawTarget: auditTarget(for: request) ?? "",
            text: request.verb == .type ? request.text : nil,
            mode: request.verb == .type ? request.mode.rawValue : nil,
            withinNamed: request.withinNamed,
            nearPoint: request.nearPoint,
            role: request.role,
            thenConfirm: request.thenConfirm
        )
    }

    /// What a request acted on, for the audit line and the ticket. Title, else
    /// the menu path, else the status item, else the focused element, else the
    /// app — a mutating verb whose record does not say what it acted on is
    /// half a record, and a ticket for it would authorise anything.
    nonisolated static func auditTarget(for request: HarnessRequest) -> String? {
        // A page's query and fragment can carry a search, a token or an address (review of H1).
        if request.verb == .openURL, let url = request.url { return HarnessHands.auditableURL(url) }
        if !request.title.isEmpty { return request.title }
        if !request.path.isEmpty { return request.path.joined(separator: " > ") }
        if let statusItem = request.statusItem, !statusItem.isEmpty { return statusItem }
        if request.aimAtFocus { return "<focused>" }
        if request.aimAtWindow { return "<window>" }
        if request.verb == .visionClick { return "<the owner's pointer>" }
        return request.app
    }

    // MARK: highlight

    /// Outline the element a press with the same fields would resolve, for
    /// `seconds`, and change nothing else.
    ///
    /// Why no per-app policy, ticket or kill switch: it sends the target app no
    /// action and no write — the only window it touches is Clicky's own
    /// click-through overlay, which can never become key or main — so it is the
    /// class of `snapshot`, not of `press`. It still writes its audit line.
    private func highlightResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = ["dryRun": dryRun]
        if request.aimAtPoint, let point = request.nearPoint {
            return approximateRingResponse(request, at: point, dryRun: dryRun, startedAt: startedAt, into: &response)
        }
        // `.press` only fills the intent's slot: the resolver matches on name, role,
        // container and point and never reads the action.
        guard let target = resolveTarget(request, action: .press, dryRun: dryRun, startedAt: startedAt, into: &response)
        else { return response }
        response["resolved"] = Self.summarise(target.node)

        func refuse(_ code: String, _ message: String) -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            return response
        }

        // Press's check, on press's input (the walk's frame), and BEFORE the live
        // read: measured 2026-09-15, scrolled-out System Settings rows fail a live
        // AXPosition/AXSize read outright, so reading first turned 7 off-screen rows
        // into `frameUnreadable` instead of `targetNotOnScreen`.
        if let reason = ActionSafetyKernel.unreachableFrameReason(
            target.node.frameInAppKitCoordinates, visibleBounds: target.rootNode.frameInAppKitCoordinates
        ) {
            return refuse("targetNotOnScreen", reason)
        }
        // The frame straight from AX, not the walk's AppKit copy converted back:
        // a value run back through the conversion that produced it can only agree
        // with itself, and then a mirrored outline would report a perfect round trip.
        guard let element = target.node.accessibilityElement,
              let elementFrame = AccessibilityTreeWalker.copyFrame(from: element).frame else {
            return refuse("frameUnreadable", "the element's AXPosition/AXSize could not be read")
        }
        let drawnRect = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
            elementFrame, primaryDisplayHeightInPoints: CGDisplayBounds(CGMainDisplayID()).height
        )
        guard let screenIndex = CompanionScreenCaptureUtility.bestDisplayIndex(
            for: drawnRect, among: DispatchQueue.main.sync { NSScreen.screens.map(\.frame) }
        ) else {
            return refuse("targetNotOnScreen", "the element's frame is on no display")
        }

        // The voice loop's pointer: never onto a password box, whatever name led here.
        let resolvedRole = target.node.role
        if request.pointer, let refusal = HarnessPolicy.pointerRefusal(
            resolvedFrame: target.node.frameInAppKitCoordinates, nearPoint: request.nearPoint, role: resolvedRole,
            subrole: target.node.subrole, subroleReadFailed: target.node.subroleReadFailed, namedByValue: target.node.namedByValue
        ) {
            return refuse(refusal.code, refusal.message)
        }

        phaseTiming.actionStarting()
        // Never inside the request: a synchronous show pumps the run loop and lets
        // a second socket request land inside this one.
        let seconds = request.highlightSeconds, label = request.label, pointer = request.pointer, speechHold = request.speechHold
        DispatchQueue.main.async {
            if pointer {
                ElementPointer.show(drawnRect, role: resolvedRole, seconds: seconds, followSpeech: speechHold)
            } else {
                ElementHighlightOverlay.show(drawnRect, label: label, onScreenAt: screenIndex, seconds: seconds)
            }
        }
        response["pointer"] = pointer

        response["ok"] = true
        Self.attachFrame(elementFrame, to: &response, key: "elementFrame")
        Self.attachFrame(drawnRect, to: &response, key: "drawnRect")
        response["screen"] = screenIndex
        response["seconds"] = seconds
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "highlighted", startedAt: startedAt)
        return response
    }

    // MARK: scroll

    /// Scroll the frontmost window — a named area of it, the area under a point,
    /// or its largest scrolling area — and say what came into view. See
    /// `HarnessScroll`. No kernel question (it moves what is on screen, no data);
    /// the app policy, kill switch, `expectApp` and Clicky-itself refusals hold.
    private func scrollResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = ["dryRun": dryRun, "direction": request.scrollDirection?.rawValue ?? NSNull(),
                                       "amount": request.scrollPages]
        func fail(_ code: String, _ message: String, kernel: String = "n/a") -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: kernel, outcome: code, startedAt: startedAt)
            return response
        }
        // `decode` guarantees it; a nil here is our bug, not a default.
        guard let direction = request.scrollDirection else { return fail("missingField", "missing required field \"direction\"") }
        let snapshot: AccessibilityWindowSnapshot
        do {
            snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
        } catch {
            return fail(Self.errorCode(for: error), String(describing: error))
        }
        if let refusal = frontmostChangedRefusal(
            request, name: snapshot.applicationName, bundleIdentifier: snapshot.bundleIdentifier, dryRun: dryRun, startedAt: startedAt
        ) { return response.merging(refusal) { _, new in new } }
        guard let rootNode = snapshot.rootNode else { return fail("noRootNode", "the walk produced no root element") }
        response["application"] = snapshot.applicationName
        response["bundleIdentifier"] = snapshot.bundleIdentifier
        response["walkMilliseconds"] = Int(snapshot.walkDurationInSeconds * 1000)

        var targetChain: [AccessibilityElementNode]?
        if !request.title.isEmpty {
            let intent = ElementActionIntent(role: request.role, title: request.title, action: .press,
                                             nearPoint: request.nearPoint, withinNamed: request.withinNamed)
            switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
            case .resolved(let node): targetChain = ElementReachability.ancestorChain(to: node, from: rootNode)
            case .notFound: return fail("notFound", "nothing named \(UntrustedText(request.title).forDisplay) is in the window")
            case .ambiguous(let count): return fail("ambiguous", "\(count) elements in the window have that name")
            }
        }
        let container = HarnessScroll.container(in: rootNode, targetChain: targetChain, point: targetChain == nil ? request.nearPoint : nil)
        let windowFrame = rootNode.frameInAppKitCoordinates
        let bounds = (container?.frameInAppKitCoordinates ?? windowFrame).intersection(windowFrame)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return fail("targetNotOnScreen", "the area to scroll is not inside the window")
        }
        var containerEntry: [String: Any] = ["role": container?.role ?? "AXWindow"]
        Self.attachFrame(bounds, to: &containerEntry)
        response["container"] = containerEntry

        let decision = applyAppPolicy(to: .allow, bundleIdentifier: snapshot.bundleIdentifier, into: &response)
        let gated = gate(decision, request: request, appName: snapshot.applicationName,
                         bundleIdentifier: snapshot.bundleIdentifier, dryRun: dryRun, into: &response)
        guard gated.executable else { return fail(gated.outcome, "app policy: \(gated.note ?? gated.outcome)", kernel: gated.decision) }
        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: gated.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        let before = HarnessScroll.visibleNames(fromNamedElements: Self.namedElements(in: rootNode), within: bounds)
        // Everything the walk knew, in view or not: what comes in from below was below.
        let known = HarnessScroll.visibleNames(fromNamedElements: Self.namedElements(in: rootNode, clippedToView: false), within: .infinite)
        let barBefore = HarnessScroll.scrollBarValue(of: container?.accessibilityElement, horizontal: direction.isHorizontal)
        // Re-walk until the content moved (an animated page takes a few hundred ms), ~1 s at most.
        func observe() -> (outcome: ScrollOutcome, newlyVisible: [String]) {
            var last: (outcome: ScrollOutcome, newlyVisible: [String]) = (.notObserved, [])
            for attempt in 0..<5 {
                Thread.sleep(forTimeInterval: attempt == 0 ? 0.15 : 0.2)
                let barAfter = HarnessScroll.scrollBarValue(of: container?.accessibilityElement, horizontal: direction.isHorizontal)
                // The SAME window (A3, 2026-10-02: a scroll "confirmed" with the page
                // unmoved), its frames taken relative to where it stood before: a
                // window that moved or animated is not content that scrolled.
                guard let later = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
                      later.bundleIdentifier == snapshot.bundleIdentifier, let laterRoot = later.rootNode,
                      let window = rootNode.accessibilityElement, let laterWindow = laterRoot.accessibilityElement,
                      CFEqual(window, laterWindow) else { continue }
                let dx = windowFrame.minX - laterRoot.frameInAppKitCoordinates.minX
                let dy = windowFrame.minY - laterRoot.frameInAppKitCoordinates.minY
                let after = HarnessScroll.visibleNames(fromNamedElements: Self.namedElements(in: laterRoot),
                                                       within: bounds.offsetBy(dx: -dx, dy: -dy))
                    .map { (name: $0.name, frame: $0.frame.offsetBy(dx: dx, dy: dy)) }
                let change = HarnessScroll.change(before: known, after: after, direction: direction, inViewBefore: Set(before.map(\.name)))
                last = (HarnessScroll.outcome(moved: change.moved, barBefore: barBefore, barAfter: barAfter, direction: direction),
                        change.newlyVisible)
                if last.outcome == .moved { return last }
            }
            return last
        }

        phaseTiming.actionStarting()
        var method = "none"
        var axErrors: [Int] = []
        var observed: (outcome: ScrollOutcome, newlyVisible: [String])?
        // The container's own page verb first — published is not implemented
        // (the About pane's four all failed -25204), so a re-read decides.
        // A page verb that reported success is NOT followed by a wheel (review
        // 2026-10-01): a page that moved only unnamed content would scroll twice.
        let pageAction = direction.pageDirection.accessibilityActionName
        if let container, let element = container.accessibilityElement, container.publishedActionNames.contains(pageAction) {
            for _ in 0..<Int(request.scrollPages.rounded(.up)) {
                let result = AccessibilityActionPerformer.perform(pageAction, on: element)
                axErrors.append(Int(result.error.rawValue))
                guard result.error == .success else { break }
            }
            if axErrors.allSatisfy({ $0 == 0 }) {
                method = "axAction"
                observed = observe()
            }
        }
        // Otherwise the wheel, at the container's own rectangle (or the caller's point inside it).
        if observed == nil {
            let point = request.nearPoint.flatMap { bounds.contains($0) ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let topLeft = SyntheticScroller.topLeftCentre(ofAppKitFrame: CGRect(origin: point, size: .zero),
                                                          primaryDisplayHeightInPoints: CGDisplayBounds(CGMainDisplayID()).height)
            // A wheel event goes to whatever window is under the point: only ever this app's.
            guard let processIdentifier = snapshot.application?.processIdentifier, Self.processIdentifier(at: topLeft) == processIdentifier else {
                phaseTiming.actionReturned()
                return fail("wheelTargetObscured", "another window covers that point, or it could not be checked; nothing more was scrolled",
                            kernel: gated.decision)
            }
            let extent = direction.isHorizontal ? bounds.width : bounds.height
            SyntheticScroller.scroll(atTopLeftPoint: topLeft, wheelDelta: direction.pageDirection.syntheticWheelDelta,
                                     steps: HarnessScroll.wheelSteps(pages: request.scrollPages, extent: extent),
                                     horizontal: direction.isHorizontal)
            method = "wheel"
            observed = observe()
        }
        phaseTiming.actionReturned()
        response["performed"] = ["method": method, "axErrorRawValues": axErrors]
        let outcome = observed?.outcome ?? .notObserved
        switch outcome {
        case .moved:
            response["verification"] = ["status": "confirmed", "evidence": "elements in view shifted as scrolling \(direction.rawValue) moves them, or the scroll bar did"]
            response["ok"] = true
        case .atEnd:
            response["verification"] = ["status": "atEnd", "evidence": "the scroll bar is already at that end"]
            response["ok"] = false
            response["error"] = "atEnd"
            response["message"] = "already at the end; there is nothing further to scroll that way"
        case .notObserved:
            response["verification"] = ["status": "notObserved", "evidence": "nothing in view moved"]
            response["ok"] = false
            response["error"] = "notVerified"
            response["message"] = "nothing in view moved — the area may not scroll that way"
        }
        response["newlyVisible"] = observed?.newlyVisible ?? []
        audit(request, dryRun: dryRun, kernel: gated.decision,
              outcome: outcome == .moved ? "confirmed" : outcome.rawValue, startedAt: startedAt)
        return response
    }

    /// The process owning what is drawn at a global top-left point, or nil.
    private static func processIdentifier(at topLeftPoint: CGPoint) -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, RealtimeScreenHitTest.messagingTimeoutSeconds)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(topLeftPoint.x), Float(topLeftPoint.y), &element) == .success,
              let element else { return nil }
        var processIdentifier: pid_t = 0
        return AXUIElementGetPid(element, &processIdentifier) == .success ? processIdentifier : nil
    }

    /// The voice loop's approximate ring: nothing nameable at the point the
    /// model gave, so a dashed ring there, said to be approximate. Same guards
    /// as any read of the app in front: not Clicky, and `expectApp` holds.
    private func approximateRingResponse(_ request: HarnessRequest, at point: CGPoint, dryRun: Bool, startedAt: Date,
                                         into response: inout [String: Any]) -> [String: Any] {
        let frontmost = AccessibilityTreeWalker.frontmost().application
        if let refusal = frontmostChangedRefusal(request, name: frontmost?.localizedName, bundleIdentifier: frontmost?.bundleIdentifier,
                                                 dryRun: dryRun, startedAt: startedAt) {
            response.merge(refusal) { _, new in new }
            return response
        }
        // Words drawn there: the pointer lands on that word's own box, read by OCR from
        // a capture that passed every guard `look` has — exact, never a guessed pixel.
        if let frontmost, let word = ocrWord(at: point, of: frontmost) {
            phaseTiming.actionStarting()
            let seconds = request.highlightSeconds, speechHold = request.speechHold
            DispatchQueue.main.async { ElementPointer.show(word.frame, role: "AXStaticText", seconds: seconds, followSpeech: speechHold) }
            response["ok"] = true
            response["pointer"] = true
            response["snappedTo"] = "ocrWord"
            response["ocrText"] = word.line
            Self.attachFrame(word.frame, to: &response, key: "drawnRect")
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "highlighted", startedAt: startedAt)
            return response
        }
        let side = ElementPointer.approximateSidePoints
        let ring = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        guard CompanionScreenCaptureUtility.bestDisplayIndex(for: ring, among: DispatchQueue.main.sync { NSScreen.screens.map(\.frame) }) != nil else {
            response["ok"] = false
            response["error"] = "targetNotOnScreen"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "targetNotOnScreen", startedAt: startedAt)
            return response
        }
        phaseTiming.actionStarting()
        let seconds = request.highlightSeconds, speechHold = request.speechHold
        DispatchQueue.main.async { ElementPointer.show(ring, role: "", seconds: seconds, approximate: true, followSpeech: speechHold) }
        response["ok"] = true
        response["pointer"] = true
        response["approximate"] = true
        Self.attachFrame(ring, to: &response, key: "drawnRect")
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "highlighted", startedAt: startedAt)
        return response
    }

    /// The word OCR reads at `point` in `application`'s own windows, and the line
    /// it sits in: a guarded crop around the point (`escalationPayload`: the
    /// policy's `refuse`, the one-app filter, secure fields, secrets). nil when
    /// nothing was read there, or the capture was refused.
    static let ocrLabelLength = 40

    private func ocrWord(at point: CGPoint, of application: NSRunningApplication) -> (frame: CGRect, line: String)? {
        let crop = CGRect(x: point.x - HarnessHands.visionCropSize.width / 2, y: point.y - HarnessHands.visionCropSize.height / 2,
                          width: HarnessHands.visionCropSize.width, height: HarnessHands.visionCropSize.height)
        let captured = escalationPayload(plan: EscalationPlan(tier: .element, reason: "the words drawn at the point", region: crop,
                                                              resolver: "pointer", candidates: [], application: application), capture: true)
        guard captured.errorCode == nil, let path = captured.payload["imagePath"] as? String,
              let jpeg = FileManager.default.contents(atPath: path), let region = RealtimeScreenVerbs.frame(captured.payload["region"]) else { return nil }
        let lines = ScreenOCR.recognize(jpeg: jpeg, region: region)
        guard let word = ScreenOCR.wordBox(at: point, in: lines) else { return nil }
        // A short line is the label the word belongs to ("Launch demo"): marked whole; a long one, the word.
        guard let line = ScreenOCR.line(holding: word, in: lines) else { return (word.frame, word.text) }
        return (line.text.count <= Self.ocrLabelLength ? line.frame : word.frame, line.text)
    }

    /// Walk, check `expectApp`, and resolve the request's element — or write the
    /// refusal into `response`, audit it, and return nil. Shared by the acting
    /// verbs and `highlight`, so an outline is always round exactly the element a
    /// press with the same fields would have pressed.
    private func resolveTarget(
        _ request: HarnessRequest, action: ElementAction, dryRun: Bool, startedAt: Date,
        into response: inout [String: Any]
    ) -> (snapshot: AccessibilityWindowSnapshot, rootNode: AccessibilityElementNode,
          intent: ElementActionIntent, node: AccessibilityElementNode)? {
        let snapshot: AccessibilityWindowSnapshot
        do {
            snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
        } catch {
            let code = Self.errorCode(for: error)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            response["ok"] = false
            response["error"] = code
            response["message"] = String(describing: error)
            return nil
        }

        // Before the intent is resolved, so a moved focus never gets as far as
        // naming an element — let alone pressing one — in the wrong app.
        if let refusal = frontmostChangedRefusal(
            request, name: snapshot.applicationName, bundleIdentifier: snapshot.bundleIdentifier,
            dryRun: dryRun, startedAt: startedAt
        ) {
            response.merge(refusal) { _, new in new }
            return nil
        }

        guard let rootNode = snapshot.rootNode else {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noRootNode", startedAt: startedAt)
            response["ok"] = false
            response["error"] = "noRootNode"
            return nil
        }
        response["application"] = snapshot.applicationName
        response["bundleIdentifier"] = snapshot.bundleIdentifier
        response["frontmostSource"] = snapshot.frontmostSource?.rawValue ?? NSNull()
        // Carried on every acting response, not just snapshot, because the
        // slow-walk anomaly rule has nothing else to compare.
        response["walkMilliseconds"] = Int(snapshot.walkDurationInSeconds * 1000)

        let intent = ElementActionIntent(
            role: request.role,
            title: request.title,
            action: action,
            nearPoint: request.nearPoint,
            withinNamed: request.withinNamed
        )

        let resolvedNode: AccessibilityElementNode
        if request.aimAtWindow {
            resolvedNode = rootNode
            response["resolution"] = ["status": "window", "matchCount": 1]
        } else if request.aimAtFocus {
            // The OS says what has focus. No name is involved, which is the
            // point: the fields most worth typing into are anonymous.
            guard let focusedNode = AccessibilityTypePerformer.focusedNode() else {
                response["resolution"] = ["status": "noFocusedElement", "matchCount": 0]
                response["ok"] = false
                response["error"] = "noFocusedElement"
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noFocusedElement", startedAt: startedAt)
                return nil
            }
            resolvedNode = focusedNode
            response["resolution"] = ["status": "focused", "matchCount": 1]
        } else {
            switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
            case .resolved(let node):
                resolvedNode = node
                response["resolution"] = ["status": "resolved", "matchCount": 1]
            case .notFound:
                response["resolution"] = ["status": "notFound", "matchCount": 0]
                response["ok"] = false
                response["error"] = "notFound"
                // The two answers a tree walk cannot improve on its own are the
                // two that get a rung offered. Everything else here is a
                // decision the harness already made.
                attachEscalation(to: &response, request: request, rootNode: rootNode, application: snapshot.application)
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return nil
            case .ambiguous(let matchCount):
                response["resolution"] = ["status": "ambiguous", "matchCount": matchCount]
                response["ok"] = false
                response["error"] = "ambiguous"
                // The free rung, below the picture: every match, each with the
                // nearest container name that picks it out alone. No capture and
                // no AX reads — it re-traverses the tree already in memory.
                let suggestions = ElementActionIntentResolver.containerSuggestions(
                    for: intent, inTreeRootedAt: rootNode
                )
                response["candidates"] = suggestions.prefix(Self.maximumCandidates).enumerated().map {
                    index, suggestion -> [String: Any] in
                    var entry = Self.summarise(suggestion.node)
                    entry["index"] = index
                    entry["suggestedWithinNamed"] = suggestion.suggestedWithinNamed ?? NSNull()
                    // Re-issuable only to a verb that resolves by element name.
                    entry["resolver"] = "elementName"
                    return entry
                }
                if suggestions.count > Self.maximumCandidates {
                    response["candidatesTruncated"] = true
                    response["warning"] = "THIS LIST IS A FLOOR, NOT A MEASUREMENT — showing "
                        + "\(Self.maximumCandidates) of \(suggestions.count) matches"
                }
                attachEscalation(to: &response, request: request, rootNode: rootNode, application: snapshot.application)
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ambiguous", startedAt: startedAt)
                return nil
            }
        }
        // press_element (and the pointer, in `pointerRefusal`): the element the
        // name resolved to must be the one at the point that was aimed at.
        if request.requireAtPoint, let moved = HarnessPolicy.movedRefusal(
            resolvedFrame: resolvedNode.frameInAppKitCoordinates, nearPoint: request.nearPoint
        ) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: moved.code, startedAt: startedAt)
            response["ok"] = false
            response["error"] = moved.code
            response["message"] = moved.message
            return nil
        }
        return (snapshot, rootNode, intent, resolvedNode)
    }

    private func actResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        guard let action = request.verb.elementAction else {
            return ["ok": false, "error": "unknownVerb", "message": "not an acting verb"]
        }

        var response: [String: Any] = ["dryRun": dryRun, "confirmed": request.confirmed]

        guard let target = resolveTarget(request, action: action, dryRun: dryRun, startedAt: startedAt, into: &response)
        else { return response }
        let (snapshot, rootNode, intent, namedNode) = target
        // A label names a link or button it sits in: the press goes to — and is
        // judged on — that control, and the label's words are word-checked too.
        // Here, not in `resolveTarget`: highlight points at what was named.
        var resolvedNode = namedNode
        var labelTitle = request.labelTitle
        if action == .press || action == .click, !request.aimAtFocus, !request.aimAtWindow,
           let chain = ElementReachability.ancestorChain(to: namedNode, from: rootNode),
           let control = HarnessPolicy.controlLabelled(byLastOf: chain) {
            resolvedNode = control
            labelTitle = namedNode.displayName?.raw ?? labelTitle
            response["retargetedFrom"] = Self.summarise(namedNode)
        }
        // A label names the field it labels: type goes there, judged as that field.
        if action == .type, !request.aimAtFocus, !AccessibilityElementNode.textInputRoles.contains(namedNode.role),
           let chain = ElementReachability.ancestorChain(to: namedNode, from: rootNode),
           let field = HarnessPolicy.fieldLabelled(by: namedNode, chain: chain, name: request.title ?? "",
                                                   linked: HarnessPolicy.liveLabelLink(namedNode)) {
            resolvedNode = field
            // The label's own words are judged by the kernel too ("Type DELETE to confirm").
            labelTitle = namedNode.displayName?.raw ?? labelTitle
            response["retargetedFrom"] = Self.summarise(namedNode)
        }
        response["resolved"] = Self.summarise(resolvedNode)

        // What the element itself says about being typed into. Four reads on
        // one element — never a per-node cost — and skipped entirely for what
        // might be a secure field (role, subrole, or an unreadable subrole),
        // which the kernel refuses without its value.
        let liveElement = resolvedNode.accessibilityElement
        let typing = HarnessPolicy.typingContext(
            verb: request.verb, mode: request.mode, aimedByFocus: request.aimAtFocus, of: resolvedNode,
            settable: { liveElement.map(AccessibilityTypePerformer.settableAttributes) ?? [] },
            value: { liveElement.flatMap(AccessibilityTypePerformer.stringValue) }
        )
        let typingContext = typing?.context
        if let field = typing?.field { response["field"] = field }

        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluate(
                intent: intent,
                resolvedNode: resolvedNode,
                matchCount: 1,
                visibleBounds: rootNode.frameInAppKitCoordinates,
                typing: typingContext,
                labelTitle: labelTitle
            ),
            bundleIdentifier: snapshot.bundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        // select is not bound: it CHANGES the selection, it does not act on one.
        let bindingSubject = request.verb == .select ? nil : ActionBinding.Subject(
            targetElement: resolvedNode.accessibilityElement, processIdentifier: snapshot.application?.processIdentifier
        )
        let gated = gate(decision, request: request, appName: snapshot.applicationName,
                         bundleIdentifier: snapshot.bundleIdentifier, dryRun: dryRun,
                         bindingSubject: bindingSubject, into: &response)

        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        // The fingerprint has to cover every name, not just pressable ones —
        // a Finder window that went 219 nodes to 99 reported "nothing changed"
        // when only pressable names were diffed.
        let namesBefore = AccessibilityDumpRunner.namedElementFingerprint(in: rootNode)

        let performedOK: Bool
        var keystrokesSawTheText = false
        switch action {
        case .click:
            // Its own act and look (AXPress or a real click, focus or names as evidence).
            return clickAct(request, node: resolvedNode, rootNode: rootNode, snapshot: snapshot, namesBefore: namesBefore,
                            kernel: described.decision, dryRun: dryRun, startedAt: startedAt, response: response)

        case .press, .open, .menu:
            guard let element = resolvedNode.accessibilityElement else {
                response["ok"] = false
                response["error"] = "noLiveElement"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
                return response
            }
            phaseTiming.actionStarting()
            let result = AccessibilityActionPerformer.perform(
                action.accessibilityActionName ?? kAXPressAction, on: element
            )
            // Print the raw code AND the clock: -25204 in 2 ms is the app
            // refusing, -25204 at 5,000 ms is our own timeout firing. Same
            // number, opposite problems.
            response["performed"] = [
                "status": result.error == .success ? "sent" : "failed",
                "axErrorRawValue": result.error.rawValue,
                "milliseconds": result.milliseconds
            ]
            performedOK = result.error == .success

        case .select:
            guard let chain = ElementReachability.ancestorChain(to: resolvedNode, from: rootNode) else {
                response["ok"] = false
                response["error"] = "noAncestorChain"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noAncestorChain", startedAt: startedAt)
                return response
            }
            phaseTiming.actionStarting()
            let outcome = AccessibilitySelectionPerformer.select(chainFromRoot: chain)
            switch outcome {
            case .selected(let path, let levelsUp, let milliseconds, let readBackTrue):
                response["performed"] = [
                    "status": "sent",
                    "selectionPath": path.rawValue,
                    "levelsAboveNamedElement": levelsUp,
                    "selectedRole": chain[chain.count - 1 - levelsUp].role,
                    "milliseconds": milliseconds,
                    "readBackSelected": readBackTrue
                ]
                performedOK = true
            case .alreadySelected(let path, let levelsUp):
                // Nothing was written, so a second walk could only ever report
                // notObserved — after the full 3 s.
                response["performed"] = [
                    "status": "alreadySelected",
                    "selectionPath": path.rawValue,
                    "levelsAboveNamedElement": levelsUp,
                    "selectedRole": chain[chain.count - 1 - levelsUp].role
                ]
                response["verification"] = [
                    "status": "notNeeded",
                    "reason": "the container's selection already is exactly this row — nothing was written, so there is nothing to verify"
                ]
                response["ok"] = true
                // The performer ran (it read the container's selection), so act is real; nothing to verify.
                phaseTiming.actionReturned()
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "alreadySelected", startedAt: startedAt)
                return response
            case .writeFailed(let error, let levelsUp, let milliseconds):
                response["performed"] = [
                    "status": "failed",
                    "axErrorRawValue": error.rawValue,
                    "levelsAboveNamedElement": levelsUp,
                    "milliseconds": milliseconds
                ]
                performedOK = false
            case .noSelectableAncestor(let levelsInspected):
                response["performed"] = ["status": "noSelectableAncestor", "levelsInspected": levelsInspected]
                performedOK = false
            case .noLiveElement:
                response["performed"] = ["status": "noLiveElement"]
                performedOK = false
            }

        case .type:
            guard let element = resolvedNode.accessibilityElement else {
                response["ok"] = false
                response["error"] = "noLiveElement"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
                return response
            }

            phaseTiming.actionStarting()
            guard let processIdentifier = snapshot.application?.processIdentifier else {
                phaseTiming.actionReturned()
                response["ok"] = false
                response["error"] = "noLiveElement"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
                return response
            }
            var afterWrite = HarnessHands.AfterWrite.keystrokes
            let keystrokesFirst = HarnessHands.typeStartsWithKeystrokes(
                forced: request.forcedTypeMethod,
                inWebContent: request.forcedTypeMethod == nil && HarnessHands.isWebContent(element, application: snapshot.application))
            if keystrokesFirst, request.forcedTypeMethod == nil { response["axWriteSkipped"] = "webContent" }
            if !keystrokesFirst {
                // Read apart from the performer's, which collapses "no value" into "": unreadable is not empty.
                let valueLengthBefore = AccessibilityTypePerformer.stringValue(of: element)?.count
                let outcome = AccessibilityTypePerformer.type(request.text, mode: request.mode, into: element)
                // Nothing was written: a selection the owner made still stands.
                if let refusal = outcome.refusal {
                    phaseTiming.actionReturned()
                    response["ok"] = false
                    response["error"] = "selectionNotEmpty"
                    response["message"] = refusal
                    audit(request, dryRun: dryRun, kernel: described.decision, outcome: "selectionNotEmpty", startedAt: startedAt)
                    return response
                }

                // For typing, the read-back IS the evidence — the text is the
                // effect. The fingerprint below says whether the app *reacted*,
                // which is a different question, and they are reported separately
                // on purpose.
                var (performed, containsWhatWeWrote) = HarnessPolicy.typedEvidence(outcome, wrote: request.text)
                var valueLengthAfter = outcome.valueAfter?.count
                // A web field may apply the write a beat later: look again before deciding to type it twice.
                if outcome.error == .success, !containsWhatWeWrote {
                    HarnessHands.waitUntil(seconds: 0.3) {
                        let value = AccessibilityTypePerformer.stringValue(of: element)
                        valueLengthAfter = value?.count
                        containsWhatWeWrote = value?.contains(request.text) ?? false
                        return containsWhatWeWrote
                    }
                    performed["valueLengthAfter"] = valueLengthAfter ?? NSNull()
                    performed["readBackContainsText"] = containsWhatWeWrote
                }
                performed["method"] = TypeMethod.axWrite.rawValue
                response["performed"] = performed
                // `.success` on a write that changed nothing has been measured three
                // times in this repo. The field's own text is what decides here.
                afterWrite = HarnessHands.afterAXWrite(
                    forced: request.forcedTypeMethod, axError: outcome.error, valueLengthBefore: valueLengthBefore,
                    valueLengthAfter: valueLengthAfter, containsText: containsWhatWeWrote, typedCount: request.text.count)
            }

            switch afterWrite {
            case .done:
                performedOK = true
                response["method"] = TypeMethod.axWrite.rawValue
            case .failed:
                performedOK = false
            case .refuse(let refusal):
                phaseTiming.actionReturned()
                response["ok"] = false
                response["error"] = refusal.code
                response["message"] = refusal.message
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: refusal.code, startedAt: startedAt)
                return response
            case .keystrokes:
                // The AX write did not take (Chrome's New Tab box, a contenteditable
                // composer — live 2026-10-02): type it as key events instead.
                // Focus first, here only (review of H1): keystrokes need it; the AX
                // write does not, and a focusing click before it was input for nothing.
                // The owner idle before that click, not only before the keys.
                let (focus, typed) = HarnessHands.idleThenFocusThenType(
                    ownerIdle: { HarnessHands.waitUntil(seconds: HarnessHands.ownerIdleWaitSeconds) { HarnessHands.ownerIsIdleNow() } },
                    focus: {
                        HarnessHands.focusForTyping(
                            element, windowFrame: rootNode.frameInAppKitCoordinates, processIdentifier: processIdentifier,
                            focusSettable: typingContext?.settableAttributes.contains(kAXFocusedAttribute) == true)
                    },
                    type: {
                        HarnessHands.typeByKeystrokes(request.text, mode: request.mode, into: element,
                                                      processIdentifier: processIdentifier, fingerprintBefore: namesBefore,
                                                      secureInput: secureInputRead)
                    })
                if let focus { response["focus"] = focus }
                switch typed {
                case .refused(let refusal):
                    phaseTiming.actionReturned()
                    response["ok"] = false
                    response["error"] = refusal.code
                    response["message"] = refusal.message
                    audit(request, dryRun: dryRun, kernel: described.decision, outcome: refusal.code, startedAt: startedAt)
                    return response
                case .posted(var payload, let evidence):
                    if let axWrite = response["performed"] { payload["axWrite"] = axWrite }
                    payload["evidence"] = evidence ?? NSNull()
                    response["performed"] = payload
                    response["method"] = TypeMethod.keystrokes.rawValue
                    performedOK = evidence != nil
                    keystrokesSawTheText = evidence.map(HarnessHands.readBackEvidence.contains) ?? false
                }
            }

            if request.thenConfirm {
                // A missing AXConfirm is never a failure of the type — measured
                // 2026-09-10, System Settings' search filtered live with no
                // confirm at all.
                let publishesConfirm = resolvedNode.publishedActionNames.contains(kAXConfirmAction)
                if publishesConfirm {
                    let confirmResult = AccessibilityActionPerformer.perform(kAXConfirmAction, on: element)
                    response["confirm"] = [
                        "published": true,
                        "axErrorRawValue": confirmResult.error.rawValue,
                        "milliseconds": confirmResult.milliseconds
                    ]
                } else {
                    response["confirm"] = ["published": false]
                }
            }
        }

        // Includes `thenConfirm`'s AXConfirm and the type performer's own read-back.
        phaseTiming.actionReturned()
        guard performedOK else {
            response["ok"] = false
            response["error"] = "performFailed"
            if (response["performed"] as? [String: Any])?["status"] as? String == "noSelectableAncestor" {
                response["message"] = "it publishes no press and is not an item in a list that can be selected; nothing was done. "
                    + "Press the control that holds it, or point at it."
            }
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "performFailed", startedAt: startedAt)
            return response
        }

        // Keystrokes re-read the field and saw it grow by exactly the text: the effect
        // itself. The fingerprint poll below cannot see a field's contents (names never
        // carry them), so it only waited out its 3 s — 3.1 s of every typed field on
        // the hands probe, 2026-10-02.
        if keystrokesSawTheText {
            phaseTiming.verified(walks: 0, path: "readBack")
            response["verification"] = ["status": "confirmed",
                                        "evidence": (response["performed"] as? [String: Any])?["evidence"] ?? HarnessHands.valueGrewEvidence,
                                        "milliseconds": 0, "appeared": [String]()]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
            return response
        }

        // .success only means the message was delivered. Three separate writes
        // in this repo returned .success and moved nothing, so the second walk
        // is the only tier that gets to say "it worked".
        let (verification, verifyWalks, confirmingSnapshot) = ActionVerifier.verifyCountingWalks { laterSnapshot in
            guard let laterRoot = laterSnapshot.rootNode else { return false }
            return AccessibilityDumpRunner.namedElementFingerprint(in: laterRoot) != namesBefore
        }
        // "poll" is the only honest path: this verifier re-walks on a 150 ms
        // timer and subscribes to no AX event.
        phaseTiming.verified(walks: verifyWalks, path: "poll")

        switch verification {
        case .confirmed(let milliseconds):
            // A first-look confirmation is reused; anything later walks again.
            // See `ActionVerifier.snapshotToDescribe` for the T3-1 evidence.
            var appeared: [String] = []
            if let laterRoot = ActionVerifier.snapshotToDescribe(
                confirming: confirmingSnapshot, walks: verifyWalks,
                walkAgain: { try? AccessibilityTreeWalker.snapshotFocusedWindow() }
            )?.rootNode {
                appeared = Self.appearedNames(in: laterRoot, since: namesBefore)
            }
            response["verification"] = [
                "status": "confirmed", "evidence": "named elements changed",
                "milliseconds": milliseconds, "appeared": appeared
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .windowGone(let milliseconds):
            // "The app reacted" is all a fingerprint change ever proved, and the
            // window we acted in vanishing is the same evidence.
            response["verification"] = [
                "status": "confirmed", "evidence": "the focused window closed",
                "milliseconds": milliseconds, "appeared": [String]()
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .notObserved(let milliseconds):
            response["verification"] = [
                "status": "notObserved", "milliseconds": milliseconds, "appeared": [String]()
            ]
            // For a press or a select the fingerprint is the only evidence there
            // is. For a type it is the *second* piece: the text is the effect,
            // and the field already read it back. An app that accepted the text
            // and did not otherwise move is a real, ordinary outcome — so the
            // two are reported separately rather than collapsed into one verdict.
            if request.verb == .type {
                response["ok"] = true
                response["verificationNote"] =
                    "the field read back the text; the window's named elements did not change"
            } else {
                response["ok"] = false
                response["error"] = "notVerified"
            }
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
        case .couldNotReadWindow:
            response["verification"] = ["status": "couldNotReadWindow"]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "couldNotReadWindow", startedAt: startedAt)
        }

        return response
    }

    // MARK: click

    /// `click` after the kernel and the gate: `AXPress` when the element publishes
    /// it and is not a text input, a real left click at its visible centre
    /// otherwise — or when the press went in and nothing could be seen to change
    /// (never on a toggle, which a second activation would undo). Each method is
    /// looked at before the next is tried; `method` says which one worked.
    private func clickAct(_ request: HarnessRequest, node: AccessibilityElementNode, rootNode: AccessibilityElementNode,
                          snapshot: AccessibilityWindowSnapshot, namesBefore: Set<String>, kernel: String,
                          dryRun: Bool, startedAt: Date, response initial: [String: Any]) -> [String: Any] {
        var response = initial
        func finish(_ outcome: String, error: String? = nil, message: String? = nil) -> [String: Any] {
            response["ok"] = error == nil
            if let error { response["error"] = error }
            if let message { response["message"] = message }
            audit(request, dryRun: dryRun, kernel: kernel, outcome: outcome, startedAt: startedAt)
            return response
        }
        guard let element = node.accessibilityElement, let processIdentifier = snapshot.application?.processIdentifier else {
            return finish("noLiveElement", error: "noLiveElement")
        }
        let methods = HarnessHands.clickMethods(publishesPress: node.publishedActionNames.contains(kAXPressAction),
                                                role: node.role, forced: request.forcedClickMethod)
        guard !methods.isEmpty else {
            return finish("pressNotPublished", error: "pressNotPublished",
                          message: "the element does not publish AXPress, so a forced axPress has nothing to send")
        }
        let focusedBefore = HarnessHands.focusIsOn(element, processIdentifier: processIdentifier)
        var attempts: [[String: Any]] = []
        var evidence: String?
        var walks = 0

        // Re-walks until the names change or focus arrives on the element.
        func look() -> String? {
            var seen: String?
            let (outcome, used, _) = ActionVerifier.verifyCountingWalks { later in
                guard let laterRoot = later.rootNode else { return false }
                seen = HarnessHands.clickEvidence(
                    fingerprintChanged: AccessibilityDumpRunner.namedElementFingerprint(in: laterRoot) != namesBefore,
                    focusedBefore: focusedBefore,
                    focusedNow: HarnessHands.focusIsOn(element, processIdentifier: processIdentifier))
                return seen != nil
            }
            walks += used
            if case .windowGone = outcome { return "the focused window closed" }
            return seen
        }

        phaseTiming.actionStarting()
        var pressError: AXError?
        for method in methods {
            var attempt: [String: Any] = ["method": method.rawValue]
            switch method {
            case .axPress:
                let result = AccessibilityActionPerformer.perform(kAXPressAction, on: element)
                phaseTiming.actionReturned()
                pressError = result.error
                // The raw code AND the clock: -25204 in 2 ms and at 5,000 ms are opposite problems.
                attempt["axErrorRawValue"] = Int(result.error.rawValue)
                attempt["milliseconds"] = result.milliseconds
                guard HarnessHands.afterPress(error: result.error) == .verify else {
                    attempts.append(attempt)
                    continue
                }
            case .click:
                switch HarnessHands.clickElement(element, windowFrame: rootNode.frameInAppKitCoordinates,
                                                 processIdentifier: processIdentifier) {
                case .failure(let refusal):
                    phaseTiming.actionReturned()
                    attempt["refused"] = refusal.code
                    attempts.append(attempt)
                    response["performed"] = ["attempts": attempts]
                    return finish(refusal.code, error: refusal.code, message: refusal.message)
                case .success(let topLeft):
                    phaseTiming.actionReturned()
                    attempt["pointTopLeft"] = Self.pointJSON(topLeft).point
                }
            }
            evidence = look()
            attempt["verified"] = evidence != nil
            attempts.append(attempt)
            if evidence != nil {
                response["method"] = method.rawValue
                break
            }
            // A press that went in and showed nothing is not clicked again: a second activation.
            if method == .axPress, let pressError, !HarnessHands.clickFollowsPress(error: pressError) { break }
        }
        phaseTiming.verified(walks: walks, path: "poll")
        response["performed"] = ["attempts": attempts]

        guard let evidence else {
            response["verification"] = ["status": "notObserved", "evidence": "names did not change and focus did not arrive"]
            return finish("notObserved", error: "notVerified")
        }
        response["verification"] = ["status": "confirmed", "evidence": evidence]
        return finish("confirmed")
    }

    // MARK: visionClick

    /// The ladder's last rung (owner 2026-10-05): a click on what is DRAWN at a
    /// point AX cannot press — a canvas, an image-only button. The model names
    /// the words on it; Vision OCR, run here on our own capture (every guard
    /// `look` has: policy, one-app filter, secure-field inspection, secret
    /// blackout), must read those words AT the point — a witness that is not
    /// the model. The kernel then judges the words read, as it judges an AX
    /// name, and a card is a ticket like any other. Verified by the region's
    /// own pixels changing; otherwise `notObserved`, never done.
    private func visionClickResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = ["dryRun": dryRun, "method": "vision"]
        func fail(_ code: String, _ message: String?, kernel: String = "n/a", outcome: String? = nil) -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            if let message { response["message"] = message }
            audit(request, dryRun: dryRun, kernel: kernel, outcome: outcome ?? code, startedAt: startedAt)
            return response
        }
        guard let point = request.nearPoint else { return fail("missingField", "missing required field \"nearPoint\"") }
        guard let application = AccessibilityTreeWalker.frontmost().application else {
            return fail("noFrontmostApplication", "nothing is frontmost")
        }
        guard !LockScreenGuard.isLockScreen(application.bundleIdentifier) else {
            return fail("screenIsLocked", "the screen is locked — there is nothing of the user's to click")
        }
        // (d) Only in the app the caller expects (the one named, or the one in front).
        if let refusal = frontmostChangedRefusal(request, name: application.localizedName, bundleIdentifier: application.bundleIdentifier,
                                                 dryRun: dryRun, startedAt: startedAt) {
            return response.merging(refusal) { _, new in new }
        }
        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let topLeft = SyntheticScroller.topLeftCentre(ofAppKitFrame: CGRect(origin: point, size: .zero), primaryDisplayHeightInPoints: primaryHeight)

        // (e) The app's focused window is what is drawn at the point: nothing covers it.
        let windowFrame: CGRect
        switch HarnessHands.visionWindow(atTopLeft: topLeft, processIdentifier: application.processIdentifier) {
        case .failure(let refusal): return fail(refusal.code, refusal.message)
        case .success(let frame): windowFrame = frame
        }
        guard windowFrame.contains(point) else {
            return fail("targetNotOnScreen", "the point is outside the app's focused window; nothing was clicked")
        }
        // (a) AX first, by the hit test's own snap: a control AX can press is pressed by
        // name, never by sight, and a password box is never clicked.
        let screens = DispatchQueue.main.sync { NSScreen.screens.map(\.frame) }
        switch RealtimeScreenHitTest.hit(atAppKitPoint: point, primaryDisplayHeight: primaryHeight, screens: screens) {
        case .refused(let error):
            return fail(error, error == "secureField" ? "that point is a password field; nothing was clicked" : Self.harnessItselfMessage)
        case .element(let candidate, _) where candidate.axCanPress:
            response["axElement"] = candidate.described
            return fail("axElementAtPoint", "AX names \(candidate.described) at that point; press it by that name instead. Nothing was clicked.")
        default:
            break
        }

        // (b) The words at the point, from a capture that passed every guard `look` has.
        let crop = HarnessHands.visionCropRegion(around: point, window: windowFrame)
        let captured = escalationPayload(plan: EscalationPlan(tier: .element, reason: "the words drawn at the point", region: crop,
                                                              resolver: "visionClick", candidates: [], application: application),
                                         capture: true)
        if let code = captured.errorCode {
            return fail(code, (captured.payload["message"] as? String) ?? "the region could not be photographed; nothing was clicked")
        }
        guard let path = captured.payload["imagePath"] as? String, let jpeg = FileManager.default.contents(atPath: path),
              let region = RealtimeScreenVerbs.frame(captured.payload["region"]) else {
            return fail("captureFailed", "the photograph of the region could not be read back; nothing was clicked")
        }
        let ocrStartedAt = Date()
        let lines = ScreenOCR.recognize(jpeg: jpeg, region: region)
        response["ocrMilliseconds"] = elapsedMilliseconds(since: ocrStartedAt)
        response["ocrLineCount"] = lines.count
        let label = request.title
        var read: (text: String, frame: CGRect)?
        if !label.isEmpty {
            switch ScreenOCR.witness(lines: lines, point: point, label: label) {
            case .matched(let text, let frame): read = (text, frame)
            case .mismatch(let text):
                response["ocrText"] = text
                return fail("visionLabelMismatch", "the words drawn at that point read \(UntrustedText(text).forDisplay), not "
                    + "\(UntrustedText(label).forDisplay); nothing was clicked")
            case .noText: break
            }
        } else if let word = ScreenOCR.wordBox(at: point, in: lines) {
            read = (ScreenOCR.line(holding: word, in: lines)?.text ?? word.text, word.frame)
        }
        // (c) No words: only the owner's own pointer, still there, says what it is.
        let ownerPointerHolds = request.ownerPointed && HarnessHands.mouseIsNear(topLeft: topLeft)
        guard read != nil || ownerPointerHolds else {
            return fail("visionNoText", request.ownerPointed
                ? "no words are drawn at that point and the owner's pointer has moved off it; nothing was clicked"
                : "no words could be read at that point, so nothing confirms what it is; nothing was clicked")
        }
        response["ocrText"] = read?.text ?? NSNull()
        response["witness"] = read != nil ? "ocr" : "ownerPointer"

        // The kernel judges what was read; the owner's pointer with no words is the owner's choice.
        let decision = read.map {
            HarnessHands.visionClickDecision(ocrText: $0.text, label: label.isEmpty ? nil : label, frame: $0.frame, windowFrame: windowFrame)
        } ?? .allow
        let composed = applyAppPolicy(to: decision, bundleIdentifier: application.bundleIdentifier, into: &response)
        let gated = gate(composed, request: request, appName: application.localizedName, bundleIdentifier: application.bundleIdentifier,
                         dryRun: dryRun, into: &response)
        guard gated.executable else { return fail(gated.outcome, gated.note, kernel: gated.decision) }
        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: gated.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        // Act, then look. Hover first, so a hover highlight is in BOTH pictures and only
        // the click's own change counts. These pictures never leave this function.
        guard let display = EscalationLadder.display(holding: region, among: EscalationLadder.displays()) else {
            return fail("captureFailed", "the region is on no display; nothing was clicked", kernel: gated.decision)
        }
        func grey() -> [UInt8] {
            guard case .success(let outcome) = EscalationLadder.captureSynchronously(
                region: region, on: display, processIdentifier: application.processIdentifier) else { return [] }
            return ScreenOCR.greyThumbnail(jpeg: outcome.jpeg)
        }
        phaseTiming.actionStarting()
        HarnessHands.postMouseMove(atTopLeft: topLeft)
        Thread.sleep(forTimeInterval: HarnessHands.visionHoverSettleSeconds)
        let before = grey()
        // Re-checked at the last moment: the owner may have switched apps, or a window come over the point.
        guard HarnessHands.targetIsFrontmost(application.processIdentifier) else {
            phaseTiming.actionReturned()
            return fail(HarnessHands.frontmostChangedRefusal.code, HarnessHands.frontmostChangedRefusal.message, kernel: gated.decision)
        }
        if case .failure(let refusal) = HarnessHands.visionWindow(atTopLeft: topLeft, processIdentifier: application.processIdentifier) {
            phaseTiming.actionReturned()
            return fail(refusal.code, refusal.message, kernel: gated.decision)
        }
        guard HarnessHands.postClick(atTopLeft: topLeft) else {
            phaseTiming.actionReturned()
            return fail("eventCreationFailed", "the click event could not be created; nothing was clicked", kernel: gated.decision)
        }
        phaseTiming.actionReturned()
        response["performed"] = ["status": "sent", "pointTopLeft": Self.pointJSON(topLeft).point]
        var changed = false
        for wait in HarnessHands.visionVerifyWaits where !changed {
            Thread.sleep(forTimeInterval: wait)
            changed = ScreenOCR.changed(before: before, after: grey())
        }
        phaseTiming.verified(walks: 0, path: "pixels")
        guard changed else {
            response["verification"] = ["status": "notObserved", "evidence": "the region's pixels did not change"]
            return fail("notVerified", "the click was sent and nothing in that region changed", kernel: gated.decision, outcome: "notObserved")
        }
        response["verification"] = ["status": "confirmed", "evidence": "the region's pixels changed"]
        response["ok"] = true
        audit(request, dryRun: dryRun, kernel: gated.decision, outcome: "confirmed", startedAt: startedAt)
        return response
    }

    // MARK: menu / menus

    // Both menu verbs report their timing as `menuMilliseconds`, and never as
    // `walkMilliseconds`.
    //
    // The slow-walk anomaly rule keeps a per-app median of *window* walk
    // durations. A menu read is a different population entirely — Finder's
    // window walks in ~112 ms and its menu bar takes 545 ms — so a menu request
    // would both fire the rule and drag the median it is compared against,
    // which is exactly how the cross-app ring poisoned itself before it was
    // keyed per app. `observe` reads only `walkMilliseconds`, so a different
    // key is the whole fix, and menu timings stay visible in the response.

    /// The frontmost app and its menu bar, or nil having already filled in the
    /// refusal and written the audit line.
    private func menuBar(
        for request: HarnessRequest,
        dryRun: Bool,
        startedAt: Date,
        into response: inout [String: Any]
    ) -> (application: NSRunningApplication, bar: AccessibilityMenu.Node)? {

        func fail(_ code: String, _ message: String) {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
        }

        // The same source `snapshotFocusedWindow` reads, and not because
        // `NSWorkspace` lags here — measured 2026-09-11, 0 disagreements in 8
        // runs. It is because the `expectApp` guard below and the menu bar it
        // guards must come from ONE answer; two sources let a race pass the
        // check against one app and read the menu bar of another.
        let frontmostRead = AccessibilityTreeWalker.frontmost()
        guard let application = frontmostRead.application else {
            fail("noFrontmostApplication", "nothing is frontmost")
            return nil
        }
        // Same guard the walker has. A locked screen makes loginwindow
        // frontmost, and its menu bar is a believable, wrong answer.
        guard !LockScreenGuard.isLockScreen(application.bundleIdentifier) else {
            fail("screenIsLocked", "the screen is locked — there is no menu bar of the user's to read")
            return nil
        }
        // Measured 2026-09-11: after a confirmed `focus Finder`, `menu` read
        // Claude Desktop's bar. Checked before one menu item is read.
        if let refusal = frontmostChangedRefusal(
            request, name: application.localizedName, bundleIdentifier: application.bundleIdentifier,
            dryRun: dryRun, startedAt: startedAt
        ) {
            response.merge(refusal) { _, new in new }
            return nil
        }
        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"
        response["frontmostSource"] = frontmostRead.source.rawValue

        guard let bar = AccessibilityMenu.menuBarNode(for: application) else {
            fail("noMenuBar", "the application publishes no AXMenuBar")
            return nil
        }
        return (application, bar)
    }

    /// The wire form of a failed path step, or nil when it resolved.
    private static func menuResolutionFailure(
        _ resolution: AccessibilityMenu.Resolution
    ) -> (code: String, payload: [String: Any])? {
        switch resolution {
        case .resolved:
            return nil
        case .notFound(let atStep, let step, let available):
            return ("notFound", [
                "status": "notFound",
                "atStep": atStep,
                "step": step,
                // What WAS at that level. Without this a miss is not actionable:
                // the caller cannot tell a typo from a menu that is not there.
                "available": available.map { UntrustedText($0).forDisplay }
            ])
        case .ambiguous(let atStep, let step, let matchCount):
            return ("ambiguous", [
                "status": "ambiguous", "atStep": atStep, "step": step, "matchCount": matchCount
            ])
        case .emptyPath:
            return ("missingField", ["status": "emptyPath"])
        }
    }

    static let maximumSubmenuLabelsListed = 5

    private func menuResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "dryRun": dryRun, "confirmed": request.confirmed, "path": request.path
        ]
        guard let (application, bar) = menuBar(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        // Only the path is read — six or seven levels, not the 300-item bar.
        let resolveStartedAt = Date()
        let (node, resolution) = AccessibilityMenu.resolveNode(
            path: request.path, from: bar, children: AccessibilityMenu.liveChildren
        )
        response["menuMilliseconds"] = Int(Date().timeIntervalSince(resolveStartedAt) * 1000)

        if let failure = Self.menuResolutionFailure(resolution) {
            response["resolution"] = failure.payload
            response["ok"] = false
            response["error"] = failure.code
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: failure.code, startedAt: startedAt)
            return response
        }
        guard let node else {
            response["ok"] = false
            response["error"] = "notFound"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
            return response
        }

        let resolvedNode = AccessibilityMenu.elementNode(for: node)
        // Pressing a submenu PARENT starts menu tracking, and there is no
        // structural way back out — `AXCancel` is inert (measured 2026-09-12) and
        // keystrokes are forbidden. Refused before the press; the leaves are listed.
        if let childLabels = AccessibilityMenu.submenuChildLabels(of: node, children: AccessibilityMenu.liveChildren) {
            response["resolution"] = [
                "status": "targetIsSubmenu", "matchCount": 1, "hasSubmenu": true,
                "available": childLabels.prefix(Self.maximumSubmenuLabelsListed).map { UntrustedText($0).forDisplay }
            ]
            response["ok"] = false
            response["error"] = "targetIsSubmenu"
            response["message"] = "\(request.path.joined(separator: " > ")) has a submenu; name a leaf item, e.g. "
                + "\(request.path.joined(separator: " > ")) > \(childLabels.first ?? "<unlabelled>")"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "targetIsSubmenu", startedAt: startedAt)
            return response
        }
        response["resolution"] = [
            "status": "resolved", "matchCount": 1,
            "enabled": node.isEnabled,
            "hasSubmenu": false,
            "shortcut": (node.shortcut ?? NSNull()) as Any
        ]
        response["resolved"] = Self.summarise(resolvedNode)

        let intent = ElementActionIntent(role: nil, title: node.label ?? "", action: .menu)
        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluate(
                intent: intent,
                resolvedNode: resolvedNode,
                matchCount: 1,
                // A closed menu item is not drawn, so there are no visible bounds
                // for it to be inside. `.infinite` says that honestly: the frame
                // checks do not run for `.menu`, and if they ever did again, a
                // degenerate frame would still be refused while a real one passes.
                visibleBounds: .infinite,
                menuItemEnabled: node.isEnabled
            ),
            bundleIdentifier: application.bundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        // A menu item acts on the frontmost window's selection ("Move to Bin").
        let gated = gate(decision, request: request, appName: application.localizedName,
                         bundleIdentifier: application.bundleIdentifier, dryRun: dryRun,
                         bindingSubject: ActionBinding.Subject(
                            targetElement: resolvedNode.accessibilityElement, processIdentifier: application.processIdentifier
                         ),
                         into: &response)

        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        guard let element = resolvedNode.accessibilityElement else {
            response["ok"] = false
            response["error"] = "noLiveElement"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
            return response
        }

        // Two independent baselines, because either one alone is blind here.
        // The named-element fingerprint cannot see `File > New Finder Window` —
        // two Finder windows on the same folder publish the same names — and
        // the window count cannot see anything that is not a window.
        let windowsBefore = AccessibilityMenu.windowCount(for: application)
        let namesBefore = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?
            .rootNode.map(AccessibilityDumpRunner.namedElementFingerprint)
        response["windowsBefore"] = (windowsBefore ?? NSNull()) as Any

        // Pressing works with the menu **closed**, and leaves nothing open on
        // screen. Measured 2026-09-10 over this socket: File > New Finder Window
        // returned AXError 0 and took Finder from 2 AX windows to 3, and
        // `AXSelected` on all eight of Finder's menu bar items read false both
        // before and after — no menu was opened, so none had to be dismissed.
        phaseTiming.actionStarting()
        let result = AccessibilityActionPerformer.perform(kAXPressAction, on: element)
        phaseTiming.actionReturned()
        response["performed"] = [
            "status": result.error == .success ? "sent" : "failed",
            "axErrorRawValue": result.error.rawValue,
            "milliseconds": result.milliseconds,
            "hasSubmenu": false
        ]
        guard result.error == .success else {
            response["ok"] = false
            response["error"] = "performFailed"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "performFailed", startedAt: startedAt)
            return response
        }

        // A menu works with no window open, and then "no focused window" after
        // the press is not a window that closed. See `ActionVerifier.verify`.
        // Count before walking — see `ActionVerifier.pollCountingWindowsFirst`.
        let windowCountMoved = {
            if let windowsBefore, AccessibilityMenu.windowCount(for: application) != windowsBefore { return true }
            return false
        }
        let (verification, verifyWalks) = ActionVerifier.pollCountingWindowsFirst(
            locate: AccessibilityTreeWalker.focusedWindowTarget,
            windowCountMoved: windowCountMoved,
            walk: { try AccessibilityTreeWalker.snapshotFocusedWindow($0) },
            hadFocusedWindowBefore: namesBefore != nil
        ) { laterSnapshot in
            if windowCountMoved() { return true }
            guard let laterRoot = laterSnapshot.rootNode, let namesBefore else { return false }
            return AccessibilityDumpRunner.namedElementFingerprint(in: laterRoot) != namesBefore
        }
        phaseTiming.verified(walks: verifyWalks, path: "poll")

        switch verification {
        case .confirmed(let milliseconds):
            // Either baseline can confirm here, so say which one did.
            let windowsAfter = AccessibilityMenu.windowCount(for: application)
            response["verification"] = [
                "status": "confirmed",
                "evidence": windowsBefore != nil && windowsAfter != windowsBefore
                    ? "the window count changed" : "named elements changed",
                "milliseconds": milliseconds,
                "windowsAfter": (windowsAfter ?? NSNull()) as Any
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .windowGone(let milliseconds):
            // Measured 2026-09-11: TextEdit File > Close on its last window. The
            // count-change check never ran — every poll threw before reaching it.
            response["verification"] = [
                "status": "confirmed",
                "evidence": "the focused window closed",
                "milliseconds": milliseconds,
                "appeared": [String](),
                "windowsAfter": (AccessibilityMenu.windowCount(for: application) ?? NSNull()) as Any
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .notObserved(let milliseconds):
            response["verification"] = [
                "status": "notObserved",
                "milliseconds": milliseconds,
                "windowsAfter": (AccessibilityMenu.windowCount(for: application) ?? NSNull()) as Any
            ]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
        case .couldNotReadWindow:
            response["verification"] = ["status": "couldNotReadWindow"]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "couldNotReadWindow", startedAt: startedAt)
        }
        return response
    }

    /// The list of what this app can currently be asked to do.
    ///
    /// A screenshot structurally cannot provide it — a closed menu shows
    /// nothing — and it is the thing a planner needs before it can plan.
    private func menusResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = ["pathPrefix": request.path]
        guard let (application, bar) = menuBar(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }
        if let reason = HarnessPolicy.modelReadRefusal(forModel: request.forModel, bundleIdentifier: application.bundleIdentifier,
                                                       policy: loadedPolicy) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "policyRefused", startedAt: startedAt)
            return ["ok": false, "error": "policyRefused", "message": reason]
        }

        // The prefix genuinely scopes the read: resolve it one level at a time,
        // then enumerate from there. Never list 591 items and filter.
        var startNode = bar
        if !request.path.isEmpty {
            let (node, resolution) = AccessibilityMenu.resolveNode(
                path: request.path, from: bar, children: AccessibilityMenu.liveChildren
            )
            if let failure = Self.menuResolutionFailure(resolution) {
                response["resolution"] = failure.payload
                response["ok"] = false
                response["error"] = failure.code
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: failure.code, startedAt: startedAt)
                return response
            }
            guard let node else {
                response["ok"] = false
                response["error"] = "notFound"
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return response
            }
            startNode = node
        }

        let listing = AccessibilityMenu.list(
            from: startNode,
            pathSoFar: request.path,
            children: AccessibilityMenu.liveChildren,
            deadline: Date().addingTimeInterval(AccessibilityMenu.listingTimeLimitInSeconds)
        )

        // Truncation is a banner above the counts, never a flag beside them.
        if !listing.stopReasons.isEmpty {
            response["warning"] = "THESE COUNTS ARE A FLOOR, NOT A MEASUREMENT — the listing stopped early: "
                + listing.stopReasons.joined(separator: ", ")
        }
        response["listingStopReasons"] = listing.stopReasons
        response["menuMilliseconds"] = listing.milliseconds
        response["itemCount"] = listing.items.count
        response["enabledCount"] = listing.items.filter(\.isEnabled).count
        response["withShortcutCount"] = listing.items.filter { $0.shortcut != nil }.count
        // Paths are raw so a caller can feed one straight back into `menu`.
        // JSON encoding is the escaping, exactly as in `summarise`.
        response["items"] = listing.items.map {
            [
                "path": $0.path,
                "role": $0.role,
                "enabled": $0.isEnabled,
                "shortcut": $0.shortcut ?? NSNull(),
                "hasSubmenu": $0.hasSubmenu,
                "marked": $0.isMarked
            ] as [String: Any]
        }
        response["ok"] = true
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)
        return response
    }

    // MARK: windows / focus

    // Both window verbs report their timing as `focusMilliseconds`, never as
    // `walkMilliseconds` — for the reason spelled out in full above
    // `// MARK: menu / menus`. A window-list read is a third population and
    // `observe` keys the slow-walk median on `walkMilliseconds` alone.

    /// The application both verbs act on: the one named, or the frontmost.
    /// Returns nil having already filled in the refusal and written the audit
    /// line, exactly like `menuBar(for:)`.
    private func targetApplication(
        for request: HarnessRequest,
        dryRun: Bool,
        startedAt: Date,
        into response: inout [String: Any]
    ) -> NSRunningApplication? {

        func fail(_ code: String, _ message: String, extra: [String: Any] = [:]) {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            for (key, value) in extra { response[key] = value }
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
        }
        // `focus` would bring the panel forward, `windows` read it: see `frontmostChangedRefusal`.
        func unlessHarnessItself(_ application: NSRunningApplication) -> NSRunningApplication? {
            guard Self.isHarnessItself(bundleIdentifier: application.bundleIdentifier) else { return application }
            fail("targetIsHarnessItself", Self.harnessItselfMessage)
            return nil
        }

        // Same guard the walker and the menu path have. A locked screen makes
        // loginwindow frontmost, and its one window is a believable, wrong
        // answer that this project has already recorded as data three times.
        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            fail("screenIsLocked", "the screen is locked — there are no windows of the user's to read or raise")
            return nil
        }

        let candidates = AccessibilityWindows.runningApplications()

        guard let query = request.app else {
            guard let frontmost = AccessibilityTreeWalker.focusedApplication() else {
                fail("noFrontmostApplication", "nothing is frontmost")
                return nil
            }
            return unlessHarnessItself(frontmost)
        }

        switch AccessibilityWindows.matchApplication(query, among: candidates.map(\.candidate)) {
        case .resolved(let index, let tier):
            response["applicationMatchedOn"] = tier.rawValue
            return unlessHarnessItself(candidates[index].application)
        case .notFound(let available):
            fail(
                "notFound",
                "no running application matches \(UntrustedText(query).forDisplay)",
                // What WAS running. Without it a miss is not actionable — the
                // caller cannot tell a typo from an app that is not open.
                extra: ["available": available.map { UntrustedText($0).forDisplay }]
            )
            return nil
        case .ambiguous(let matchCount, let tier):
            fail(
                "ambiguous",
                "\(matchCount) running applications match \(UntrustedText(query).forDisplay) on \(tier.rawValue)",
                extra: ["matchCount": matchCount]
            )
            return nil
        }
    }

    /// The wire form of one running application. `NSWorkspace` only — no AX
    /// reads, so this list is nearly free, and it is how a caller finds out what
    /// it could focus in the first place.
    private static func summariseApplication(
        _ candidate: AccessibilityWindows.ApplicationCandidate
    ) -> [String: Any] {
        [
            "name": (candidate.localizedName ?? NSNull()) as Any,
            "bundleIdentifier": (candidate.bundleIdentifier ?? NSNull()) as Any,
            "active": candidate.isActive,
            "hidden": candidate.isHidden
        ]
    }

    /// The wire form of one window. Frames are already AppKit — converted in
    /// `liveWindows`, at the one boundary where AX's top-left origin meets
    /// AppKit's bottom-left.
    private static func summariseWindow(
        _ candidate: AccessibilityWindows.WindowCandidate
    ) -> [String: Any] {
        var entry: [String: Any] = [
            // Raw, because JSON encoding is the escaping — same rule as
            // `summarise`. The plausibility flag travels beside it.
            "title": (candidate.title?.raw ?? NSNull()) as Any,
            "titleIsPlausibleLabel": candidate.title?.isPlausibleControlLabel ?? false,
            "role": candidate.role,
            "subrole": (candidate.subrole ?? NSNull()) as Any,
            "main": candidate.isMain,
            "minimized": candidate.isMinimized,
            "actions": candidate.publishedActionNames
        ]
        Self.attachFrame(candidate.frameInAppKitCoordinates, to: &entry)
        return entry
    }

    private func windowsResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [:]
        guard let application = targetApplication(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"

        // The one guard here that is a separate lookup from the app it reads, and
        // it has to be: kAXWindows is Space-scoped, so what this list can contain
        // is decided by whichever app is in front. Measured 2026-09-11: `focus
        // Finder` confirmed, Claude took focus back 0.9 s later, and `windows
        // Finder` listed 0 windows from Claude's full-screen Space (1 from Finder's)
        // — a planner checker counted that as the baseline and failed the task.
        let frontmost = AccessibilityTreeWalker.focusedApplication()
        if let refusal = frontmostChangedRefusal(
            request, name: frontmost?.localizedName, bundleIdentifier: frontmost?.bundleIdentifier,
            dryRun: dryRun, startedAt: startedAt
        ) { return response.merging(refusal) { _, new in new } }

        let readStartedAt = Date()
        let read = AccessibilityWindows.liveWindows(for: application)
        response["focusMilliseconds"] = Int(Date().timeIntervalSince(readStartedAt) * 1000)

        response["windowCount"] = read.windows.count
        response["windows"] = read.windows.map { Self.summariseWindow($0.candidate) }
        response["applications"] = AccessibilityWindows.runningApplications()
            .map { Self.summariseApplication($0.candidate) }

        // A count of zero is only a fact if the read worked. This is the one
        // field that separates "this app has no windows" from "this app did not
        // answer", and without it both print as `windowCount: 0`.
        response["windowListRead"] = read.readSucceeded ? "ok" : "failed"
        response["windowListErrorRawValue"] = read.error.rawValue
        // Zero windows from a *successful* read is still not "this app has no
        // windows" — kAXWindows is Space-scoped, measured 2026-09-10. Say so
        // where the count is, not in a footnote.
        if read.readSucceeded, read.windows.isEmpty, frontmost?.processIdentifier != application.processIdentifier {
            response["warning"] = "ZERO IS NOT A MEASUREMENT — \(application.localizedName ?? "this app") "
                + "is not the active application, and kAXWindows only lists windows on the active Space. "
                + "Focus the app and read again before concluding it has no windows."
        }
        if !read.readSucceeded {
            response["warning"] = "WINDOW COUNT IS NOT A MEASUREMENT — "
                + "kAXWindows failed with AXError \(read.error.rawValue); the list below is empty "
                + "because the read did not answer, not because the app has no windows"
        }
        response["ok"] = read.readSucceeded
        if !read.readSucceeded { response["error"] = "windowListUnreadable" }
        audit(
            request, dryRun: dryRun, kernel: "n/a",
            outcome: read.readSucceeded ? "ok" : "windowListUnreadable", startedAt: startedAt
        )
        return response
    }

    private func focusResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "dryRun": dryRun, "confirmed": request.confirmed,
            "app": (request.app ?? NSNull()) as Any,
            "title": request.title.isEmpty ? NSNull() : request.title
        ]

        // Captured BEFORE anything moves. Focus is the one verb the human can
        // undo trivially, and this is what tells them how.
        if let previous = AccessibilityWindows.previousApplication() {
            response["previousApplication"] = [
                "name": (previous.name ?? NSNull()) as Any,
                "bundleIdentifier": (previous.bundleIdentifier ?? NSNull()) as Any
            ]
        }

        guard let application = targetApplication(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"

        // Judged before the window read, because reading a window on another
        // Space activates the app — a refused app must never come forward.
        let appDecision = applyAppPolicy(to: .allow, bundleIdentifier: application.bundleIdentifier, into: &response)
        let appGate = gate(appDecision, request: request, appName: application.localizedName,
                           bundleIdentifier: application.bundleIdentifier, dryRun: dryRun, into: &response)
        guard appGate.executable else {
            response["ok"] = false
            response["error"] = appGate.outcome
            audit(request, dryRun: dryRun, kernel: appGate.decision, outcome: appGate.outcome, startedAt: startedAt)
            return response
        }

        // A title-less focus is an app activation, and reading the window list
        // is then only worth it to say which window ends up in front — which
        // the observation tier reports anyway. So it is read either way, once.
        let readStartedAt = Date()
        var read = AccessibilityWindows.liveWindows(for: application)

        // A window on another Space is invisible to kAXWindows, so resolving a
        // title against an empty list would report `notFound` for a window that
        // is merely elsewhere. Bringing the app forward IS the app-level half of
        // this verb — the half the kernel allows unconditionally — so doing it
        // first is the verb's own order, not an escalation past a decision.
        if !request.title.isEmpty, read.windows.isEmpty, !application.isActive {
            let attempt = AccessibilityWindows.activateAndWaitForWindows(application)
            read = attempt.read
            response["activatedToReadWindows"] = [
                "activated": attempt.activated,
                "milliseconds": attempt.milliseconds,
                "windowsThenVisible": attempt.read.windows.count
            ]
        }
        response["focusMilliseconds"] = Int(Date().timeIntervalSince(readStartedAt) * 1000)
        response["windowCount"] = read.windows.count
        response["windowListRead"] = read.readSucceeded ? "ok" : "failed"

        // A title we cannot look for is not a title that is missing. Reporting
        // `notFound` here would tell the caller the window does not exist, on
        // the strength of a read that never happened.
        if !request.title.isEmpty, !read.readSucceeded {
            response["ok"] = false
            response["error"] = "windowListUnreadable"
            response["message"] = "kAXWindows failed with AXError \(read.error.rawValue) — "
                + "cannot tell whether that window exists"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "windowListUnreadable", startedAt: startedAt)
            return response
        }

        var resolvedWindow: (element: AXUIElement, candidate: AccessibilityWindows.WindowCandidate)?
        var matchCount = 1
        var kernelTitle: UntrustedText?

        if !request.title.isEmpty {
            switch AccessibilityWindows.matchWindow(
                title: request.title, nearPoint: request.nearPoint,
                among: read.windows.map(\.candidate)
            ) {
            case .resolved(let index):
                resolvedWindow = read.windows[index]
                kernelTitle = read.windows[index].candidate.title
                response["resolution"] = [
                    "status": "resolved", "matchCount": 1,
                    "title": (read.windows[index].candidate.title?.raw ?? NSNull()) as Any
                ]
            case .notFound(let available):
                response["resolution"] = [
                    "status": "notFound",
                    "available": available.map { UntrustedText($0).forDisplay }
                ]
                response["ok"] = false
                response["error"] = "notFound"
                attachFocusEscalation(
                    to: &response, request: request,
                    windows: read.windows.map(\.candidate), application: application
                )
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return response
            case .ambiguous(let count):
                // Not returned here: the kernel is the thing that refuses an
                // ambiguous target, in this verb as in every other.
                matchCount = count
                kernelTitle = UntrustedText(request.title)
                response["resolution"] = ["status": "ambiguous", "matchCount": count]
            }
        }

        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluateFocus(windowTitle: kernelTitle, matchCount: matchCount),
            bundleIdentifier: application.bundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        let gated = gate(decision, request: request, appName: application.localizedName,
                         bundleIdentifier: application.bundleIdentifier, dryRun: dryRun, into: &response)

        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            // An ambiguous window title is precisely what a picture settles, so
            // this verb gets the ladder too — built from the window list, which
            // is the candidate set it resolves against.
            if matchCount != 1 {
                attachFocusEscalation(
                    to: &response, request: request,
                    windows: read.windows.map(\.candidate), application: application
                )
            }
            audit(request, dryRun: dryRun, kernel: described.decision,
                  outcome: described.decision == "refuse" ? "kernelRefused" : "confirmationRequired",
                  startedAt: startedAt)
            return response
        }

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        phaseTiming.actionStarting()
        let outcome = AccessibilityWindows.focus(application: application, window: resolvedWindow)
        // A title focus on another Space already activated the app to READ its
        // windows (`activatedToReadWindows`), and that sits in resolveMs.
        phaseTiming.actedThenVerified(actMilliseconds: outcome.actMilliseconds,
                                      walks: outcome.observationPolls, path: outcome.observedVia)

        // Every step separately. A raise that was never published, a raise that
        // returned 0, and a window that actually came forward are three
        // different facts, and collapsing them into one boolean is how a write
        // that did nothing gets reported as a success.
        response["performed"] = [
            "unminimized": outcome.unminimized,
            "unminimizeErrorRawValue": (outcome.unminimizeErrorRawValue.map { Int($0) } ?? NSNull()) as Any,
            "raisePublished": outcome.raisePublished,
            "axErrorRawValue": (outcome.raiseErrorRawValue.map { Int($0) } ?? NSNull()) as Any,
            "milliseconds": (outcome.raiseMilliseconds ?? NSNull()) as Any,
            "activated": outcome.activated
        ]
        response["verification"] = [
            "status": outcome.observed ? "confirmed" : "notObserved",
            "readBackMain": (outcome.readBackMain ?? NSNull()) as Any,
            "observed": outcome.observed,
            "milliseconds": outcome.observedMilliseconds,
            "observedApplication": (outcome.observedApplication ?? NSNull()) as Any,
            "observedVia": (outcome.observedVia ?? NSNull()) as Any,
            "observedWindowTitle": (outcome.observedWindowTitle?.raw ?? NSNull()) as Any
        ]

        response["ok"] = outcome.observed
        if !outcome.observed { response["error"] = "notVerified" }
        audit(request, dryRun: dryRun, kernel: described.decision,
              outcome: outcome.observed ? "confirmed" : "notObserved", startedAt: startedAt)
        return response
    }

    // MARK: launch

    // Timing is `launchMilliseconds` and never `walkMilliseconds` — for the
    // reason spelled out above `// MARK: menu / menus`. A launch is seconds of
    // waiting, and in the slow-walk median it would be a poisoned sample.

    private func launchResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "dryRun": dryRun, "confirmed": request.confirmed,
            "app": (request.app ?? NSNull()) as Any
        ]
        func fail(_ code: String, _ message: String, kernel: String = "n/a") -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: kernel, outcome: code, startedAt: startedAt)
            return response
        }

        // `decode` guarantees it; a nil here is our bug, not a default.
        guard let query = request.app else { return fail("missingField", "missing required field \"app\"") }

        // `open -a` cannot launch into a locked session, and a launch that
        // "succeeds" behind the lock screen is a believable, wrong answer.
        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            return fail("screenIsLocked", "the screen is locked — an application cannot be launched into it")
        }

        let url: URL
        let bundleIdentifier: String
        switch ApplicationLauncher.resolve(query) {
        case .resolved(let resolvedURL, let resolvedIdentifier):
            url = resolvedURL
            bundleIdentifier = resolvedIdentifier
        case .notFound:
            return fail("notFound", "no installed application matches \(UntrustedText(query).forDisplay) "
                + "by bundle identifier or exact name in "
                + ApplicationLauncher.searchDirectories.map(\.path).joined(separator: ", "))
        case .ambiguous(let candidates):
            response["candidates"] = candidates.map(\.path)
            return fail("ambiguous", "\(candidates.count) installed applications match \(UntrustedText(query).forDisplay)")
        }
        guard !Self.isHarnessItself(bundleIdentifier: bundleIdentifier) else {
            return fail("targetIsHarnessItself", Self.harnessItselfMessage)
        }
        response["application"] = url.deletingPathExtension().lastPathComponent
        response["bundleIdentifier"] = bundleIdentifier
        response["path"] = url.path

        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluateLaunch(bundleIdentifier: bundleIdentifier),
            bundleIdentifier: bundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        let gated = gate(decision, request: request, appName: url.deletingPathExtension().lastPathComponent,
                         bundleIdentifier: bundleIdentifier, dryRun: dryRun, into: &response)
        guard gated.executable else {
            // Not `fail`: a fresh ticket already wrote its re-issue `message`.
            response["ok"] = false
            response["error"] = gated.outcome
            if response["message"] == nil { response["message"] = gated.note ?? gated.outcome }
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }

        // Read BEFORE launching, and not read again.
        response["alreadyRunning"] = !NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was launched"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        phaseTiming.actionStarting()
        let outcome = ApplicationLauncher.launchAndWait(url)
        // Act is `openApplication` until its callback hands back a process; verify
        // is the AXFrontmost + window wait. No callback means verification never began.
        if let processMilliseconds = outcome.processMilliseconds {
            phaseTiming.actedThenVerified(actMilliseconds: processMilliseconds,
                                          walks: outcome.readinessPolls, path: nil)
        } else {
            phaseTiming.actionReturned()
        }
        response["launchMilliseconds"] = elapsedMilliseconds(since: startedAt)
        response["launch"] = [
            "processMilliseconds": (outcome.processMilliseconds ?? NSNull()) as Any,
            "frontmostMilliseconds": (outcome.frontmostMilliseconds ?? NSNull()) as Any,
            "windowMilliseconds": (outcome.windowMilliseconds ?? NSNull()) as Any,
            // Raw AXError values. -25204 is "still launching", not "refused" —
            // the clock beside it is what separates the two.
            "lastFrontmostError": (outcome.lastFrontmostError.map { Int($0) } ?? NSNull()) as Any,
            "lastWindowError": (outcome.lastWindowError.map { Int($0) } ?? NSNull()) as Any
        ]

        if let launchError = outcome.launchError {
            return fail("launchFailed", launchError, kernel: described.decision)
        }

        response["status"] = outcome.status.rawValue
        switch outcome.status {
        case .ready, .frontmostNoWindow:
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision,
                  outcome: outcome.status.rawValue, startedAt: startedAt)
            return response
        case .notReady:
            // Deliberately not an ordinary refusal: it reaches the flight recorder.
            return fail(
                "launchNotReady",
                "\(bundleIdentifier) never reported AXFrontmost true within "
                    + "\(ApplicationLauncher.launchReadinessDeadlineInSeconds) s"
                    + (outcome.windowMilliseconds != nil ? " — it has a window, so it may have launched behind another app" : ""),
                kernel: described.decision
            )
        }
    }

    // MARK: openURL

    /// Open an http/https page in the named browser or the default one. Allowed
    /// without a card (it reads a page and destroys nothing), but the per-app
    /// policy is asked about the BROWSER, so a refused browser stays refused.
    /// Verified by the browser coming forward with a new or retitled window.
    private func openURLResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = ["dryRun": dryRun, "url": request.url?.absoluteString ?? NSNull()]
        func fail(_ code: String, _ message: String, kernel: String = "n/a") -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: kernel, outcome: code, startedAt: startedAt)
            return response
        }
        // `decode` guarantees it; a nil here is our bug, not a default.
        guard let url = request.url else { return fail("missingField", "missing required field \"url\"") }
        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            return fail("screenIsLocked", "the screen is locked — nothing can be opened into it")
        }

        let browserURL: URL
        if let app = request.app {
            switch ApplicationLauncher.resolve(app) {
            case .resolved(let resolvedURL, _): browserURL = resolvedURL
            case .notFound: return fail("notFound", "no installed application matches \(UntrustedText(app).forDisplay)")
            case .ambiguous(let candidates):
                response["candidates"] = candidates.map(\.path)
                return fail("ambiguous", "\(candidates.count) installed applications match \(UntrustedText(app).forDisplay)")
            }
        } else {
            guard let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                return fail("noBrowser", "no application is set to open http/https pages")
            }
            browserURL = defaultBrowser
        }
        // A web handler, or not a browser at all ("open https://… in Terminal").
        let webHandlers = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        guard HarnessHands.handlesWeb(appURL: browserURL, webHandlers: webHandlers) else {
            return fail("notABrowser", "\(browserURL.deletingPathExtension().lastPathComponent) does not open web pages")
        }
        let bundleIdentifier = Bundle(url: browserURL)?.bundleIdentifier
        guard !Self.isHarnessItself(bundleIdentifier: bundleIdentifier) else {
            return fail("targetIsHarnessItself", Self.harnessItselfMessage)
        }
        let browserName = browserURL.deletingPathExtension().lastPathComponent
        response["application"] = browserName
        response["bundleIdentifier"] = bundleIdentifier ?? NSNull()

        // The address judged like a control's name, a private host asked about (review of H1).
        let decision = applyAppPolicy(to: HarnessHands.openURLDecision(url), bundleIdentifier: bundleIdentifier, into: &response)
        let gated = gate(decision, request: request, appName: browserName, bundleIdentifier: bundleIdentifier,
                         dryRun: dryRun, into: &response)
        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            if response["message"] == nil { response["message"] = gated.note ?? gated.outcome }
            audit(request, dryRun: dryRun, kernel: gated.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }
        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was opened"]
            audit(request, dryRun: dryRun, kernel: gated.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        // Read BEFORE opening: the browser's front window and its title, if it runs.
        let before = bundleIdentifier
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .map { HarnessHands.browserWindow(processIdentifier: $0.processIdentifier) }
        let tabBefore = bundleIdentifier
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .flatMap { HarnessHands.selectedTab(processIdentifier: $0.processIdentifier) }

        phaseTiming.actionStarting()
        let application: NSRunningApplication
        switch HarnessHands.open(url, withApplicationAt: browserURL) {
        case .failure(let refusal):
            phaseTiming.actionReturned()
            return fail(refusal.code, refusal.message, kernel: gated.decision)
        case .success(let opened): application = opened
        }
        phaseTiming.actionReturned()

        var evidence: String?
        var pageHost: String?
        var firstEvidenceAt: Date?
        var polls = 0
        let verifyStartedAt = Date()
        let requestedHost = url.host ?? ""
        HarnessHands.waitUntil(seconds: HarnessHands.openURLDeadlineSeconds) {
            polls += 1
            let after = HarnessHands.browserWindow(processIdentifier: application.processIdentifier)
            let windowChanged = after.window.map { window in before?.window.map { !CFEqual($0, window) } ?? true } ?? false
            // The tab is read only when nothing cheaper moved: it walks the window.
            let tabChanged = !windowChanged && after.title == before?.title && tabBefore != nil
                && HarnessHands.selectedTab(processIdentifier: application.processIdentifier).map { $0 != tabBefore } == true
            evidence = HarnessHands.openURLEvidence(frontmost: after.frontmost, windowChanged: windowChanged, tabChanged: tabChanged,
                                                    titleBefore: before?.title, titleAfter: after.title)
            guard evidence != nil else { return false }
            if let title = after.title { response["title"] = UntrustedText(title).forDisplay }
            // The page's own address names the host: confirmed. A page still loading gets a moment more.
            pageHost = after.window.flatMap(HarnessHands.pageHost(inWindow:))
            if let pageHost, HarnessHands.hostMatches(page: pageHost, requested: requestedHost) { return true }
            if firstEvidenceAt == nil { firstEvidenceAt = Date() }
            return Date().timeIntervalSince(firstEvidenceAt!) >= HarnessHands.openURLHostGraceSeconds
        }
        phaseTiming.verified(walks: polls, path: "poll")
        response["performed"] = ["status": "sent", "browserWasRunning": before != nil]
        let status = HarnessHands.openURLVerification(evidence: evidence, pageHost: pageHost, requestedHost: requestedHost)
        var verification: [String: Any] = ["status": status, "milliseconds": Int(Date().timeIntervalSince(verifyStartedAt) * 1000)]
        if let evidence { verification["evidence"] = evidence }
        response["verification"] = verification
        switch status {
        case "notObserved":
            return fail("notVerified", "the browser did not come forward with a new or retitled window within "
                        + "\(Int(HarnessHands.openURLDeadlineSeconds)) s", kernel: gated.decision)
        case "pageHostDiffers":
            response["pageHost"] = UntrustedText(pageHost ?? "").forDisplay
            return fail("pageHostDiffers", "the browser came forward, but its page is on another site", kernel: gated.decision)
        default:
            break
        }
        response["ok"] = true
        audit(request, dryRun: dryRun, kernel: gated.decision, outcome: "confirmed", startedAt: startedAt)
        return response
    }

    // MARK: look / escalation

    // Capture timing is reported as `captureMilliseconds` and NEVER as
    // `walkMilliseconds` — for exactly the reason spelled out in full above
    // `// MARK: menu / menus`. A capture is a fourth population (fixed ~344 ms,
    // measured 2026-09-08) and `observe` keys its per-app slow-walk median on
    // `walkMilliseconds` alone. A `look` still reports the *tree walk* it did as
    // `walkMilliseconds`, because that one really is a window walk of the same
    // window every other verb measures.
    //
    // The secure-field inspection before a capture is `inspectMilliseconds`,
    // for the same reason: it walks every window of the app that touches the
    // region — one or several, background ones included — so it is a fifth
    // population, and a multi-window total in `walkMilliseconds` would poison
    // the per-app median.

    /// Which rung, over what rectangle, showing what.
    private struct EscalationPlan {
        let tier: EscalationLadder.Tier
        let reason: String
        let region: CGRect
        /// Which resolver these candidates — and therefore these suggested
        /// points — belong to.
        ///
        /// Measured 2026-09-10, and it is a trap that returned a plausible
        /// wrong answer: `press` resolves names in the focused window's tree,
        /// where "Recent" matched one AXWindow and two sidebar AXStaticTexts,
        /// so the separating point was computed against those three. `focus`
        /// resolves the same word against the app's **window list**, where
        /// "Recent" matched two windows — and that point sits inside both.
        /// Re-issuing it came straight back ambiguous. A separating point is
        /// only valid within the candidate set it was computed from, so the
        /// set has to travel with it.
        let resolver: String
        /// What a caller would have to choose between.
        let candidates: [AccessibilityElementNode]
        /// The one application a capture may photograph, and whose windows the
        /// secure-field check walks first. Nil when none could be named — and
        /// then nothing is photographed, never the whole display instead.
        let application: NSRunningApplication?
    }

    /// The rectangle a display tier would cover: the display holding the
    /// window, else the one holding the cursor, else the first one.
    private static func fallbackDisplayFrame(
        forWindowFrame windowFrame: CGRect?,
        among displays: [EscalationLadder.DisplayInfo]
    ) -> CGRect? {
        if let windowFrame, windowFrame.width > 0, windowFrame.height > 0,
           let display = EscalationLadder.display(holding: windowFrame, among: displays) {
            return display.appKitFrame
        }
        let cursor = cursorLocationInAppKitCoordinates()
        return displays.first(where: { display in cursor.map { display.appKitFrame.contains($0) } ?? false })?.appKitFrame
            ?? displays.first?.appKitFrame
    }

    /// `NSEvent.mouseLocation` without AppKit, which wants main: a null-source
    /// `CGEvent` reads the same cursor in CG's TOP-left space, flipped here
    /// against the display at (0, 0) into AppKit's bottom-left.
    nonisolated static func cursorLocationInAppKitCoordinates() -> CGPoint? {
        guard let topLeft = CGEvent(source: nil)?.location else { return nil }
        return CGPoint(x: topLeft.x, y: CGDisplayBounds(CGMainDisplayID()).height - topLeft.y)
    }

    private func escalationPlan(
        forcedTier: EscalationLadder.Tier?,
        title: String,
        role: String?,
        rootNode: AccessibilityElementNode?,
        application: NSRunningApplication?
    ) -> EscalationPlan? {
        let displays = EscalationLadder.displays()
        let allNodes = rootNode?.flattenedDescendants() ?? []
        let candidates = (rootNode.map { root in
            title.isEmpty ? [] : EscalationLadder.namedCandidates(in: root, title: title, role: role)
        }) ?? []

        let choice = EscalationLadder.chooseTier(
            forcedTier: forcedTier,
            candidateFrames: candidates.map(\.frameInAppKitCoordinates),
            windowFrame: rootNode?.frameInAppKitCoordinates,
            windowActionableCount: allNodes.filter(\.isActionable).count
        )

        let region: CGRect?
        switch choice.tier {
        case .element:
            region = EscalationLadder.region(forCandidateFrames: candidates.map(\.frameInAppKitCoordinates))
        case .window:
            region = rootNode?.frameInAppKitCoordinates
        case .display, .none:
            region = Self.fallbackDisplayFrame(
                forWindowFrame: rootNode?.frameInAppKitCoordinates, among: displays
            )
        }
        guard let region, region.width > 0, region.height > 0 else { return nil }

        return EscalationPlan(
            tier: choice.tier,
            reason: choice.reason,
            region: region,
            resolver: "elementName",
            // On the window and display rungs nothing was named, so the useful
            // list is what a caller could name instead.
            candidates: choice.tier == .element ? candidates : Self.regionCandidates(in: rootNode, region: region),
            application: application
        )
    }

    /// The window and display rungs' "what you could name instead": actionable
    /// nodes touching the region, never inside a text input or a secure field —
    /// these reach the socket, the flight-recorder ring and anomaly dumps.
    static func regionCandidates(in rootNode: AccessibilityElementNode?, region: CGRect) -> [AccessibilityElementNode] {
        (rootNode?.wireDescendants() ?? []).filter { $0.isActionable && $0.frameInAppKitCoordinates.intersects(region) }
    }

    /// How many candidates a payload will describe.
    ///
    /// The window and display rungs answer "what could you have named instead",
    /// which on a rich app is everything actionable — measured 2026-09-10,
    /// Claude Desktop's window returned **110**. That is a large response, and
    /// the separating-point search is quadratic in it: each candidate cuts its
    /// frame at every other candidate's edges, so 110 candidates build a
    /// 221x221 arrangement each, 5.4 million points across the list. Forty is
    /// past the point where a caller reads them anyway.
    static let maximumCandidates = 40

    /// Hang the ladder off a failed `focus`, free unless the caller asked to pay.
    private func attachFocusEscalation(
        to response: inout [String: Any],
        request: HarnessRequest,
        windows: [AccessibilityWindows.WindowCandidate],
        application: NSRunningApplication
    ) {
        guard let plan = windowEscalationPlan(
            title: request.title, windows: windows, application: application
        ) else { return }
        let result = escalationPayload(plan: plan, capture: request.escalate)
        var payload = result.payload
        payload["available"] = true
        if !request.escalate {
            payload["hint"] = "re-issue with \"escalate\": true for an image and candidate points"
        }
        response["escalation"] = payload
    }

    /// The same ladder, built from an app's **window list** instead of a window's
    /// element tree — the candidate set `focus` actually resolves against.
    ///
    /// Windows are turned into `AccessibilityElementNode`s rather than given a
    /// parallel summariser: they have a role, a name, a frame and a published
    /// action list, which is everything the candidate machinery reads.
    private func windowEscalationPlan(
        title: String,
        windows: [AccessibilityWindows.WindowCandidate],
        application: NSRunningApplication
    ) -> EscalationPlan? {
        func node(_ candidate: AccessibilityWindows.WindowCandidate) -> AccessibilityElementNode {
            AccessibilityElementNode(
                role: candidate.role, subrole: candidate.subrole,
                title: candidate.title?.raw, value: nil,
                frameInAppKitCoordinates: candidate.frameInAppKitCoordinates,
                depth: 0, children: [],
                publishedActionNames: candidate.publishedActionNames
            )
        }

        let lowercased = title.lowercased()
        let matching = windows.filter { $0.title?.raw.lowercased() == lowercased }
        let shown = matching.isEmpty ? windows : matching
        let candidates = shown.map(node)
        guard let region = EscalationLadder.region(
            forCandidateFrames: candidates.map(\.frameInAppKitCoordinates)
        ) else { return nil }

        return EscalationPlan(
            tier: .element,
            reason: matching.isEmpty
                ? "no window matched that title; the region is the union of the app's \(windows.count) window(s)"
                : "\(matching.count) window(s) matched that title; the region is the union of their frames padded",
            region: region,
            resolver: "windowTitle",
            candidates: candidates,
            // The resolved app. `focus` has already brought it forward when its
            // windows were Space-hidden, so a capture can walk them — and a
            // window read that still fails is a refusal, not a pass.
            application: application
        )
    }

    /// The candidate list, each entry carrying a point that provably picks it
    /// out — or saying that no point does.
    ///
    /// Plausibly-named candidates come first, because a name is the only thing
    /// a caller can re-issue the intent with; an anonymous element in this list
    /// is context, not an option.
    private static func summariseCandidates(_ all: [AccessibilityElementNode]) -> [[String: Any]] {
        let named = all.filter { $0.listedName?.isPlausibleControlLabel == true }
        let anonymous = all.filter { $0.listedName?.isPlausibleControlLabel != true }
        let nodes = Array((named + anonymous).prefix(maximumCandidates))
        let frames = nodes.map(\.frameInAppKitCoordinates)
        return nodes.indices.map { index in
            var entry = summarise(nodes[index])
            entry["index"] = index
            let point = EscalationLadder.separatingPoint(forCandidateAt: index, among: frames)
            if let point {
                let (json, invalid) = pointJSON(point)
                entry["suggestedPoint"] = json
                if invalid { entry["pointInvalid"] = true }
            } else {
                entry["suggestedPoint"] = NSNull()
            }
            // Never omitted, and never a "nearest" fallback: `false` is the
            // answer that stops a caller re-issuing a point that will only come
            // back ambiguous again.
            entry["separable"] = point != nil
            return entry
        }
    }

    /// The whole payload, shared by `look` (where it is the response) and the
    /// acting verbs (where it hangs under `escalation`).
    private func escalationPayload(
        plan: EscalationPlan,
        capture: Bool
    ) -> (payload: [String: Any], errorCode: String?) {
        var payload: [String: Any] = [
            "tier": plan.tier.rawValue,
            "reason": plan.reason,
            // A suggested point below is only re-issuable to the verb that
            // resolves this way. See `EscalationPlan.resolver`.
            "resolver": plan.resolver
        ]

        guard capture else {
            // The free half, and it is free in bytes as well as in time: which
            // rung and why, nothing else. A capture costs ~344 ms (measured
            // 2026-09-08), so making every `notFound` pay for one silently
            // would turn a 12 ms refusal into a 350 ms one for callers that
            // never wanted a picture — and a candidate list here would put a
            // whole window's actionable elements into every failed press.
            payload["hint"] = "re-issue with \"escalate\": true for an image and candidate points"
            return (payload, nil)
        }

        Self.attachFrame(plan.region, to: &payload, key: "region")
        // The true total, always — the list below may be shorter. A count that
        // silently equalled the list length would be the truncation defect this
        // project already paid for once, in a new place.
        payload["candidateCount"] = plan.candidates.count
        let listed = Self.summariseCandidates(plan.candidates)
        payload["candidates"] = listed
        if listed.count < plan.candidates.count {
            payload["candidatesTruncated"] = true
            payload["warning"] = "THIS LIST IS A FLOOR, NOT A MEASUREMENT — showing \(listed.count) "
                + "of \(plan.candidates.count) candidates, named ones first"
        }

        // Inspect first, then photograph — and the camera may only see what was
        // inspected. Every window of the one app the capture includes that
        // touches the region is walked here, before the shutter; a refusal that
        // arrives once the JPEG is on disk is not a refusal. There is no path
        // below that photographs without a complete check.
        // Any verb's escalation photograph too, not only `look`.
        let secureInput = secureInputRead()
        guard !secureInput.isOn else {
            payload["message"] = HarnessPolicy.handOverMessage(secureInput)
            return (payload, "handOver")
        }
        guard let application = plan.application else {
            payload["message"] = "no application to restrict the capture to, and a display-wide capture is never taken"
            return (payload, "captureFailed")
        }
        // The per-app policy judges the photograph too. Review 2026-09-13: a
        // `refuse`d app could not be pressed but could still be captured, from
        // every acting verb's escalation and from `look`.
        // Coordinator's ruling 2026-09-13: a photograph is not an action — `confirm`
        // gates acting, `refuse` gates looking too. So `confirm` photographs without asking.
        let (verdict, source) = HarnessAppPolicy.verdict(for: application.bundleIdentifier, in: loadedPolicy)
        payload["policy"] = policyBlock(verdict: verdict, source: source, bundleIdentifier: application.bundleIdentifier)
        guard verdict != .refuse else {
            payload["message"] = "app policy refuses \(application.bundleIdentifier ?? "this app") — nothing was photographed"
            return (payload, "policyRefused")
        }
        let inspectStartedAt = Date()
        let inspection = EscalationLadder.inspectForCapture(region: plan.region, of: application)
        payload["inspectMilliseconds"] = Int(Date().timeIntervalSince(inspectStartedAt) * 1000)
        // How many windows were walked. "complete" beside 0 is legitimate only
        // when no window of the app touches the region — worth being able to see.
        payload["inspectedWindows"] = inspection.windows.count
        payload["secureFieldCheck"] = inspection.incompleteReason ?? "complete"
        let decision = ActionSafetyKernel.evaluateCapture(inspection)
        let described = HarnessPolicy.describe(decision)
        // No human is asked for a picture: anything but `allow` is a refusal.
        let executable = HarnessPolicy.executableWithoutAHuman(decision)
        payload["kernel"] = [
            "decision": described.decision,
            "reason": (described.reason ?? NSNull()) as Any,
            "executable": executable,
            "note": (described.reason.map { "refused: \($0)" } ?? NSNull()) as Any
        ]
        guard executable else {
            return (payload, "kernelRefused")
        }

        // Safe to photograph, and nothing to photograph: refuse before the
        // shutter rather than return `ok: true` and a blank image.
        guard inspection.containsDrawableWindow else {
            payload["message"] = "none of this app's windows in the region is a real window (Finder's desktop "
                + "draws nothing in a one-app capture), so the image would be blank"
            return (payload, "applicationNotCapturable")
        }

        // Secrets in the inspected windows' text are blacked out of the photograph;
        // one that cannot be located refuses it (`ScreenSecretGuard`, fail closed).
        let secrets = ScreenSecretGuard.secretsBeforeShutter(
            in: inspection, primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
        )
        payload["secretRedactions"] = secrets.redactions.count
        if let refusal = secrets.refusal {
            payload["message"] = refusal
            return (payload, "captureFailed")
        }

        let displays = EscalationLadder.displays()
        guard let display = EscalationLadder.display(holding: plan.region, among: displays) else {
            payload["message"] = EscalationLadder.CaptureFailure.regionOffScreen.description
            return (payload, "captureFailed")
        }

        switch EscalationLadder.captureSynchronously(
            region: plan.region, on: display,
            processIdentifier: application.processIdentifier,
            redactions: secrets.redactions
        ) {
        case .failure(let error):
            payload["message"] = String(describing: error)
            if let failure = error as? EscalationLadder.CaptureFailure,
               case .applicationNotListed = failure {
                return (payload, "applicationNotCapturable")
            }
            return (payload, "captureFailed")

        case .success(let outcome):
            guard let url = EscalationLadder.writeImage(outcome.jpeg) else {
                payload["message"] = "the image could not be written to \(EscalationLadder.imageDirectory.path)"
                return (payload, "captureFailed")
            }
            payload["imagePath"] = url.path
            payload["imageBytes"] = outcome.jpeg.count
            payload["imagePixels"] = ["w": outcome.pixelWidth, "h": outcome.pixelHeight]
            // What was actually photographed, which is the request clipped to
            // the display — not the request.
            Self.attachFrame(outcome.region, to: &payload, key: "region")
            // The case for a crop is sharpness, not cost, so the resolution is
            // in the response rather than left to be inferred from two numbers.
            // Points per pixel: 0.5 is a Retina display captured at full scale,
            // 1.0 is one pixel per point, and anything above 1 means the 4096
            // cap shrank it.
            payload["pointsPerPixel"] = outcome.pixelWidth > 0
                ? outcome.region.width / CGFloat(outcome.pixelWidth) : 0
            // One estimator in this project, and it is the one that reproduces
            // Anthropic's published table.
            payload["estimatedVisualTokens"] = AccessibilityDumpRunner.estimatedVisualTokens(
                width: outcome.pixelWidth, height: outcome.pixelHeight, usesHighResolutionTier: false
            )
            payload["captureMilliseconds"] = outcome.milliseconds
            return (payload, nil)
        }
    }

    /// Hangs an escalation block under a failed acting verb.
    ///
    /// Always the announcement — which rung would be chosen and why — because
    /// the tree is already in hand and that costs nothing. The picture only
    /// when the caller asked for it.
    private func attachEscalation(
        to response: inout [String: Any],
        request: HarnessRequest,
        rootNode: AccessibilityElementNode,
        application: NSRunningApplication?
    ) {
        // The app the snapshot walked — not a second frontmost read, which is a
        // live system-wide AX query and can name whatever came forward since.
        guard let plan = escalationPlan(
            forcedTier: request.tier, title: request.title, role: request.role, rootNode: rootNode,
            application: application
        ) else { return }

        let result = escalationPayload(plan: plan, capture: request.escalate)
        var block = result.payload
        block["available"] = true
        // The top-level error stays `notFound`/`ambiguous` — that is what the
        // caller asked for and did not get. A capture that then also failed is
        // a second, separate fact and says so where it happened.
        if let code = result.errorCode { block["error"] = code }
        // Rungs in cost order. An ambiguous response already carries each
        // match's separating container — structure, and free — so that is
        // offered before the picture. `notFound` has nothing to separate and
        // keeps the plain picture hint.
        if block["hint"] != nil, response["error"] as? String == "ambiguous" {
            block["hint"] = "first re-issue with a candidate's \"suggestedWithinNamed\" as \"withinNamed\" "
                + "(free, structural); only if the one you mean has null there, "
                + "re-issue with \"escalate\": true for an image and candidate points"
        }
        response["escalation"] = block
    }

    private func lookResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "title": request.title.isEmpty ? NSNull() : request.title,
            "requestedTier": (request.tier?.rawValue ?? NSNull()) as Any
        ]

        func fail(_ code: String, _ message: String) -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            return response
        }

        // Same guard the walker, the menu path and the window path have. A
        // locked screen is the one thing this verb must never photograph — and
        // it is the failure this project recorded as data three times before
        // anyone read the app name.
        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            return fail("screenIsLocked", "the screen is locked — there is nothing of the user's to photograph")
        }

        // A failed walk is not fatal here: the display rung needs no tree at
        // all, and "I could not read the window, here is the screen" is a more
        // useful answer than a refusal. Why it failed still travels.
        // One application for the guard, the walk and the capture. On a failed
        // walk the fallback is read once here and shot below — never re-read.
        var rootNode: AccessibilityElementNode?
        let application: NSRunningApplication?
        do {
            let snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
            rootNode = snapshot.rootNode
            application = snapshot.application
            response["application"] = snapshot.applicationName
            response["bundleIdentifier"] = snapshot.bundleIdentifier
            response["frontmostSource"] = snapshot.frontmostSource?.rawValue ?? NSNull()
            response["walkMilliseconds"] = Int(snapshot.walkDurationInSeconds * 1000)
        } catch {
            application = AccessibilityTreeWalker.focusedApplication()
            response["snapshotError"] = Self.errorCode(for: error)
            response["application"] = application?.localizedName ?? "unknown"
            response["bundleIdentifier"] = application?.bundleIdentifier ?? "unknown"
        }

        // Against whichever app this response says it read — the walked one, or
        // on a failed walk the fallback the display rung is about to shoot.
        // Before any capture: a photograph of the wrong app is still a leak.
        if let refusal = frontmostChangedRefusal(
            request, name: response["application"] as? String,
            bundleIdentifier: response["bundleIdentifier"] as? String,
            dryRun: dryRun, startedAt: startedAt
        ) { return response.merging(refusal) { _, new in new } }

        guard let plan = escalationPlan(
            forcedTier: request.tier, title: request.title, role: request.role, rootNode: rootNode,
            application: application
        ) else {
            return fail(
                "notFound",
                request.tier == .element
                    ? "nothing matched that name, so there is no element region to crop to"
                    : "no rectangle to capture: neither a window frame nor a display frame was readable"
            )
        }

        let result = escalationPayload(plan: plan, capture: true)
        for (key, value) in result.payload { response[key] = value }
        response["ok"] = result.errorCode == nil
        if let code = result.errorCode { response["error"] = code }
        audit(
            request, dryRun: dryRun,
            kernel: (result.payload["kernel"] as? [String: Any])?["decision"] as? String ?? "n/a",
            outcome: result.errorCode ?? "ok", startedAt: startedAt
        )
        return response
    }

    // MARK: status

    /// How long a status-item press may take to show up as a new window, a new
    /// child, or a focus change. Measured 2026-09-12: Wi‑Fi's dropdown was a new
    /// Control Centre AXWindow within ~50 ms.
    static let statusItemVerificationDeadlineInSeconds = 2.0
    static let statusMenuPressTimeoutInSeconds: Float = 0.5

    private static func summariseStatusItem(_ descriptor: AccessibilityStatusItems.Descriptor) -> [String: Any] {
        var entry: [String: Any] = [
            "owner": [
                "name": (descriptor.ownerName ?? NSNull()) as Any,
                "bundleIdentifier": (descriptor.ownerBundleIdentifier ?? NSNull()) as Any
            ],
            "identifier": (descriptor.identifier ?? NSNull()) as Any,
            // Raw, because JSON encoding is the escaping — same rule as `summarise`.
            "title": (descriptor.title?.raw ?? NSNull()) as Any,
            "description": (descriptor.elementDescription?.raw ?? NSNull()) as Any,
            "value": (descriptor.value?.raw ?? NSNull()) as Any,
            "enabled": descriptor.isEnabled,
            "actions": descriptor.publishedActionNames,
            "hasMenu": descriptor.hasMenu,
            "secure": AccessibilityStatusItems.isSecure(descriptor)
        ]
        Self.attachFrame(descriptor.frameInAppKitCoordinates, to: &entry)
        return entry
    }

    /// Merges into the response already collected (`dryRun`, `statusItem`…), like every other refusal.
    private func refuseIfScreenIsLocked(_ request: HarnessRequest, dryRun: Bool, startedAt: Date,
                                        _ message: String, into response: inout [String: Any]) -> Bool {
        guard LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else { return false }
        response["ok"] = false
        response["error"] = "screenIsLocked"
        response["message"] = message
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "screenIsLocked", startedAt: startedAt)
        return true
    }

    /// A process that did not answer is not a process with no icon — so every
    /// list of status items, including an `available` list, says what it missed.
    private static func attachReadFailures(_ read: AccessibilityStatusItems.ReadAll, to response: inout [String: Any]) {
        response["processesFailedCount"] = read.processesFailed.count
        response["processesFailed"] = read.processesFailed.map {
            ["name": UntrustedText($0.name).forDisplay, "axErrorRawValue": Int($0.axErrorRawValue)] as [String: Any]
        }
        response["childrenFailed"] = read.childrenFailed
        if !read.processesFailed.isEmpty || read.childrenFailed > 0 {
            response["warning"] = "THIS LIST IS A FLOOR, NOT A MEASUREMENT — \(read.processesFailed.count) process(es) "
                + "and \(read.childrenFailed) item(s) did not answer"
        }
    }

    /// Not app-scoped: icons are global, so `expectApp` is refused at decode and
    /// there is no frontmost check — but the lock screen still has a menu bar.
    private func statusResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [:]
        if refuseIfScreenIsLocked(request, dryRun: dryRun, startedAt: startedAt,
                                  "the screen is locked — the status items are not the user's", into: &response) { return response }
        let read = AccessibilityStatusItems.readAll()
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)
        response["ok"] = true
        response["itemCount"] = read.items.count
        response["processesAsked"] = read.processesAsked
        response["processesAnswered"] = read.processesAnswered
        response["statusMilliseconds"] = read.milliseconds
        response["items"] = read.items.map { Self.summariseStatusItem($0.descriptor) }
        Self.attachReadFailures(read, to: &response)
        return response
    }

    private func statusItemPressResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        let query = request.statusItem ?? ""
        var response: [String: Any] = ["dryRun": dryRun, "confirmed": request.confirmed, "statusItem": query]
        if refuseIfScreenIsLocked(request, dryRun: dryRun, startedAt: startedAt,
                                  "the screen is locked — there is no status item of the user's to press", into: &response) { return response }

        let read = AccessibilityStatusItems.readAll()
        response["statusMilliseconds"] = read.milliseconds
        let item: AccessibilityStatusItems.Item
        switch AccessibilityStatusItems.match(query, among: read.items.map(\.descriptor)) {
        case .resolved(let index, let tier):
            item = read.items[index]
            response["resolution"] = ["status": "resolved", "matchedOn": tier.rawValue]
        case .ambiguous(let matchCount, let tier):
            response["resolution"] = ["status": "ambiguous", "matchCount": matchCount, "matchedOn": tier.rawValue]
            response["ok"] = false
            response["error"] = "ambiguous"
            Self.attachReadFailures(read, to: &response)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ambiguous", startedAt: startedAt)
            return response
        case .notFound(let available):
            response["resolution"] = [
                "status": "notFound",
                "available": available.map { UntrustedText($0).forDisplay }
            ]
            response["ok"] = false
            response["error"] = "notFound"
            Self.attachReadFailures(read, to: &response)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
            return response
        }
        let descriptor = item.descriptor
        response["item"] = Self.summariseStatusItem(descriptor)
        // Our own status item opens our own panel — see `frontmostChangedRefusal`.
        if Self.isHarnessItself(bundleIdentifier: descriptor.ownerBundleIdentifier) {
            response["ok"] = false
            response["error"] = "targetIsHarnessItself"
            response["message"] = Self.harnessItselfMessage
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "targetIsHarnessItself", startedAt: startedAt)
            return response
        }

        // The "app" a status item belongs to is its owner, so that is what an
        // expectation is checked against — before anything is judged or pressed.
        if let expected = request.expectApp,
           !HarnessPolicy.appMatches(expected: expected, bundleIdentifier: descriptor.ownerBundleIdentifier, name: descriptor.ownerName) {
            response["ok"] = false
            response["error"] = "expectAppMismatch"
            response["expectedApp"] = expected
            response["message"] = "the matched status item is owned by "
                + "\(UntrustedText(descriptor.ownerName ?? descriptor.ownerBundleIdentifier ?? "unknown").forDisplay), "
                + "not \(UntrustedText(expected).forDisplay) — nothing was pressed"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "expectAppMismatch", startedAt: startedAt)
            return response
        }

        // Security first, above the kernel: `confirmed: true` cannot lift it,
        // like a secure field.
        if AccessibilityStatusItems.isSecure(descriptor) {
            _ = applyAppPolicy(to: .allow, bundleIdentifier: descriptor.ownerBundleIdentifier, into: &response)
            response["kernel"] = [
                "decision": "refuse",
                "reason": ActionSafetyKernel.secureStatusItemRefusalReason,
                "executable": false
            ]
            response["ok"] = false
            response["error"] = "kernelRefused"
            audit(request, dryRun: dryRun, kernel: "refuse", outcome: "kernelRefused", startedAt: startedAt)
            return response
        }

        // An anonymous item (Cursor, Claude, Wispr Flow: title "", description
        // "") is named by its owner, or the kernel refuses an empty label.
        let name = descriptor.identifier ?? descriptor.title?.raw ?? descriptor.elementDescription?.raw
            ?? descriptor.ownerName ?? ""
        let resolvedNode = AccessibilityElementNode(
            role: AccessibilityMenu.menuBarItemRole, subrole: nil,
            // The kernel judges the NODE's label, so the owner-name fallback
            // has to be here too, or an anonymous item is refused as unnamed.
            title: descriptor.title?.raw ?? name, value: descriptor.value?.raw,
            elementDescription: descriptor.elementDescription?.raw,
            frameInAppKitCoordinates: descriptor.frameInAppKitCoordinates,
            depth: 0, children: [],
            publishedActionNames: descriptor.publishedActionNames,
            accessibilityElement: item.element
        )
        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluate(
                intent: ElementActionIntent(role: nil, title: name, action: .menu),
                resolvedNode: resolvedNode,
                matchCount: 1,
                // Off-screen is fine here: the bar slides to y=-67 in a full-screen
                // Space and `AXPress` still returns 0.
                visibleBounds: .infinite,
                menuItemEnabled: descriptor.isEnabled
            ),
            bundleIdentifier: descriptor.ownerBundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        let gated = gate(decision, request: request, appName: descriptor.ownerName,
                         bundleIdentifier: descriptor.ownerBundleIdentifier, dryRun: dryRun, into: &response)
        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }
        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        // Four baselines, because a press moves a different one per shape.
        // Measured 2026-09-12: Wi‑Fi opens a new Control Centre window (0 -> 1)
        // and makes it frontmost, its item's `AXSelected` stays false; Cursor's
        // menu item moves NOTHING but `AXSelected` (false -> true) — its 9 menu
        // children were readable before the press, like an app menu's.
        let owner = NSRunningApplication(processIdentifier: descriptor.ownerProcessIdentifier)
        let ownerPid = descriptor.ownerProcessIdentifier
        let windowsBefore = owner.flatMap(AccessibilityMenu.windowCount)
        let childrenBefore = AccessibilityStatusItems.childCount(of: item.element)
        let selectedBefore = AccessibilityStatusItems.isSelected(item.element)
        let ownerWasFrontmost = AccessibilityTreeWalker.frontmost().application?.processIdentifier == ownerPid
        response["windowsBefore"] = (windowsBefore ?? NSNull()) as Any

        // An item with a menu tracks that menu INSIDE its action callback, so
        // the press does not return until the menu closes: measured -25204 at
        // 507 ms on Cursor with the menu plainly open. The performer's 5 s would
        // only hold this thread five times longer. A short timeout, and -25204
        // is "sent, unconfirmed" — the verification decides, not the code.
        phaseTiming.actionStarting()
        let result = AccessibilityActionPerformer.perform(
            kAXPressAction, on: item.element,
            timeoutInSeconds: descriptor.hasMenu ? Self.statusMenuPressTimeoutInSeconds
                : AccessibilityActionPerformer.actionTimeoutInSeconds
        )
        phaseTiming.actionReturned()
        let sentUnconfirmed = result.error == .cannotComplete && descriptor.hasMenu
        response["performed"] = [
            "status": result.error == .success ? "sent" : (sentUnconfirmed ? "sentUnconfirmed" : "failed"),
            "axErrorRawValue": result.error.rawValue,
            "milliseconds": result.milliseconds
        ]
        guard result.error == .success || sentUnconfirmed else {
            response["ok"] = false
            response["error"] = "performFailed"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "performFailed", startedAt: startedAt)
            return response
        }

        let verifyStartedAt = Date()
        var evidence: String?
        var verifyPolls = 0
        while evidence == nil,
              Date().timeIntervalSince(verifyStartedAt) < Self.statusItemVerificationDeadlineInSeconds {
            verifyPolls += 1
            if let windowsBefore, let owner, AccessibilityMenu.windowCount(for: owner) != windowsBefore {
                evidence = "the owner's window count changed"
            } else if AccessibilityStatusItems.childCount(of: item.element) != childrenBefore {
                evidence = "the item's child count changed"
            } else if AccessibilityStatusItems.isSelected(item.element) != selectedBefore {
                evidence = "the item's AXSelected changed"
            } else if !ownerWasFrontmost,
                      AccessibilityTreeWalker.frontmost().application?.processIdentifier == ownerPid {
                evidence = "the owner became frontmost"
            } else {
                usleep(AccessibilityWindows.observationPollIntervalInMicroseconds)
            }
        }
        let verifyMilliseconds = Int(Date().timeIntervalSince(verifyStartedAt) * 1000)
        phaseTiming.verified(walks: verifyPolls, path: "poll")
        response["windowsAfter"] = (owner.flatMap(AccessibilityMenu.windowCount) ?? NSNull()) as Any

        if let evidence {
            response["verification"] = ["status": "confirmed", "evidence": evidence, "milliseconds": verifyMilliseconds]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        } else {
            response["verification"] = ["status": "notObserved", "milliseconds": verifyMilliseconds]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
        }
        return response
    }

    // MARK: Audit

    /// An accessibility close that bypasses the harness (a probe's or the runner's
    /// own cleanup) still leaves an audit line: which tool, which window number —
    /// or which app, for a tab — and why. 2026-10-06: the only witness to four such
    /// closes was Chrome's own AppKit log.
    nonisolated static func directCloseAuditLine(tool: String, app: String?, windowNumber: Int?, why: String, closed: Bool,
                                                 at date: Date = Date()) -> String {
        HarnessPolicy.auditLine(at: date, id: "axClose-" + String(UUID().uuidString.prefix(8)), verb: "axClose",
                                target: windowNumber.map { "window \($0)" } ?? "tab", app: app, session: sessionIdentifier,
                                dryRun: false, confirmed: false, kernel: "bypassesHarness", outcome: closed ? "closed" : "notClosed",
                                milliseconds: 0, phases: ["tool": tool, "why": why, "windowNumber": windowNumber ?? NSNull()])
    }

    /// Writes it to harness-audit.log and the day's mirror: one O_APPEND write each.
    /// ponytail: no rotation or mirror cap here (a handful of lines per run); the next harness request rotates.
    nonisolated static func auditDirectClose(tool: String, processIdentifier: pid_t, windowNumber: Int?, why: String, closed: Bool) {
        let date = Date()
        let app = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
        let data = Data((directCloseAuditLine(tool: tool, app: app, windowNumber: windowNumber, why: why, closed: closed, at: date) + "\n").utf8)
        _ = append(data, to: auditLogURL)
        _ = append(data, to: auditMirrorURL(for: date))
    }

    private func audit(
        _ request: HarnessRequest,
        dryRun: Bool,
        kernel: String,
        outcome: String,
        startedAt: Date
    ) {
        audit(request, dryRun: dryRun, kernel: kernel, outcome: outcome, startedAt: startedAt,
              confirmedBy: currentConfirmedBy, phases: phaseTiming.wireFields)
    }

    /// Called off the request queue by `ping`, so it takes the per-request
    /// fields as arguments instead of reading the in-flight request's.
    private func audit(
        _ request: HarnessRequest,
        dryRun: Bool,
        kernel: String,
        outcome: String,
        startedAt: Date,
        confirmedBy: String?,
        phases: [String: Any],
        frontmost knownFrontmost: AccessibilityTreeWalker.FrontmostRead? = nil
    ) {
        let frontmost = knownFrontmost ?? AccessibilityTreeWalker.frontmost()
        appendAudit(HarnessPolicy.auditLine(
            at: startedAt,
            id: request.id,
            verb: request.verb.rawValue,
            target: Self.auditTarget(for: request),
            app: frontmost.application?.bundleIdentifier,
            session: Self.sessionIdentifier,
            dryRun: dryRun,
            confirmed: request.confirmed,
            kernel: kernel,
            outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt),
            frontmostSource: frontmost.source.rawValue,
            frontmostSystemWideError: frontmost.systemWideErrorRawValue,
            confirmedBy: confirmedBy,
            phases: phases
        ), at: startedAt)
    }

    /// Reads nothing a request in flight owns — see `answer(line:)`.
    private func pingResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        // No frontmost read: the system-wide one waits on the focused app (Xcode busy
        // under a test run), and its fallback adds a 0.5 s timeout — a ping over 0.5 s, 2026-10-06.
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt,
              confirmedBy: nil, phases: HarnessPhaseTiming().wireFields,
              frontmost: .init(application: nil, source: .notRead, systemWideErrorRawValue: nil))
        let counters = stateLock.withLock { (failures: auditMirrorFailures, overflow: auditMirrorOverflowLines) }
        return [
            "ok": true,
            "harness": versionString,
            "dryRun": dryRun,
            "dryRunSource": globalDryRun ? "global --harness-dry-run" : (request.requestedDryRun == true ? "request" : "none"),
            "killSwitchPresent": Self.killSwitchIsPresent(),
            "socket": Self.socketURL.path,
            "auditMirrorFailures": counters.failures,
            "auditMirrorOverflowLines": counters.overflow
        ]
    }

    /// Append-only, and it rotates rather than truncates. The log is the only
    /// record that a refusal happened at all — a refused request leaves nothing
    /// else behind — so history is kept, just bounded.
    ///
    /// The same line also goes to the day-split mirror under `~/Library/Logs`,
    /// which nothing rotates but `AuditMirrorCap` bounds per day. A mirror
    /// failure never fails the request; failures and capped lines are counted
    /// and `ping` reports both.
    private func appendAudit(_ line: String, at date: Date = Date()) {
        stateLock.lock(); defer { stateLock.unlock() }
        let data = Data((line + "\n").utf8)
        rotateAuditLogIfLarge()
        _ = Self.append(data, to: Self.auditLogURL)

        let mirrorURL = Self.auditMirrorURL(for: date)
        let mirrorBytes = ((try? FileManager.default.attributesOfItem(atPath: mirrorURL.path))?[.size] as? Int) ?? 0
        switch AuditMirrorCap.decision(
            currentBytes: mirrorBytes, lineBytes: data.count,
            markerWritten: auditMirrorFilesMarkedAsCapped.contains(mirrorURL.lastPathComponent)
        ) {
        case .append:
            if !Self.append(data, to: mirrorURL) { auditMirrorFailures += 1 }
        case .dropAndWriteMarker:
            // One line saying the silence that follows is the cap, not a harness that stopped.
            auditMirrorFilesMarkedAsCapped.insert(mirrorURL.lastPathComponent)
            auditMirrorOverflowLines += 1
            let marker = "{\"timestamp\":\"\(HarnessPolicy.auditTimestampFormatter.string(from: date))\","
                + "\"session\":\"\(Self.sessionIdentifier)\",\"outcome\":\"auditMirrorCapReached\","
                + "\"message\":\"this mirror reached its \(AuditMirrorCap.dailyBytes)-byte daily cap; later lines today "
                + "are dropped here, still written to harness-audit.log, and counted by ping as auditMirrorOverflowLines\"}\n"
            if !Self.append(Data(marker.utf8), to: mirrorURL) { auditMirrorFailures += 1 }
        case .drop:
            auditMirrorOverflowLines += 1
        }
    }

    /// Owner-only, like the voice logs: every audit line names the app, the
    /// target and any typed text, and `data.write(to:)` created these 0644 —
    /// readable by every local account (found 2026-09-25). Created 0600 and an
    /// existing file narrowed on the next append (`appendOwnerOnly`).
    static func append(_ data: Data, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return MeasurementLogFile.appendOwnerOnly(data, to: url)
    }

    /// One old file, then the previous one goes. Two files is enough to answer
    /// "what happened just before this" and small enough that nobody has to
    /// think about it.
    private func rotateAuditLogIfLarge() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.auditLogURL.path)
        guard let size = attributes?[.size] as? Int, size > Self.auditLogRotationBytes else { return }
        try? FileManager.default.removeItem(at: Self.rotatedAuditLogURL)
        try? FileManager.default.moveItem(at: Self.auditLogURL, to: Self.rotatedAuditLogURL)
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    static func errorCode(for error: Error) -> String {
        guard let snapshotError = error as? AccessibilitySnapshotError else { return "snapshotFailed" }
        switch snapshotError {
        case .accessibilityPermissionNotGranted: return "accessibilityPermissionNotGranted"
        case .noFrontmostApplication: return "noFrontmostApplication"
        case .noFocusedWindow: return "noFocusedWindow"
        case .screenIsLocked: return "screenIsLocked"
        }
    }
}
