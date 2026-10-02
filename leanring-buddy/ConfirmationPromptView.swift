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
    enum Style: Equatable {
        /// The menu-bar panel: every line in mono, answered rows kept a while.
        case panel
        /// The card under the notch: pending tickets only, laid out by line kind.
        case card(step: ConfirmationStep?)
    }

    @ObservedObject var confirmations: HarnessConfirmations
    var style: Style = .panel
    /// The menu-bar panel keeps answered and expired rows for a while; the
    /// floating card asks only what is still open.
    private var includesAnsweredTickets: Bool { style == .panel }

    /// The card's sections, top to bottom. Every `CardLine.Kind` is here (a test
    /// holds it), so no line a ticket binds can be left off the card.
    static let cardSections: [HarnessConfirmations.CardLine.Kind] = [.verb, .preview, .place, .qualifier, .effect]
    /// Why the last approval pressed on a ticket did not count, by ticket id.
    /// Every reason is our own words and numbers — no app-written text.
    @State private var approvalRejections: [String: String] = [:]
    /// Where each row and this view's window sit, for `minimumRowSettledSeconds`.
    @State private var placementTracker = ConfirmationPlacementTracker()

    static let inputLogFileName = "confirmation-input.log"

    /// One line per button press with the event that delivered it and the
    /// verdict `HarnessConfirmations.ApprovalInput` gave — no ticket content,
    /// only its id.
    static func recordInput(button: String, ticketID: String, event: NSEvent?,
                            evidence: HarnessConfirmations.ApprovalInput.Evidence,
                            verdict: HarnessConfirmations.ApprovalInput.Verdict) {
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
            "eventAgeMilliseconds": evidence.eventAgeSeconds.map { $0 * 1000 } ?? NSNull(),
            "clickCount": evidence.clickCount,
            "eventWindowNumber": evidence.eventWindowNumber ?? NSNull(),
            "hostWindowNumber": evidence.hostWindowNumber ?? NSNull(),
            "rowSettledMilliseconds": evidence.rowSettledSeconds.map { $0 * 1000 } ?? NSNull(),
            // Both numbers of the inside-the-button check, so the first real click
            // shows whether the two coordinate spaces actually agree.
            "clickTopLeft": evidence.clickLocationInWindow.flatMap { location in
                evidence.hostContentHeight.map { height in
                    let point = HarnessConfirmations.ApprovalInput.topLeftPoint(fromWindowPoint: location, contentHeight: height)
                    return [point.x, point.y]
                }
            } ?? NSNull(),
            "pressedButtonFrame": evidence.pressedButtonFrame.map {
                [$0.minX, $0.minY, $0.width, $0.height]
            } ?? NSNull(),
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
            case .allowed, .denied, .stale: return includesAnswered && now.timeIntervalSince(ticket.answeredAt ?? now) < lingerInSeconds
            }
        }
    }

    static func buttonFrameKey(_ ticketID: String, _ button: String) -> String { "\(ticketID)|\(button)" }

    /// Records a button's frame in the hosting view's top-left space, so a click
    /// is counted only when it landed inside the button that was pressed.
    private func recordsFrame(of button: String, ticketID: String) -> some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                placementTracker.buttonFrames[Self.buttonFrameKey(ticketID, button)] = frame
            }
        }
    }

    /// Every button lands here, so the input check cannot be forgotten on one of them.
    private func press(_ button: String, _ ticket: HarnessConfirmations.Ticket, allow: Bool, scope: HarnessConfirmations.Scope) {
        let event = NSApp.currentEvent
        let nowUptime = ProcessInfo.processInfo.systemUptime
        // Re-read the window here too: a move or show whose notification never
        // came still resets its clock (an unchanged window keeps its clock).
        placementTracker.windowChanged()
        let evidence = HarnessConfirmations.ApprovalInput.Evidence.gathered(
            from: event,
            hostWindowNumber: placementTracker.hostWindow?.windowNumber,
            rowSettledSeconds: ScreenPlacement.settledSeconds(
                row: placementTracker.rowPlacements[ticket.id], window: placementTracker.windowPlacement, nowUptime: nowUptime
            ),
            // Both panels host the SwiftUI tree as the window's content view, so
            // `.global` frames and this height share one space.
            hostContentHeight: placementTracker.hostWindow?.contentView?.bounds.height,
            pressedButtonFrame: placementTracker.buttonFrames[Self.buttonFrameKey(ticket.id, button)],
            nowUptime: nowUptime
        )
        let verdict = confirmations.answerFromPanel(ticket.id, allow: allow, scope: scope, evidence: evidence)
        Self.recordInput(button: button, ticketID: ticket.id, event: event, evidence: evidence, verdict: verdict)
        if case .rejected(let reason) = verdict { approvalRejections[ticket.id] = reason } else { approvalRejections[ticket.id] = nil }
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
                    if case .card(let step) = style {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, ticket in
                                if index > 0 { Rectangle().fill(ConfirmationCardStyle.ink.opacity(0.1)).frame(height: 1) }
                                cardRow(ticket, step: step, now: context.date)
                            }
                        }
                        .background(HostWindowReader(tracker: placementTracker))
                    } else {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            ForEach(visible) { ticket in
                                row(ticket, now: context.date)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .background(HostWindowReader(tracker: placementTracker))
                    }
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
                        .background(recordsFrame(of: "allowOnce", ticketID: ticket.id))
                    // The lines above are the definition of "exactly this".
                    // For focus/launch the rule is app-wide, and the label says so.
                    if HarnessConfirmations.offersAlwaysRule(for: ticket) {
                        Button(HarnessConfirmations.alwaysButtonTitle(for: ticket)) { press("always", ticket, allow: true, scope: .always) }
                            .background(recordsFrame(of: "always", ticketID: ticket.id))
                    }
                    Button("Deny") { press("deny", ticket, allow: false, scope: .once) }
                        .tint(DS.Colors.destructive)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let rejection = approvalRejections[ticket.id] {
                    Text(verbatim: "Not counted: \(rejection)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(status == .stale ? "stale — ask again (the \(ticket.staleField ?? "binding") changed)" : status.rawValue)
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
        .modifier(TracksRowPlacement(ticketID: ticket.id, tracker: placementTracker))
    }

    // MARK: Card

    private static let ink = ConfirmationCardStyle.ink
    private static let labelWidth: CGFloat = 58

    /// One ticket on the card. Pending only (the card never shows answered rows).
    @ViewBuilder
    private func cardRow(_ ticket: HarnessConfirmations.Ticket, step: ConfirmationStep?, now: Date) -> some View {
        let lines = ticket.cardLines
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.cardSections, id: \.self) { kind in
                cardSection(kind, lines.filter { $0.kind == kind }.map(\.text), ticket: ticket)
            }
            // The kernel's reason, as before: why it asked.
            labelled("WHY", Text(ticket.reason).font(.system(size: 12)).foregroundStyle(Self.ink.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true))
            if let rejection = approvalRejections[ticket.id] {
                Text(verbatim: "Not counted: \(rejection)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let step {
                    Text(verbatim: "Doing \u{00B7} step \(step.current)/\(step.total)")
                        .font(.system(size: 12))
                        .foregroundStyle(Self.ink.opacity(0.62))
                }
                Spacer(minLength: 0)
                Button { press("deny", ticket, allow: false, scope: .once) } label: {
                    Text("Deny")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Self.ink)
                        .frame(width: 96, height: 32)
                        .overlay(Capsule().stroke(Self.ink.opacity(0.6), lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { press("allowOnce", ticket, allow: true, scope: .once) } label: {
                    Text("Allow once")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ConfirmationCardStyle.material)
                        .frame(width: 108, height: 32)
                        .background(Capsule().fill(Self.ink))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(recordsFrame(of: "allowOnce", ticketID: ticket.id))
            }
            // The quieter third control, only where today's card offered it: a
            // destructive question is Allow once and Deny only.
            if HarnessConfirmations.offersAlwaysRule(for: ticket) {
                HStack {
                    Spacer(minLength: 0)
                    Button { press("always", ticket, allow: true, scope: .always) } label: {
                        Text(HarnessConfirmations.alwaysButtonTitle(for: ticket))
                            .font(.system(size: 11))
                            .underline()
                            .foregroundStyle(Self.ink.opacity(0.62))
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(recordsFrame(of: "always", ticketID: ticket.id))
                }
            }
        }
        .padding(22)
        .modifier(TracksRowPlacement(ticketID: ticket.id, tracker: placementTracker))
    }

    @ViewBuilder
    private func cardSection(_ kind: HarnessConfirmations.CardLine.Kind, _ texts: [String],
                             ticket: HarnessConfirmations.Ticket) -> some View {
        if !texts.isEmpty {
            switch kind {
            case .verb:
                HStack(alignment: .center, spacing: 12) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Self.ink, lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: Self.symbol(for: ticket.verb))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Self.ink))
                    (Text("J.A.R.V.I.S. wants to ") + Text(texts.joined(separator: " ")).fontWeight(.semibold))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Self.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    CountdownRing(expiresAt: ticket.expiresAt)
                }
            case .preview:
                // Whole, never cut: `open` refused anything too long to show in full.
                ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Self.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .place:
                labelled("WHERE", monoLines(texts, opacity: 0.8))
            case .qualifier:
                labelled("", monoLines(texts, opacity: 0.5))
            case .effect:
                labelled("EFFECT", VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(Self.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                })
            }
        }
    }

    private func monoLines(_ texts: [String], opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Self.ink.opacity(opacity))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labelled(_ label: String, _ value: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.ink.opacity(0.62))
                .frame(width: Self.labelWidth, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
    }

    /// The icon tile: our own verb, never app-written.
    static func symbol(for verb: String) -> String {
        switch verb {
        case "type": return "keyboard"
        case "menu": return "filemenu.and.selection"
        case "focus": return "macwindow"
        case "launch": return "app"
        case "openURL": return "globe"
        case "scroll": return "arrow.up.and.down"
        case "select": return "checkmark.circle"
        default: return "cursorarrow.click"
        }
    }
}

