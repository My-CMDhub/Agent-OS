//
//  ConfirmationPromptView.swift
//  leanring-buddy
//
//  The in-process half of a harness confirmation: the kernel asked, the socket
//  could not answer, so the question lands here. Every string shown is either
//  ours or already escaped by `HarnessConfirmations.displayLines`.
//

import AppKit
import SwiftUI

struct ConfirmationPromptView: View {
    @ObservedObject var confirmations: HarnessConfirmations
    /// The menu-bar panel keeps answered and expired rows for a while; the
    /// floating card asks only what is still open.
    var includesAnsweredTickets = true
    /// Tickets whose approval was pressed by something that is not the HID layer.
    @State private var approvalsRefused: Set<String> = []

    static let inputLogFileName = "confirmation-input.log"

    /// One line per button press with the event that delivered it and the
    /// verdict `HarnessConfirmations.ApprovalInput` gave — no ticket content,
    /// only its id.
    static func recordInput(button: String, ticketID: String, event: NSEvent?, verdict: HarnessConfirmations.ApprovalInput.Verdict) {
        let cgEvent = event?.cgEvent
        var rejectionReason: Any = NSNull()
        if case .rejected(let reason) = verdict { rejectionReason = reason }
        MeasurementLogFile.appendJSONLine([
            "button": button,
            "ticket": ticketID,
            "verdict": verdict == .accepted ? "accepted" : "rejected",
            "rejectionReason": rejectionReason,
            "eventType": event.map { $0.type.rawValue } ?? NSNull(),
            "modifierFlags": event.map { $0.modifierFlags.rawValue } ?? NSNull(),
            "eventSourceUnixProcessID": cgEvent.map { $0.getIntegerValueField(.eventSourceUnixProcessID) } ?? NSNull(),
            "eventSourceStateID": cgEvent.map { $0.getIntegerValueField(.eventSourceStateID) } ?? NSNull(),
            "eventSourceUserData": cgEvent.map { $0.getIntegerValueField(.eventSourceUserData) } ?? NSNull(),
            // Both on systemUptime: NSEvent.timestamp is seconds since boot.
            "eventAgeMilliseconds": event.map { (ProcessInfo.processInfo.systemUptime - $0.timestamp) * 1000 } ?? NSNull(),
            "pressedMouseButtons": NSEvent.pressedMouseButtons,
            "uptime": MeasurementLogFile.roundedUptime(ProcessInfo.processInfo.systemUptime)
        ], toFileNamed: inputLogFileName)
    }

    /// How long an answered or expired ticket stays visible.
    static let lingerInSeconds: TimeInterval = 20

    static func visibleTickets(_ tickets: [HarnessConfirmations.Ticket], now: Date, includesAnswered: Bool = true) -> [HarnessConfirmations.Ticket] {
        tickets.filter { ticket in
            switch HarnessConfirmations.status(of: ticket, now: now) {
            case .pending: return true
            case .expired: return includesAnswered && now.timeIntervalSince(ticket.expiresAt) < lingerInSeconds
            case .allowed, .denied: return includesAnswered && now.timeIntervalSince(ticket.answeredAt ?? now) < lingerInSeconds
            }
        }
    }

    /// Every button lands here, so the input check cannot be forgotten on one of them.
    private func press(_ button: String, _ ticket: HarnessConfirmations.Ticket, allow: Bool, scope: HarnessConfirmations.Scope) {
        let event = NSApp.currentEvent
        let verdict = confirmations.answerFromPanel(ticket.id, allow: allow, scope: scope, triggeringEvent: event)
        Self.recordInput(button: button, ticketID: ticket.id, event: event, verdict: verdict)
        if verdict == .accepted { approvalsRefused.remove(ticket.id) } else { approvalsRefused.insert(ticket.id) }
    }

    var body: some View {
        if confirmations.tickets.isEmpty {
            EmptyView()
        } else {
            // A one-second clock so a ticket greys out when it expires, not when
            // something else happens to redraw the panel.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let visible = Self.visibleTickets(confirmations.tickets, now: context.date, includesAnswered: includesAnsweredTickets)
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        ForEach(visible) { ticket in
                            row(ticket, now: context.date)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ ticket: HarnessConfirmations.Ticket, now: Date) -> some View {
        let status = HarnessConfirmations.status(of: ticket, now: now)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Clicky asks to:")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status == .pending ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            // Exactly the lines the ticket binds, computed once at `open` — this
            // view never reads the fields itself, so it cannot show less than is
            // approved. No lineLimit: a cut line is a prefix of the question, and
            // `open` already refused anything too long to show whole.
            ForEach(Array(ticket.displayLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Colors.codeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ticket.reason)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if status == .pending {
                HStack(spacing: DS.Spacing.sm) {
                    Button("Allow once") { press("allowOnce", ticket, allow: true, scope: .once) }
                    // The lines above are the definition of "exactly this".
                    Button("Always allow exactly this") { press("always", ticket, allow: true, scope: .always) }
                    Button("Deny") { press("deny", ticket, allow: false, scope: .once) }
                        .tint(DS.Colors.destructive)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if approvalsRefused.contains(ticket.id) {
                    Text("Allow needs a real click")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.warning)
                }
            } else {
                Text(status.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(status == .allowed ? DS.Colors.success
                                     : status == .denied ? DS.Colors.destructiveText : DS.Colors.textTertiary)
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
            .stroke(status == .pending ? DS.Colors.warning : DS.Colors.borderSubtle, lineWidth: 1))
    }
}

/// The rules an "Always" answer created. They live in the data-protection
/// keychain, which the `security` CLI cannot reach, so this list is the only
/// way to revoke one. Remove needs no hardware click: it only narrows.
struct AlwaysRulesListView: View {
    @ObservedObject var confirmations: HarnessConfirmations

    var body: some View {
        Group {
            if !confirmations.alwaysRules.isEmpty || confirmations.alwaysRulesProblem != nil {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Always rules")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    if let problem = confirmations.alwaysRulesProblem {
                        Text(problem)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(confirmations.alwaysRules.enumerated()), id: \.offset) { _, rule in
                        HStack(alignment: .top, spacing: DS.Spacing.sm) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(HarnessConfirmations.displayLines(for: rule).enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(DS.Colors.codeText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                            Button("Remove") { confirmations.removeAlwaysRule(rule) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        // The panel outlives many requests; re-read when it is shown.
        .onAppear { confirmations.refreshAlwaysRules() }
    }
}
