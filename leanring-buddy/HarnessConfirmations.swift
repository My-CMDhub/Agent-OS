//
//  HarnessConfirmations.swift
//  leanring-buddy
//
//  The kernel's `requireConfirmation` is a question for a human. Harness
//  requests run on the main thread inside `DispatchQueue.main.sync`, so a
//  request cannot block waiting for a click — the panel only gets to draw
//  *between* requests. So a confirmation is a TICKET: the request returns at
//  once with a ticket id, the panel shows the question, the owner answers it
//  in-process, and the caller re-issues the same request carrying the id.
//
//  Two things the wire can never do: answer a ticket (the answer comes from
//  this object's UI, or from an approval rule that UI created) and spend one
//  ticket on a different action (a ticket matches one verb, one app, one
//  target — and for `type`, one text — and is consumed by one execution).
//
//  Main-thread only, like everything the harness touches. Not annotated
//  `@MainActor` because `HarnessServer` is not, and it is the one caller.
//

import AppKit
import Combine
import Foundation
import Security

final class HarnessConfirmations: ObservableObject {

    /// `stale`: the element or selection the ticket was opened on moved before it
    /// was used (`ActionBinding`). Terminal — a stale ticket never becomes spendable.
    enum Status: String { case pending, allowed, denied, expired, stale }
    enum Scope: String { case once, always }

    /// Who pressed an approval button. Measured 2026-09-14 from inside the
    /// SwiftUI Button action, via `NSApp.currentEvent`:
    ///   - the owner's real mouse click: leftMouseUp, source pid 0
    ///   - another process's `AXUIElementPerformAction(AXPress)`: no event at all
    ///   - another process posting a `CGEvent` click: leftMouseUp, source pid = the poster
    /// A poster can forge `eventSourceStateID` (it wrote 1 and 1 arrived) but not
    /// the source pid (it wrote 0 and its real pid arrived). So stateID is not a
    /// signal and pid 0 on a mouse or key event is.
    ///
    /// The limit, stated so nobody reads more into it: pid 0 means "came through
    /// the HID layer", not "a human". A virtual HID driver (Karabiner) and remote
    /// screen control arrive pid 0 too. The highest-risk tier needs Touch ID.
    ///
    /// Review 2026-09-14: pid 0 alone is not enough, because `NSApp.currentEvent`
    /// is documented as the last event the app RETRIEVED, not the one that caused
    /// this action. An `AXPress` on "Always" landing while the owner's real
    /// mouse-up on another button is still current would inherit that event. So
    /// an approval also needs the event to be fresh, to belong to the window the
    /// button is in, never to have reached an answer button before, to be a single
    /// click, and to land on a row that has not just moved under the pointer.
    enum ApprovalInput {
        enum Verdict: Equatable {
            case accepted
            case rejected(reason: String)
        }

