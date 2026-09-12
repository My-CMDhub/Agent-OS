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

import Combine
import Foundation

extension Notification.Name {
    static let clickyShowPanel = Notification.Name("clickyShowPanel")
}

final class HarnessConfirmations: ObservableObject {

    enum Status: String { case pending, allowed, denied, expired }
    enum Scope: String { case once, always }

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
        let appName: String?
        let bundleIdentifier: String
        let reason: String
        var status: Status
        var answeredAt: Date?
        /// One ticket, one action. Status stays `allowed` so the panel can still
        /// show the answer; this flag is what refuses a second use.
        var consumed = false

        var expiresAt: Date { createdAt.addingTimeInterval(HarnessConfirmations.ticketLifetimeInSeconds) }
    }

    /// The shape of one request, as far as a ticket or a rule is concerned.
    struct Shape: Equatable {
        let verb: String
        let bundleIdentifier: String?
        let rawTarget: String
        var text: String? = nil
        var mode: String? = nil
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
    struct ApprovalRule: Codable, Equatable {
        let bundleIdentifier: String
        let verb: String
        let target: String?
        var text: String? = nil
    }

    static let ticketLifetimeInSeconds: TimeInterval = 60
    /// More than this many open questions is not a queue, it is a way to get a
    /// click on the wrong one.
    static let maximumPendingTickets = 3
    /// Verbs whose "always" rule covers the whole app: their target IS the app.
    static let appWideRuleVerbs: Set<String> = ["focus", "launch"]

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
        if ticket.verb != shape.verb { return "verb" }
        if !sameBundleIdentifier(ticket.bundleIdentifier, shape.bundleIdentifier) { return "bundleIdentifier" }
        if ticket.rawTarget != shape.rawTarget { return "target" }
        if shape.verb == "type" {
            if ticket.text != shape.text { return "text" }
            if ticket.mode != shape.mode { return "mode" }
        }
        return nil
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
    static func openRefusal(for shape: Shape, pendingCount: Int) -> (code: String, message: String)? {
        if shape.rawTarget.isEmpty {
            return ("confirmationTargetUnnamed", "the request names no target, so a ticket for it would authorise anything")
        }
        if (shape.bundleIdentifier ?? "").isEmpty {
            return ("confirmationAppUnidentified", "the application has no bundle identifier, so a ticket could not be scoped to it")
        }
        if pendingCount >= maximumPendingTickets {
            return ("tooManyPendingConfirmations",
                    "\(pendingCount) tickets are already waiting in the Clicky panel — answer or let them expire first")
        }
        return nil
    }

    /// Bundle id case-insensitive, verb exact, target and text exact when the rule has them.
    static func matchingRule(in rules: [ApprovalRule], _ shape: Shape) -> ApprovalRule? {
        rules.first { rule in
            rule.verb == shape.verb
                && sameBundleIdentifier(rule.bundleIdentifier, shape.bundleIdentifier)
                && (rule.target == nil || rule.target == shape.rawTarget)
                && (rule.text == nil || rule.text == shape.text)
        }
    }

    /// The rule an "always" answer to this ticket creates: this action in this
    /// app — except `focus`/`launch`, whose action is the app.
    static func rule(for ticket: Ticket) -> ApprovalRule {
        let appWide = appWideRuleVerbs.contains(ticket.verb)
        return ApprovalRule(
            bundleIdentifier: ticket.bundleIdentifier, verb: ticket.verb,
            target: appWide ? nil : ticket.rawTarget,
            text: appWide ? nil : ticket.text
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
        if let refusal = Self.openRefusal(for: shape, pendingCount: pending) {
            return .refused(code: refusal.code, message: refusal.message)
        }
        let ticket = Ticket(
            id: UUID().uuidString, createdAt: now, verb: shape.verb,
            rawTarget: shape.rawTarget, target: UntrustedText(shape.rawTarget).forDisplay,
            text: shape.text, mode: shape.mode,
            appName: appName.map { UntrustedText($0).forDisplay },
            bundleIdentifier: shape.bundleIdentifier ?? "", reason: reason, status: .pending
        )
        tickets.insert(ticket, at: 0)
        // At most 20: evict the oldest answered/expired first, never a pending one.
        while tickets.count > 20,
              let index = tickets.lastIndex(where: { Self.status(of: $0, now: now) != .pending }) {
            tickets.remove(at: index)
        }
        // Posted on the NEXT run-loop turn, never inside the request: showing
        // the panel pumps the run loop, and a second socket request would land
        // inside the first. And only when the panel is not already asking.
        if pending == 0 {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .clickyShowPanel, object: nil) }
        }
        return .opened(ticket)
    }

    func answer(_ id: String, allow: Bool, scope: Scope) {
        guard let index = tickets.firstIndex(where: { $0.id == id }),
              Self.status(of: tickets[index], now: Date()) == .pending else { return }
        tickets[index].status = allow ? .allowed : .denied
        tickets[index].answeredAt = Date()
        guard allow, scope == .always else { return }
        // Read, append, write: the file is the store, so a hand-edit made after
        // launch survives. A file we cannot read is not one we overwrite — the
        // ticket still allows this once, and every consult keeps reporting it.
        guard case .success(var rules) = Self.loadApprovals(from: approvalsURL) else { return }
        let rule = Self.rule(for: tickets[index])
        guard !rules.contains(rule), let data = try? JSONEncoder().encode(rules + [rule]) else { return }
        rules.append(rule)
        try? FileManager.default.createDirectory(
            at: approvalsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: approvalsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: approvalsURL.path)
    }

    func consume(ticket id: String, _ shape: Shape, now: Date = Date()) -> Consumption {
        let index = tickets.firstIndex { $0.id == id }
        let result = Self.consumption(of: index.map { tickets[$0] }, shape, now: now)
        if result == .allowed, let index { tickets[index].consumed = true }
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
