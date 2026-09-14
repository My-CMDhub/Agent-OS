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

final class HarnessConfirmations: ObservableObject {

    enum Status: String { case pending, allowed, denied, expired }
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
    enum ApprovalInput {
        enum Verdict: Equatable {
            case accepted
            case rejected(reason: String)
        }

        static let humanInputEventTypes: Set<NSEvent.EventType> = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .keyDown, .keyUp
        ]

        static func verdict(eventType: NSEvent.EventType?, sourceProcessID: Int64?) -> Verdict {
            guard let eventType else {
                return .rejected(reason: "no input event (programmatic press, e.g. Accessibility)")
            }
            guard humanInputEventTypes.contains(eventType) else {
                return .rejected(reason: "event type \(eventType.rawValue) is not a mouse button or key")
            }
            guard let sourceProcessID else {
                return .rejected(reason: "event carries no source process")
            }
            guard sourceProcessID == 0 else {
                return .rejected(reason: "posted by process \(sourceProcessID)")
            }
            return .accepted
        }

        static func verdict(for event: NSEvent?) -> Verdict {
            verdict(eventType: event?.type, sourceProcessID: event?.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID))
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
    }

    enum OpenResult: Equatable {
        case opened(Ticket)
        /// A wire error code and its message.
        case refused(code: String, message: String)
    }

    /// nil target = any target for that verb in that app; nil text = any text.
    /// Those two wildcards exist for hand-written rules. The qualifiers below
    /// are NOT wildcards: nil means "the approved request had none". Before
    /// 2026-09-14 a rule kept only app+verb+target+text, so "Always press Delete
    /// within Drafts" allowed Delete within any container — the defect the
    /// ticket had before review. A rule on disk from before then decodes these
    /// as nil and so matches only an unqualified request: narrower, never
    /// broader. (An old `type` rule has no `mode` and so matches no `type`
    /// request at all until re-approved.)
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

    @Published private(set) var tickets: [Ticket] = []   // newest first

    private let approvalsURL: URL

    init(approvalsURL: URL) {
        self.approvalsURL = approvalsURL
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

    static func consumption(of ticket: Ticket?, _ shape: Shape, now: Date) -> Consumption {
        guard let ticket else { return .unknown }
        if let field = mismatchedField(ticket, shape) { return .mismatch(field: field) }
        switch status(of: ticket, now: now) {
        case .pending: return .pending
        case .denied: return .denied
        case .expired: return .expired
        case .allowed: return ticket.consumed ? .consumed : .allowed
        }
    }

    /// Why a ticket may not be opened for this shape, or nil.
    static func openRefusal(for shape: Shape, appName: String? = nil, pendingCount: Int) -> (code: String, message: String)? {
        if shape.rawTarget.isEmpty {
            return ("confirmationTargetUnnamed", "the request names no target, so a ticket for it would authorise anything")
        }
        if (shape.bundleIdentifier ?? "").isEmpty {
            return ("confirmationAppUnidentified", "the application has no bundle identifier, so a ticket could not be scoped to it")
        }
        if let longest = displayLines(for: shape, appName: appName).map(\.count).max(), longest > maximumDisplayLineLength {
            return ("confirmationTooLongToShow",
                    "a line of the question is \(longest) characters and the panel shows at most \(maximumDisplayLineLength) in full — the owner cannot approve what they cannot read")
        }
        if pendingCount >= maximumPendingTickets {
            return ("tooManyPendingConfirmations",
                    "\(pendingCount) tickets are already waiting in the Clicky panel — answer or let them expire first")
        }
        return nil
    }

    /// Bundle id case-insensitive, verb exact, target and text exact when the
    /// rule has them, and every qualifier exact — through the same
    /// `mismatchedField` a ticket uses. `focus`/`launch` stay app-wide.
    static func matchingRule(in rules: [ApprovalRule], _ shape: Shape) -> ApprovalRule? {
        rules.first { rule in
            if appWideRuleVerbs.contains(rule.verb), rule.target == nil {
                return rule.verb == shape.verb && sameBundleIdentifier(rule.bundleIdentifier, shape.bundleIdentifier)
            }
            let approved = Shape(
                verb: rule.verb, bundleIdentifier: rule.bundleIdentifier,
                rawTarget: rule.target ?? shape.rawTarget, text: rule.text ?? shape.text, mode: rule.mode,
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

    /// Missing file = no rules. Anything else that is not a clean parse is a reason.
    static func loadApprovals(from url: URL) -> Result<[ApprovalRule], HarnessAppPolicy.ParseFailure> {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .success([])
        } catch {
            return .failure(.init(reason: "\(url.path): \(error.localizedDescription)"))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.init(reason: "\(url.path): unreadable"))
        }
        return parseApprovals(data).mapError { .init(reason: "\(url.path): \($0.reason)") }
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

    func open(_ shape: Shape, appName: String?, reason: String) -> OpenResult {
        let now = Date()
        let pending = pendingCount(now: now)
        if let refusal = Self.openRefusal(for: shape, appName: appName, pendingCount: pending) {
            return .refused(code: refusal.code, message: refusal.message)
        }
        let ticket = Ticket(
            id: UUID().uuidString, createdAt: now, verb: shape.verb,
            rawTarget: shape.rawTarget, target: UntrustedText(shape.rawTarget).forDisplay,
            text: shape.text, mode: shape.mode,
            withinNamed: shape.withinNamed, nearPoint: shape.nearPoint, role: shape.role, thenConfirm: shape.thenConfirm,
            appName: appName.map { UntrustedText($0).forDisplay },
            bundleIdentifier: shape.bundleIdentifier ?? "", reason: reason, status: .pending,
            displayLines: Self.displayLines(for: shape, appName: appName)
        )
        tickets.insert(ticket, at: 0)
        // At most 20: evict the oldest answered/expired first, never a pending one.
        while tickets.count > 20,
              let index = tickets.lastIndex(where: { Self.status(of: $0, now: now) != .pending }) {
            tickets.remove(at: index)
        }
        // Nothing is shown from here: `ConfirmationCardWindowManager` watches
        // `tickets` and brings its card up on the next run-loop turn.
        return .opened(ticket)
    }

    /// The ONE entry point for a button the owner pressed in Clicky's UI. An
    /// approval counts only when the triggering event came through the HID
    /// layer (`ApprovalInput`); anything else leaves the ticket pending. Deny is
    /// accepted from any source — saying no cannot harm.
    @discardableResult
    func answerFromPanel(_ id: String, allow: Bool, scope: Scope, triggeringEvent: NSEvent?) -> ApprovalInput.Verdict {
        let verdict: ApprovalInput.Verdict = allow ? ApprovalInput.verdict(for: triggeringEvent) : .accepted
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
        guard allow, scope == .always else { return }
        // Read, append, write: the file is the store, so a hand-edit made after
        // launch survives. A file we cannot read is not one we overwrite — the
        // ticket still allows this once, and every consult keeps reporting it.
        guard case .success(let rules) = Self.loadApprovals(from: approvalsURL) else { return }
        let rule = Self.rule(for: tickets[index])
        guard !rules.contains(rule), let data = try? JSONEncoder().encode(rules + [rule]) else { return }
        try? FileManager.default.createDirectory(
            at: approvalsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: approvalsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: approvalsURL.path)
    }

    /// `spend: false` answers what the gate would decide without marking the
    /// ticket used — a dry run must not cost the caller its one approval.
    func consume(ticket id: String, _ shape: Shape, spend: Bool = true, now: Date = Date()) -> Consumption {
        let index = tickets.firstIndex { $0.id == id }
        let result = Self.consumption(of: index.map { tickets[$0] }, shape, now: now)
        if spend, result == .allowed, let index { tickets[index].consumed = true }
        return result
    }

    /// Consults the file every time, like the policy layer: a hand-edit applies
    /// to the next request. `unreadable` is set when the file exists and could
    /// not be read or parsed — no rules then, and the caller must say so.
    func rule(for shape: Shape) -> (rule: ApprovalRule?, unreadable: String?) {
        switch Self.loadApprovals(from: approvalsURL) {
        case .success(let rules): return (Self.matchingRule(in: rules, shape), nil)
        case .failure(let failure): return (nil, failure.reason)
        }
    }
}