/// The 60 s ring, drawn from the ticket's own `expiresAt` — never a timer of its own.
private struct CountdownRing: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = remaining / HarnessConfirmations.ticketLifetimeInSeconds
            ZStack {
                Circle().stroke(ConfirmationCardStyle.ink.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ConfirmationCardStyle.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: "\(Int(remaining.rounded(.up)))")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(ConfirmationCardStyle.ink.opacity(0.62))
            }
            .frame(width: 26, height: 26)
            .accessibilityLabel("\(Int(remaining.rounded(.up))) seconds left")
        }
    }
}

/// A row's top-left in window coordinates. Any move — a row above it answered
/// and dropped, the card re-laid-out for a new ticket — restarts its clock, so
/// a click aimed at one ticket cannot count on another that slid under the
/// pointer. Origin, not frame: the rejection line growing below the buttons
/// changes the height and moves nothing clickable.
private struct TracksRowPlacement: ViewModifier {
    let ticketID: String
    let tracker: ConfirmationPlacementTracker

    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global).origin, initial: true) { _, origin in
                tracker.rowPlacements[ticketID] = ScreenPlacement.after(
                    tracker.rowPlacements[ticketID], origin: origin, nowUptime: ProcessInfo.processInfo.systemUptime
                )
            }
        })
    }
}