        static let humanInputEventTypes: Set<NSEvent.EventType> = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .keyDown, .keyUp
        ]
        /// `NSEvent.clickCount` raises for any other type, so it is read only for these.
        static let mouseButtonEventTypes: Set<NSEvent.EventType> = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp
        ]

        /// Measured 2026-09-14: the owner's real clicks were 1.0-3.4 ms old when
        /// the Button action ran. 500 ms is two orders of magnitude of headroom
        /// for a busy main thread while staying far shorter than the gap between a
        /// real click and a scripted press that waits to reuse it. A click that
        /// queued behind a multi-second harness request is refused and the owner
        /// clicks again — cheaper than widening the window a stale event can ride.
        static let maximumEventAgeSeconds: TimeInterval = 0.5
        /// A row must sit still this long before its buttons count. Above the
        /// default double-click interval (0.5 s), so the second click of a slow
        /// double-click cannot approve a row that slid in under the first; and
        /// below the time it takes to read a card's lines and aim, so a human who
        /// actually read the question never meets it.
        static let minimumRowSettledSeconds: TimeInterval = 0.8

        /// What makes one `NSEvent` itself and not another. Every field is safe to
        /// read on any event type; the mouse event number is a CG field, 0 for keys.
        struct EventIdentity: Hashable {
            let typeRawValue: UInt
            let timestamp: TimeInterval
            let windowNumber: Int
            let mouseEventNumber: Int64
        }

        /// Everything the verdict looks at, gathered at the moment of the press.
        /// Pure data, so every rejection is testable without a real event.
        struct Evidence: Equatable {
            var eventType: NSEvent.EventType? = nil
            var sourceProcessID: Int64? = nil
            /// 0 for a key event.
            var clickCount: Int = 0
            var eventAgeSeconds: TimeInterval? = nil
            var eventWindowNumber: Int? = nil
            /// The window the pressed button is drawn in (the card or the panel).
            var hostWindowNumber: Int? = nil
            /// How long the row AND its window have been in their current place.
            var rowSettledSeconds: TimeInterval? = nil
            var eventIdentity: EventIdentity? = nil
            /// `NSEvent.locationInWindow`: AppKit, BOTTOM-left origin. Mouse events only.
            var clickLocationInWindow: CGPoint? = nil
            /// Height of the window's content view, which hosts the SwiftUI tree —
            /// the one number that flips a bottom-left point into top-left.
            var hostContentHeight: CGFloat? = nil
            /// The pressed button's frame in the hosting view's SwiftUI `.global`
            /// space: TOP-left origin.
            var pressedButtonFrame: CGRect? = nil

            /// Reads a live event. Both clocks are seconds since boot:
            /// `NSEvent.timestamp` and `ProcessInfo.systemUptime`.
            static func gathered(from event: NSEvent?, hostWindowNumber: Int?, rowSettledSeconds: TimeInterval?,
                                 hostContentHeight: CGFloat? = nil, pressedButtonFrame: CGRect? = nil,
                                 nowUptime: TimeInterval) -> Evidence {
                var evidence = Evidence(hostWindowNumber: hostWindowNumber, rowSettledSeconds: rowSettledSeconds,
                                        hostContentHeight: hostContentHeight, pressedButtonFrame: pressedButtonFrame)
                guard let event else { return evidence }
                let cgEvent = event.cgEvent
                evidence.eventType = event.type
                evidence.sourceProcessID = cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
                // `locationInWindow` is only meaningful for mouse events.
                evidence.clickLocationInWindow = mouseButtonEventTypes.contains(event.type) ? event.locationInWindow : nil
                evidence.clickCount = mouseButtonEventTypes.contains(event.type) ? event.clickCount : 0
                evidence.eventAgeSeconds = nowUptime - event.timestamp
                evidence.eventWindowNumber = event.windowNumber
                evidence.eventIdentity = EventIdentity(
                    typeRawValue: event.type.rawValue, timestamp: event.timestamp, windowNumber: event.windowNumber,
                    mouseEventNumber: cgEvent?.getIntegerValueField(.mouseEventNumber) ?? 0
                )
                return evidence
            }
        }

        /// A window point (bottom-left origin) in the hosting view's top-left space.
        static func topLeftPoint(fromWindowPoint point: CGPoint, contentHeight: CGFloat) -> CGPoint {
            CGPoint(x: point.x, y: contentHeight - point.y)
        }

        /// Review 2026-09-14: every other check passes for a real click ANYWHERE in
        /// the card window, so a programmatic press within 500 ms could borrow a
        /// click the owner made on blank space, a line of text, or another row.
        static func clickLandsInsidePressedButton(_ evidence: Evidence) -> Bool {
            guard let location = evidence.clickLocationInWindow, let height = evidence.hostContentHeight,
                  let frame = evidence.pressedButtonFrame, !frame.isEmpty else { return false }
            return frame.contains(topLeftPoint(fromWindowPoint: location, contentHeight: height))
        }

        static func verdict(_ evidence: Evidence, eventAlreadyUsed: Bool) -> Verdict {
            guard let eventType = evidence.eventType else {
                return .rejected(reason: "no input event (programmatic press, e.g. Accessibility)")
            }
            guard humanInputEventTypes.contains(eventType) else {
                return .rejected(reason: "event type \(eventType.rawValue) is not a mouse button or key")
            }
            guard let sourceProcessID = evidence.sourceProcessID else {
                return .rejected(reason: "event carries no source process")
            }
            guard sourceProcessID == 0 else {
                return .rejected(reason: "posted by process \(sourceProcessID)")
            }
            guard evidence.clickCount <= 1 else {
                return .rejected(reason: "click \(evidence.clickCount) of a multi-click — it may have landed on a row that moved under the first")
            }
            guard let age = evidence.eventAgeSeconds, age <= maximumEventAgeSeconds else {
                let shown = evidence.eventAgeSeconds.map { "\(Int($0 * 1000)) ms" } ?? "of unknown age"
                return .rejected(reason: "input event is \(shown) old, at most \(Int(maximumEventAgeSeconds * 1000)) ms — it is not the click that pressed this button")
            }
            guard let host = evidence.hostWindowNumber, evidence.eventWindowNumber == host else {
                return .rejected(reason: "input event belongs to window \(evidence.eventWindowNumber.map(String.init) ?? "none"), the button is in window \(evidence.hostWindowNumber.map(String.init) ?? "unknown")")
            }
            // A key press has no location; it reaches a button only through focus,
            // which the card can never have (it never becomes key).
            if mouseButtonEventTypes.contains(eventType), !clickLandsInsidePressedButton(evidence) {
                return .rejected(reason: "the click did not land inside the pressed button")
            }
            guard !eventAlreadyUsed else {
                return .rejected(reason: "this input event already reached an answer button")
            }
            guard let settled = evidence.rowSettledSeconds, settled >= minimumRowSettledSeconds else {
                let shown = evidence.rowSettledSeconds.map { "\(Int($0 * 1000)) ms" } ?? "an unknown time"
                return .rejected(reason: "the row had been in place \(shown), needs \(Int(minimumRowSettledSeconds * 1000)) ms — click again")
            }
            return .accepted
        }
    }

    struct Ticket: Identifiable, Equatable {
        let id: String
        let createdAt: Date
        let verb: String
        /// Exactly what the request named — the match key. Never shown.
        let rawTarget: String
        /// `UntrustedText(rawTarget).forDisplay` — the only form the UI sees.
        let target: String
        /// `type` only: the text and mode are part of the action's identity.
        let text: String?
        let mode: String?
        /// The resolution qualifiers. Review 2026-09-13: without them a ticket
        /// approved for `press "Delete" withinNamed:"Drafts"` re-issued as
        /// `withinNamed:"Bank"` matched — same verb, app and title, different button.
        var withinNamed: String? = nil
        var nearPoint: CGPoint? = nil
        var role: String? = nil
        var thenConfirm: Bool = false
        let appName: String?
        let bundleIdentifier: String
        /// `displayedReason(_:)` of the kernel's reason, escaped at `open`. The
        /// kernel's reasons embed app-written strings (`unrecognised role <role>`),
        /// so the raw reason could forge a line under the question like any name.
        let reason: String
        var status: Status
        var answeredAt: Date?
        /// One ticket, one action. Status stays `allowed` so the panel can still
        /// show the answer; this flag is what refuses a second use.
        var consumed = false
        /// `displayLines(for:appName:)` of this ticket's shape, computed once at
        /// `open`. The panel renders exactly these — never its own reading of
        /// the fields — so what the owner sees and what the ticket binds cannot drift.
        var displayLines: [String] = []
        /// What the action would affect when the ticket was opened. nil for verbs
        /// that act on no element (focus, launch) and in tests of the words alone.
        var binding: ActionBinding? = nil
        /// "target" or "selection" once the ticket went stale.
        var staleField: String? = nil
        /// Decided from the kernel's RAW reason when the ticket opens — the stored
        /// `reason` is the quoted display form, which a prefix check never matches
        /// (caught by `aDestructiveQuestionCanBeAllowedOnceButNeverAlways`).
        var isDestructive = false

        /// The shape this ticket answers — what `mismatchedField` compares.
        var shape: Shape {
            Shape(verb: verb, bundleIdentifier: bundleIdentifier, rawTarget: rawTarget, text: text, mode: mode,
                  withinNamed: withinNamed, nearPoint: nearPoint, role: role, thenConfirm: thenConfirm)
        }

        var expiresAt: Date { createdAt.addingTimeInterval(HarnessConfirmations.ticketLifetimeInSeconds) }
    }

    /// The shape of one request, as far as a ticket or a rule is concerned.
    struct Shape: Equatable {
        let verb: String
        let bundleIdentifier: String?
        let rawTarget: String
        var text: String? = nil
        var mode: String? = nil
        var withinNamed: String? = nil
        var nearPoint: CGPoint? = nil
        var role: String? = nil
        var thenConfirm: Bool = false
    }

    enum Consumption: Equatable {
        case allowed, pending, denied, expired, unknown
        /// An `allowed` ticket that already ran its one action.
        case consumed
        /// A ticket for a different action. Names the field so the caller can
        /// see which half of the request drifted.
        case mismatch(field: String)
        /// The element or selection moved since the ticket was opened.
        case stale(field: String)
    }

    enum OpenResult: Equatable {
        case opened(Ticket)
        /// A wire error code and its message.
        case refused(code: String, message: String)
    }

    /// nil target is app-wide for `focus`/`launch` — the only rules the panel
    /// creates without one — and matches nothing for any other verb; nil text
    /// means "the approved request had no text". The qualifiers below
    /// are NOT wildcards: nil means "the approved request had none". Before
    /// 2026-09-14 a rule kept only app+verb+target+text, so "Always press Delete
    /// within Drafts" allowed Delete within any container — the defect the
    /// ticket had before review. A rule from before then decodes these
    /// as nil and so matches only an unqualified request: narrower, never
    /// broader. (An old `type` rule has no `mode` and so matches no `type`
    /// request at all until re-approved.) Stored in the keychain — see
    /// `ApprovalRulesKeychainStore`.
    struct ApprovalRule: Codable, Equatable {
        let bundleIdentifier: String
        let verb: String
        let target: String?
        var text: String? = nil
        var mode: String? = nil
        var withinNamed: String? = nil
        var nearPoint: CGPoint? = nil
        var role: String? = nil
        /// Absent means false — the same reading a pre-2026-09-14 file gets.
        var thenConfirm: Bool? = nil
    }

    static let ticketLifetimeInSeconds: TimeInterval = 60
    /// More than this many open questions is not a queue, it is a way to get a
    /// click on the wrong one.
    static let maximumPendingTickets = 3
    /// Verbs whose "always" rule covers the whole app: their target IS the app.
    static let appWideRuleVerbs: Set<String> = ["focus", "launch"]
    /// No displayed line may be longer than this, or no ticket is opened. A
    /// question that cannot be shown in full cannot be asked. 300 is a control
    /// label at `UntrustedText.maximumLabelLength` (128) with room for its
    /// escaping and the line's own words — every real target fits — while a
    /// typed paragraph does not, and a paragraph in a menu-bar panel is text
    /// the owner will approve without reading.
    static let maximumDisplayLineLength = 300

    /// Oldest first. Review 2026-09-14: newest-first inserted every new ticket
    /// at the top, so a ticket opened while the owner was mid-click pushed the
    /// row under the pointer down and put a different ticket's button there.
    /// Appending never moves an existing row.
    @Published private(set) var tickets: [Ticket] = []
    /// Identities of every input event that reached an answer button, whatever
    /// the verdict. An event is spent the first time it arrives: a real click on
    /// Deny, or on an Allow refused as too early, must not stay current for a
    /// scripted press on another ticket to reuse. Only events younger than
    /// `maximumEventAgeSeconds` can pass anyway, so a short list is the whole set.
    private var inputEventsThatReachedAnAnswerButton: [ApprovalInput.EventIdentity] = []
    private static let rememberedInputEventCount = 64
    /// The rules as last read from the keychain, for the panel's "Always rules"
    /// list. The gate never uses this copy — `rule(for:)` re-reads every time.
    @Published private(set) var alwaysRules: [ApprovalRule] = []
    /// Why the rules could not be read or saved, shown beside the list. An
    /// "always" that failed to save is a "once" the owner thinks is permanent.
    @Published private(set) var alwaysRulesProblem: String?

    private let rulesStore: ApprovalRulesKeychainStore
    /// The pre-2026-09-14 rules file. Never read as rules — any process running
    /// as the owner can write it — but its existence is reported on every
    /// consult, so an attempt to plant a rule there is visible, not silently honoured.
    private let ignoredApprovalsFileURL: URL?

    init(rulesStore: ApprovalRulesKeychainStore, ignoredApprovalsFileURL: URL? = nil) {
        self.rulesStore = rulesStore
        self.ignoredApprovalsFileURL = ignoredApprovalsFileURL
        refreshAlwaysRules()
    }

    // MARK: Pure

    static func status(of ticket: Ticket, now: Date) -> Status {
        if ticket.status == .pending, now >= ticket.expiresAt { return .expired }
        return ticket.status
    }

    /// A ticket answers exactly one request shape.
    static func ticketMatches(_ ticket: Ticket, _ shape: Shape) -> Bool {
        mismatchedField(ticket, shape) == nil
    }

    static func mismatchedField(_ ticket: Ticket, _ shape: Shape) -> String? {
        mismatchedField(approved: ticket.shape, shape)
    }

    /// The one definition of "the same action", shared by tickets and rules.
    static func mismatchedField(approved: Shape, _ shape: Shape) -> String? {
        if approved.verb != shape.verb { return "verb" }
        guard let approvedBundle = approved.bundleIdentifier,
              sameBundleIdentifier(approvedBundle, shape.bundleIdentifier) else { return "bundleIdentifier" }
        if approved.rawTarget != shape.rawTarget { return "target" }
        if approved.withinNamed != shape.withinNamed { return "withinNamed" }
        if approved.nearPoint != shape.nearPoint { return "nearPoint" }
        if approved.role != shape.role { return "role" }
        if approved.thenConfirm != shape.thenConfirm { return "thenConfirm" }
        if shape.verb == "type" {
            if approved.text != shape.text { return "text" }
            if approved.mode != shape.mode { return "mode" }
        }
        return nil
    }

    /// Every field of `shape` as a plain line a human reads — the whole question.
    /// App-written strings are escaped (a newline cannot forge a second line)
    /// and never truncated; `open` refuses instead when a line is too long.
    /// A test walks `Shape` with `Mirror`, so a field added here without a line fails it.
    static func displayLines(for shape: Shape, appName: String?, binding: ActionBinding?) -> [String] {
        displayLines(for: shape, appName: appName)
            + (binding.map { ActionBinding.displayLines(for: $0, bundleIdentifier: shape.bundleIdentifier) } ?? [])
    }

    static func displayLines(for shape: Shape, appName: String?) -> [String] {
        var lines = ["\(shape.verb) \(UntrustedText(shape.rawTarget).forDisplayInFull)"]
        if let withinNamed = shape.withinNamed { lines.append("within \(UntrustedText(withinNamed).forDisplayInFull)") }
        if let role = shape.role { lines.append("role \(UntrustedText(role).forDisplayInFull)") }
        if let point = shape.nearPoint { lines.append("at point (\(point.x), \(point.y))") }
        if shape.text != nil || shape.mode != nil {
            let text = shape.text.map { UntrustedText($0).forDisplayInFull } ?? "none"
            lines.append("text: \(text) (\(shape.mode ?? "no mode"))")
        }
        // `type` with thenConfirm also performs AXConfirm — it submits. The owner
        // must not approve "type X" and get "type X and press Return".
        if shape.thenConfirm { lines.append("then submits (AXConfirm)") }
        let app = appName.map { UntrustedText($0).forDisplayInFull } ?? "unnamed app"
        let bundle = shape.bundleIdentifier.map { UntrustedText($0).forDisplayInFull } ?? "no bundle identifier"
        lines.append("in \(app) (\(bundle))")
        return lines
    }

    /// A stored rule in the same words a ticket uses, for the panel's revoke list.
    /// The app name comes from the local install, not from the rule.
    static func displayLines(for rule: ApprovalRule) -> [String] {
        let shape = Shape(
            verb: rule.verb, bundleIdentifier: rule.bundleIdentifier, rawTarget: rule.target ?? "",
            text: rule.text, mode: rule.mode, withinNamed: rule.withinNamed, nearPoint: rule.nearPoint,
            role: rule.role, thenConfirm: rule.thenConfirm ?? false
        )
        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) }
        var lines = displayLines(for: shape, appName: appName)
        if rule.target == nil { lines[0] = "\(rule.verb) (any target)" }
        return lines
    }

    static func consumption(of ticket: Ticket?, _ shape: Shape, now: Date) -> Consumption {
        guard let ticket else { return .unknown }
        if let field = mismatchedField(ticket, shape) { return .mismatch(field: field) }
        switch status(of: ticket, now: now) {
        case .pending: return .pending
        case .denied: return .denied
        case .expired: return .expired
        case .stale: return .stale(field: ticket.staleField ?? "binding")
        case .allowed: return ticket.consumed ? .consumed : .allowed
        }
    }

    /// The reason line exactly as the card draws it.
    static func displayedReason(_ reason: String) -> String {
        UntrustedText(reason).forDisplayInFull
    }

    /// The "Always" button's words. For `focus`/`launch` the rule `rule(for:)`
    /// creates covers the whole app, so calling it "exactly this" would be the
    /// one line on the card that is not true. `ticket.appName` is already escaped.
    /// Destructive questions get Allow once and Deny only — see
    /// `ActionSafetyKernel.isDestructiveConfirmationReason`. The card hides the
    /// button AND `answer` refuses to save the rule, so no caller can get one.
    static func offersAlwaysRule(for ticket: Ticket) -> Bool {
        !ticket.isDestructive
    }

    static func alwaysButtonTitle(for ticket: Ticket) -> String {
        guard appWideRuleVerbs.contains(ticket.verb) else { return "Always allow exactly this" }
        return "Always allow \(ticket.verb) for the whole app \(ticket.appName ?? "(unnamed app)")"
    }

    /// Why a ticket may not be opened for this shape, or nil.
    static func openRefusal(for shape: Shape, appName: String? = nil, binding: ActionBinding? = nil, reason: String, pendingCount: Int) -> (code: String, message: String)? {
        if shape.rawTarget.isEmpty {
            return ("confirmationTargetUnnamed", "the request names no target, so a ticket for it would authorise anything")
        }
        if (shape.bundleIdentifier ?? "").isEmpty {
            return ("confirmationAppUnidentified", "the application has no bundle identifier, so a ticket could not be scoped to it")
        }
        // Unicode scalars, not Characters (review 2026-09-14): "a" followed by
        // 3,000 combining marks is ONE Character, yet draws a column of marks over
        // the lines around it. Scalars bound what is actually drawn.
        let shownLines = displayLines(for: shape, appName: appName, binding: binding) + [displayedReason(reason)]
        if let longest = shownLines.map(\.unicodeScalars.count).max(), longest > maximumDisplayLineLength {
            return ("confirmationTooLongToShow",
                    "a line of the question is \(longest) unicode scalars and the panel shows at most \(maximumDisplayLineLength) in full — the owner cannot approve what they cannot read")
        }
        if pendingCount >= maximumPendingTickets {
            return ("tooManyPendingConfirmations",
                    "\(pendingCount) tickets are already waiting in the Clicky panel — answer or let them expire first")
        }
        return nil
    }

    /// Bundle id case-insensitive, everything else exact — through the same
    /// `mismatchedField` a ticket uses. `focus`/`launch` stay app-wide.
    ///
    /// Review 2026-09-14: a nil `target` or `text` used to mean "anything", a
    /// wildcard the panel no longer creates but still honoured. Now nil text
    /// matches only a request with no text, and a nil target matches nothing: a
    /// request's target is never nil, and an empty one is the unnamed target a
    /// ticket is refused for (`confirmationTargetUnnamed`).
    static func matchingRule(in rules: [ApprovalRule], _ shape: Shape) -> ApprovalRule? {
        rules.first { rule in
            if appWideRuleVerbs.contains(rule.verb), rule.target == nil {
                return rule.verb == shape.verb && sameBundleIdentifier(rule.bundleIdentifier, shape.bundleIdentifier)
            }
            guard let target = rule.target else { return false }
            let approved = Shape(
                verb: rule.verb, bundleIdentifier: rule.bundleIdentifier,
                rawTarget: target, text: rule.text, mode: rule.mode,
                withinNamed: rule.withinNamed, nearPoint: rule.nearPoint, role: rule.role,
                thenConfirm: rule.thenConfirm ?? false
            )
            return mismatchedField(approved: approved, shape) == nil
        }
    }

    /// The rule an "always" answer to this ticket creates: exactly this action
    /// in this app — every field the panel showed — except `focus`/`launch`,
    /// whose action is the app.
    static func rule(for ticket: Ticket) -> ApprovalRule {
        if appWideRuleVerbs.contains(ticket.verb) {
            return ApprovalRule(bundleIdentifier: ticket.bundleIdentifier, verb: ticket.verb, target: nil)
        }
        return ApprovalRule(
            bundleIdentifier: ticket.bundleIdentifier, verb: ticket.verb, target: ticket.rawTarget,
            text: ticket.text, mode: ticket.mode, withinNamed: ticket.withinNamed, nearPoint: ticket.nearPoint,
            role: ticket.role, thenConfirm: ticket.thenConfirm ? true : nil
        )
    }

    static func parseApprovals(_ data: Data) -> Result<[ApprovalRule], HarnessAppPolicy.ParseFailure> {
        do {
            return .success(try JSONDecoder().decode([ApprovalRule].self, from: data))
        } catch {
            return .failure(.init(reason: String(describing: error).prefix(200).description))
        }
    }

    private static func sameBundleIdentifier(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    // MARK: Mutating

    func pendingCount(now: Date = Date()) -> Int {
        tickets.filter { Self.status(of: $0, now: now) == .pending }.count
    }

    func ticket(id: String) -> Ticket? { tickets.first { $0.id == id } }

    func open(_ shape: Shape, appName: String?, reason: String, binding: ActionBinding? = nil) -> OpenResult {
        let now = Date()
        let pending = pendingCount(now: now)
        if let refusal = Self.openRefusal(for: shape, appName: appName, binding: binding, reason: reason, pendingCount: pending) {
            return .refused(code: refusal.code, message: refusal.message)
        }
        var ticket = Ticket(
            id: UUID().uuidString, createdAt: now, verb: shape.verb,
            rawTarget: shape.rawTarget, target: UntrustedText(shape.rawTarget).forDisplay,
            text: shape.text, mode: shape.mode,
            withinNamed: shape.withinNamed, nearPoint: shape.nearPoint, role: shape.role, thenConfirm: shape.thenConfirm,
            appName: appName.map { UntrustedText($0).forDisplay },
            bundleIdentifier: shape.bundleIdentifier ?? "", reason: Self.displayedReason(reason), status: .pending,
            displayLines: Self.displayLines(for: shape, appName: appName, binding: binding),
            binding: binding
        )
        ticket.isDestructive = ActionSafetyKernel.isDestructiveConfirmationReason(reason)
        tickets.append(ticket)
        // At most 20: evict the oldest answered/expired first, never a pending one.
        while tickets.count > 20,
              let index = tickets.firstIndex(where: { Self.status(of: $0, now: now) != .pending }) {
            tickets.remove(at: index)
        }
        // Nothing is shown from here: `ConfirmationCardWindowManager` watches
        // `tickets` and brings its card up on the next run-loop turn.
        return .opened(ticket)
    }

    /// The ONE entry point for a button the owner pressed in Clicky's UI. An
    /// approval counts only when `ApprovalInput.verdict` accepts the evidence;
    /// anything else leaves the ticket pending. Deny is accepted from any source
    /// — saying no cannot harm — but still spends the event it arrived with.
    @discardableResult
    func answerFromPanel(_ id: String, allow: Bool, scope: Scope, evidence: ApprovalInput.Evidence) -> ApprovalInput.Verdict {
        let eventAlreadyUsed = evidence.eventIdentity.map { inputEventsThatReachedAnAnswerButton.contains($0) } ?? false
        if let identity = evidence.eventIdentity, !eventAlreadyUsed {
            inputEventsThatReachedAnAnswerButton.append(identity)
            if inputEventsThatReachedAnAnswerButton.count > Self.rememberedInputEventCount {
                inputEventsThatReachedAnAnswerButton.removeFirst()
            }
        }
        let verdict: ApprovalInput.Verdict = allow ? ApprovalInput.verdict(evidence, eventAlreadyUsed: eventAlreadyUsed) : .accepted
        if verdict == .accepted { answer(id, allow: allow, scope: scope) }
        return verdict
    }

    /// Unchecked: for in-process callers that are not a button (the future voice
    /// path, tests). UI buttons go through `answerFromPanel`, never here.
    func answer(_ id: String, allow: Bool, scope: Scope) {
        guard let index = tickets.firstIndex(where: { $0.id == id }),
              Self.status(of: tickets[index], now: Date()) == .pending else { return }
        tickets[index].status = allow ? .allowed : .denied
        tickets[index].answeredAt = Date()
        // Measured 2026-09-13: a shown panel is Clicky's key window, so the
        // system-wide focused app reads "Clicky" and every `focus Finder` after
        // the click failed to verify — the planner fell to 4/6. When nothing is
        // left to ask, the panel goes away and focus returns to the app in use.
        if pendingCount() == 0 {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .clickyDismissPanel, object: nil) }
        }
        guard allow, scope == .always, Self.offersAlwaysRule(for: tickets[index]) else { return }
        // Read, append, write. A keychain item we cannot read is not one we
        // overwrite — the ticket still allows this once, and every consult keeps
        // reporting the read failure.
        guard case .success(let rules) = rulesStore.load() else { refreshAlwaysRules(); return }
        let rule = Self.rule(for: tickets[index])
        guard !rules.contains(rule) else { return }
        let status = rulesStore.save(rules + [rule])
        refreshAlwaysRules()
        if status != errSecSuccess {
            alwaysRulesProblem = "\"Always\" was not saved (keychain OSStatus \(status)) — it allowed this once only"
        }
    }

    /// Removing a rule only narrows what runs without asking, so unlike an
    /// approval it needs no proof that a human pressed the button.
    func removeAlwaysRule(_ rule: ApprovalRule) {
        let status = rulesStore.remove(rule)
        refreshAlwaysRules()
        if status != errSecSuccess {
            alwaysRulesProblem = "rule not removed (keychain OSStatus \(status))"
        }
    }

    func refreshAlwaysRules() {
        switch rulesStore.load() {
        case .success(let rules):
            if alwaysRules != rules { alwaysRules = rules }
            if alwaysRulesProblem != nil { alwaysRulesProblem = nil }
        case .failure(let failure):
            if !alwaysRules.isEmpty { alwaysRules = [] }
            if alwaysRulesProblem != failure.reason { alwaysRulesProblem = failure.reason }
        }
    }

    /// `spend: false` answers what the gate would decide without marking the
    /// ticket used — a dry run must not cost the caller its one approval.
    func consume(ticket id: String, _ shape: Shape, spend: Bool = true, now: Date = Date()) -> Consumption {
        let index = tickets.firstIndex { $0.id == id }
        let result = Self.consumption(of: index.map { tickets[$0] }, shape, now: now)
        if spend, result == .allowed, let index { tickets[index].consumed = true }
        return result
    }

    /// Marks a pending or allowed, unspent ticket stale. A stale ticket answers
    /// `.stale` from then on — the caller must ask again, and the owner sees why.
    func invalidateAsStale(ticket id: String, movedPart: String, now: Date = Date()) {
        guard let index = tickets.firstIndex(where: { $0.id == id }) else { return }
        let status = Self.status(of: tickets[index], now: now)
        guard status == .pending || (status == .allowed && !tickets[index].consumed) else { return }
        tickets[index].status = .stale
        tickets[index].staleField = movedPart
        tickets[index].answeredAt = now
    }

    /// Consults the keychain every time, like the policy layer: a rule removed
    /// in the panel stops applying on the next request. `unreadable` is set when
    /// the item exists and could not be read or decoded — no rules then, and the
    /// caller must say so. `ignoredFile` is the path of a legacy rules file that
    /// exists and was NOT read.
    func rule(for shape: Shape) -> (rule: ApprovalRule?, unreadable: String?, ignoredFile: String?) {
        // `attributesOfItem` does not follow a final symlink, so a dangling link
        // planted there is reported too.
        let ignoredFile = ignoredApprovalsFileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil ? $0.path : nil
        }
        switch rulesStore.load() {
        case .success(let rules): return (Self.matchingRule(in: rules, shape), nil, ignoredFile)
        case .failure(let failure): return (nil, failure.reason, ignoredFile)
        }
    }
}
