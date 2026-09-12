//
//  ConfirmationPromptView.swift
//  leanring-buddy
//
//  The in-process half of a harness confirmation: the kernel asked, the socket
//  could not answer, so the question lands here. Every string shown is either
//  ours or already `UntrustedText.forDisplay` (see `HarnessConfirmations.Ticket`).
//

import SwiftUI

struct ConfirmationPromptView: View {
    @ObservedObject var confirmations: HarnessConfirmations

    /// How long an answered or expired ticket stays visible.
    static let lingerInSeconds: TimeInterval = 20

    static func visibleTickets(_ tickets: [HarnessConfirmations.Ticket], now: Date) -> [HarnessConfirmations.Ticket] {
        tickets.filter { ticket in
            switch HarnessConfirmations.status(of: ticket, now: now) {
            case .pending: return true
            case .expired: return now.timeIntervalSince(ticket.expiresAt) < lingerInSeconds
            case .allowed, .denied: return now.timeIntervalSince(ticket.answeredAt ?? now) < lingerInSeconds
            }
        }
    }

    var body: some View {
        if confirmations.tickets.isEmpty {
            EmptyView()
        } else {
            // A one-second clock so a ticket greys out when it expires, not when
            // something else happens to redraw the panel.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let visible = Self.visibleTickets(confirmations.tickets, now: context.date)
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
        let appName = ticket.appName ?? ticket.bundleIdentifier
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Clicky wants to \(ticket.verb) \(ticket.target)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status == .pending ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            if let text = ticket.text {
                Text("text: \(UntrustedText(text).forDisplay) (\(ticket.mode ?? "insert"))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Colors.codeText)
                    .lineLimit(2)
            }
            Text("in \(appName) — \(ticket.reason)")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(3)

            if status == .pending {
                HStack(spacing: DS.Spacing.sm) {
                    Button("Allow once") { confirmations.answer(ticket.id, allow: true, scope: .once) }
                    Button("Always for this action in \(appName)") {
                        confirmations.answer(ticket.id, allow: true, scope: .always)
                    }
                    Button("Deny") { confirmations.answer(ticket.id, allow: false, scope: .once) }
                        .tint(DS.Colors.destructive)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
