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
    /// holds it), so no line a ticket binds can be left off the card. The first
    /// group is always drawn; the second opens under Details.
    static let alwaysVisibleSections: [HarnessConfirmations.CardLine.Kind] = [.question, .warning, .preview, .place]
    static let detailSections: [HarnessConfirmations.CardLine.Kind] = [.qualifier, .effect]
    static var cardSections: [HarnessConfirmations.CardLine.Kind] { alwaysVisibleSections + detailSections }
    /// Opening Details or a long preview moves the buttons; the move is this
    /// long and `minimumRowSettledSeconds` outlasts it (a test holds that).
    static let expandSeconds: TimeInterval = 0.2
    /// Tickets whose Details, or whose whole typed text, the owner opened.
    @State private var openDetails: Set<String> = []
    @State private var openPreviews: Set<String> = []
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
                let key = Self.buttonFrameKey(ticketID, button)
                placementTracker.buttonFrames[key] = frame
                // A button that moved (Details opened, a preview expanded) starts
                // its clock again: its recorded frame is where it is going, not
                // where it is drawn mid-move.
                placementTracker.buttonPlacements[key] = ScreenPlacement.after(
                    placementTracker.buttonPlacements[key], origin: frame.origin, nowUptime: ProcessInfo.processInfo.systemUptime)
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
                row: placementTracker.rowPlacements[ticket.id], window: placementTracker.windowPlacement,
                button: placementTracker.buttonPlacements[Self.buttonFrameKey(ticket.id, button)], nowUptime: nowUptime
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
    /// Icon tile plus its gap: the lines under the question start here.
    private static let textInset: CGFloat = 40

    /// One ticket on the card. Pending only (the card never shows answered rows).
    /// Owner's layout 2026-10-05: question + countdown, where, Details, buttons.
    @ViewBuilder
    private func cardRow(_ ticket: HarnessConfirmations.Ticket, step: ConfirmationStep?, now: Date) -> some View {
        let texts = { (kind: HarnessConfirmations.CardLine.Kind) in ticket.cardLines.filter { $0.kind == kind }.map(\.text) }
        let detailsOpen = openDetails.contains(ticket.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Self.ink, lineWidth: 1.5)
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: Self.symbol(for: ticket.verb))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Self.ink))
                Text(texts(.question).joined(separator: " "))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                CountdownRing(expiresAt: ticket.expiresAt)
            }
            VStack(alignment: .leading, spacing: 6) {
                // No colour (cyan means proof, and the card is notch black): a glyph
                // and weight mark it, and the second chime already sounded.
                ForEach(Array(texts(.warning).enumerated()), id: \.offset) { _, text in
                    Label(text, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(texts(.preview).enumerated()), id: \.offset) { _, text in
                    previewText(text, ticketID: ticket.id)
                }
                monoLines(texts(.place), size: 12, opacity: 0.72)
                toggle(detailsOpen ? "Details \u{25B4}" : "Details \u{25BE}", id: ticket.id, in: $openDetails)
                if detailsOpen {
                    VStack(alignment: .leading, spacing: 6) {
                        monoLines(texts(.qualifier), size: 11, opacity: 0.5)
                        ForEach(Array(texts(.effect).enumerated()), id: \.offset) { _, text in
                            Text(text).font(.system(size: 12)).foregroundStyle(Self.ink.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // The kernel's reason: why it asked.
                        Text(ticket.reason).font(.system(size: 12)).foregroundStyle(Self.ink.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.leading, Self.textInset)
            if let rejection = approvalRejections[ticket.id] {
                Text(verbatim: "Not counted: \(rejection)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let step {
                    Text(verbatim: "Doing \u{00B7} step \(step.current)/\(step.total)")
                        .font(.system(size: 11))
                        .foregroundStyle(Self.ink.opacity(0.62))
                }
                Spacer(minLength: 0)
                Button { press("deny", ticket, allow: false, scope: .once) } label: {
                    Text("Deny")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Self.ink)
                        .frame(width: 84, height: 30)
                        .overlay(Capsule().stroke(Self.ink.opacity(0.6), lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { press("allowOnce", ticket, allow: true, scope: .once) } label: {
                    Text("Allow once")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ConfirmationCardStyle.material)
                        .frame(width: 100, height: 30)
                        .background(Capsule().fill(Self.ink))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(recordsFrame(of: "allowOnce", ticketID: ticket.id))
            }
            // The quieter third control, only where today's card offered it: a
            // destructive question is Allow once and Deny only. Its words are the
            // scope the "Always allowed" list will show for the rule it saves.
            if HarnessConfirmations.offersAlwaysRule(for: ticket) {
                HStack {
                    Spacer(minLength: 0)
                    Button { press("always", ticket, allow: true, scope: .always) } label: {
                        Text(HarnessConfirmations.alwaysButtonTitle(for: ticket))
                            .font(.system(size: 11))
                            .underline()
                            .foregroundStyle(Self.ink.opacity(0.62))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(recordsFrame(of: "always", ticketID: ticket.id))
                }
            }
        }
        .padding(18)
        .modifier(TracksRowPlacement(ticketID: ticket.id, tracker: placementTracker))
    }

    /// The typed text, never silently cut: a short head and "+N more", which
    /// opens the whole line (`open` refused anything over 300 scalars).
    @ViewBuilder
    private func previewText(_ text: String, ticketID: String) -> some View {
        let preview = TypedTextPreview(text)
        let whole = preview.hiddenCharacters == 0 || openPreviews.contains(ticketID)
        VStack(alignment: .leading, spacing: 2) {
            Text(whole ? text : preview.head + "\u{2026}")
                .font(.system(size: 13))
                .foregroundStyle(Self.ink)
                .fixedSize(horizontal: false, vertical: true)
            if preview.hiddenCharacters > 0 {
                toggle(whole ? "Show less" : "+\(preview.hiddenCharacters) more", id: ticketID, in: $openPreviews)
            }
        }
    }

    /// A quiet text control that opens or closes one ticket's part of the card.
    private func toggle(_ title: String, id: String, in set: Binding<Set<String>>) -> some View {
        Button {
            withAnimation(.easeOut(duration: Self.expandSeconds)) {
                if set.wrappedValue.contains(id) { set.wrappedValue.remove(id) } else { set.wrappedValue.insert(id) }
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.ink.opacity(0.62))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    fileprivate static func monoLinesView(_ texts: [String], size: CGFloat, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.system(size: size, design: .monospaced))
                    .foregroundStyle(ink.opacity(opacity))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func monoLines(_ texts: [String], size: CGFloat, opacity: Double) -> some View {
        Self.monoLinesView(texts, size: size, opacity: opacity)
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

/// The typed text's collapsed form: the first `visibleCharacters` and a count
/// of the rest. `head` is always a prefix and `head + hidden` the whole, so the
/// card can shorten the quote but never drop part of it unannounced.
struct TypedTextPreview: Equatable {
    static let visibleCharacters = 90
    let head: String
    let hiddenCharacters: Int

    init(_ text: String, limit: Int = visibleCharacters) {
        head = String(text.prefix(limit))
        hiddenCharacters = max(0, text.count - limit)
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
    /// The pressed button counts too: opening Details moves the buttons inside a
    /// row whose own origin never changes.
    static func settledSeconds(row: ScreenPlacement?, window: ScreenPlacement?, button: ScreenPlacement?,
                               nowUptime: TimeInterval) -> TimeInterval? {
        guard let row, let window, let button else { return nil }
        return nowUptime - max(row.sinceUptime, window.sinceUptime, button.sinceUptime)
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
    /// The same buttons' origins and since when — a moved button is not settled.
    var buttonPlacements: [String: ScreenPlacement] = [:]
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
/// Drawn in the card's material and words: each row's title is the question
/// the card asked, its scope the words on the card's "Always" button.
struct AlwaysRulesListView: View {
    @ObservedObject var confirmations: HarnessConfirmations
    private static let ink = ConfirmationCardStyle.ink

    /// The app's name from the local install, never from the rule.
    static func installedAppName(_ bundleIdentifier: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) }
    }

    var body: some View {
        Group {
            if !confirmations.alwaysRules.isEmpty || confirmations.alwaysRulesProblem != nil {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ALWAYS ALLOWED")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(Self.ink.opacity(0.62))
                        .padding(.bottom, 8)
                    if let problem = confirmations.alwaysRulesProblem {
                        Text(problem)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(confirmations.alwaysRules.enumerated()), id: \.offset) { index, rule in
                        if index > 0 { Rectangle().fill(Self.ink.opacity(0.1)).frame(height: 1) }
                        row(rule, HarnessConfirmations.ruleSummary(for: rule, appName: Self.installedAppName(rule.bundleIdentifier)))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ConfirmationCardStyle.material))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        // The panel outlives many requests; re-read when it is shown.
        .onAppear { confirmations.refreshAlwaysRules() }
    }

    private func row(_ rule: HarnessConfirmations.ApprovalRule, _ summary: HarnessConfirmations.RuleSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Self.ink, lineWidth: 1.25)
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: ConfirmationPromptView.symbol(for: rule.verb))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Self.ink))
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview = summary.preview {
                    Text(preview).font(.system(size: 12)).foregroundStyle(Self.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                (Text(summary.place).font(.system(size: 11, design: .monospaced)).foregroundColor(Self.ink.opacity(0.72))
                 + Text(verbatim: "  \u{00B7}  \(summary.scope)").font(.system(size: 11, weight: .medium)).foregroundColor(Self.ink.opacity(0.62)))
                    .fixedSize(horizontal: false, vertical: true)
                ConfirmationPromptView.monoLinesView(summary.qualifiers, size: 10, opacity: 0.45)
            }
            Spacer(minLength: 0)
            Button { confirmations.removeAlwaysRule(rule) } label: {
                Text("Remove")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.ink)
                    .frame(width: 64, height: 24)
                    .overlay(Capsule().stroke(Self.ink.opacity(0.6), lineWidth: 1.25))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }
}