/// Where something has sat, and since when (seconds since boot, the clock
/// `NSEvent.timestamp` uses).
struct ScreenPlacement: Equatable {
    let origin: CGPoint
    let sinceUptime: TimeInterval

    /// An unchanged origin keeps its clock; any move starts a new one.
    static func after(_ previous: ScreenPlacement?, origin: CGPoint, nowUptime: TimeInterval) -> ScreenPlacement {
        if let previous, previous.origin == origin { return previous }
        return ScreenPlacement(origin: origin, sinceUptime: nowUptime)
    }

    /// How long a row has been still inside a still, visible window. nil when
    /// either is unknown — the verdict refuses that rather than guessing.
    static func settledSeconds(row: ScreenPlacement?, window: ScreenPlacement?, nowUptime: TimeInterval) -> TimeInterval? {
        guard let row, let window else { return nil }
        return nowUptime - max(row.sinceUptime, window.sinceUptime)
    }
}

/// The window a `ConfirmationPromptView` is drawn in, and how long it has been
/// visible at its current top-left. A row's origin is window-relative, so a
/// card that jumps to another screen, or a panel ordered out and back in, keeps
/// every row origin identical — only the window's own clock sees it.
final class ConfirmationPlacementTracker {
    private(set) weak var hostWindow: NSWindow?
    /// nil while the window is not visible.
    private(set) var windowPlacement: ScreenPlacement?
    var rowPlacements: [String: ScreenPlacement] = [:]
    /// Answer buttons by `ConfirmationPromptView.buttonFrameKey`, SwiftUI `.global`.
    var buttonFrames: [String: CGRect] = [:]
    private var windowObservers: [NSObjectProtocol] = []

    func attach(to window: NSWindow?) {
        guard window !== hostWindow else { return }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        hostWindow = window
        windowPlacement = nil
        guard let window else { return }
        let names = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            // queue nil: delivered synchronously on the posting thread, which for
            // these is main — so the clock resets before the next click is handled.
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowChanged() }
            })
        }
        windowChanged()
    }

    func windowChanged() {
        guard let window = hostWindow, window.occlusionState.contains(.visible) else {
            windowPlacement = nil
            return
        }
        // Top-left, in AppKit screen coordinates: the card is top-anchored, so a
        // taller card for a new ticket keeps this point and its rows' clocks.
        windowPlacement = ScreenPlacement.after(
            windowPlacement, origin: CGPoint(x: window.frame.minX, y: window.frame.maxY),
            nowUptime: ProcessInfo.processInfo.systemUptime
        )
    }
}

/// Reports the hosting window to the tracker whenever this view joins or leaves one.
private struct HostWindowReader: NSViewRepresentable {
    let tracker: ConfirmationPlacementTracker
    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.tracker = tracker
        return view
    }
    func updateNSView(_ nsView: WindowReportingView, context: Context) {}
}

private final class WindowReportingView: NSView {
    weak var tracker: ConfirmationPlacementTracker?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.attach(to: window)
    }
    /// Sits behind the rows; never takes a click meant for them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
