//
//  ConfirmationPromptView.swift
//  leanring-buddy
//
//  The in-process half of a harness confirmation: the kernel asked, the socket
//  could not answer, so the question lands here — on the card under the notch,
//  the ONE place a ticket can be answered (owner's D2, 2026-11-01: the menu-bar
//  panel only says "Approval waiting · at the notch"). Every string shown is
//  either ours or already escaped by `HarnessConfirmations.displayLines`.
//

import AppKit
import SwiftUI

struct ConfirmationPromptView: View {
    @ObservedObject var confirmations: HarnessConfirmations

    /// The card's sections, top to bottom. Every `CardLine.Kind` is here (a test
    /// holds it), so no line a ticket binds can be left off the card. The first
    /// group is always drawn; the second opens under Details.
    static let alwaysVisibleSections: [HarnessConfirmations.CardLine.Kind] = [.question, .warning, .preview, .place]
    static let detailSections: [HarnessConfirmations.CardLine.Kind] = [.qualifier, .effect]
    static var cardSections: [HarnessConfirmations.CardLine.Kind] { alwaysVisibleSections + detailSections }
    /// Details and "+N more" open BELOW the buttons and move nothing clickable;
    /// should that ever change, the move is this long and `minimumRowSettledSeconds`
    /// outlasts it (a test holds that).
    static let expandSeconds: TimeInterval = 0.2
    /// Tickets whose Details, or whose whole typed text, the owner opened.
    @State private var openDetails: Set<String> = []
    @State private var openPreviews: Set<String> = []
    /// Why the last approval pressed on a ticket did not count, by ticket id.
    /// Every reason is our own words and numbers — no app-written text.
    @State private var approvalRejections: [String: String] = [:]

    /// `expandedForSnapshot` (UI snapshots only): every ticket drawn with Details
    /// and its whole typed text open and a rejection line showing, so the
    /// renderer can show that none of them moves a button.
    init(confirmations: HarnessConfirmations, expandedForSnapshot: Bool = false) {
        _confirmations = ObservedObject(wrappedValue: confirmations)
        guard expandedForSnapshot else { return }
        let ids = Set(confirmations.tickets.map(\.id))
        _openDetails = State(initialValue: ids)
        _openPreviews = State(initialValue: ids)
        _approvalRejections = State(initialValue: Dictionary(uniqueKeysWithValues: ids.map {
            ($0, "the button moved 0.3 s before the click (needs 0.8 s still)")
        }))
    }
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

    /// Pending tickets only, oldest first: a new one appends below, so the rows
    /// already showing (and their buttons' settle clocks) never move.
    static func visibleTickets(_ tickets: [HarnessConfirmations.Ticket], now: Date) -> [HarnessConfirmations.Ticket] {
        tickets.filter { HarnessConfirmations.status(of: $0, now: now) == .pending }
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
            // Both panels' SwiftUI tree fills the window's content view from its origin, so
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
                let visible = Self.visibleTickets(confirmations.tickets, now: context.date)
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, ticket in
                            if index > 0 { Rectangle().fill(JV.hairline).frame(height: 1) }
                            cardRow(ticket, now: context.date)
                        }
                    }
                    .background(HostWindowReader(tracker: placementTracker))
                }
            }
        }
    }

    // MARK: Card

    /// The verb glyph's column plus its gap: every line under the headline starts here.
    private static let textInset: CGFloat = 28
    static let denyWidth: CGFloat = 88
    static let allowWidth: CGFloat = 112
    /// The expiry turns from ink3 to ink in its last seconds.
    static let urgentSeconds: TimeInterval = 10

    /// "Expires in 0:42": the ticket's own `expiresAt`, never a timer of its own.
    static func expiryText(expiresAt: Date, now: Date) -> String {
        let seconds = Int(max(0, expiresAt.timeIntervalSince(now)).rounded(.up))
        return String(format: "Expires in %d:%02d", seconds / 60, seconds % 60)
    }

    /// One ticket on the card. Pending only (the card never shows answered rows).
    /// Top to bottom: headline, warning band, preview, place — then the buttons —
    /// then everything that can open or appear. Principle 4 of the 2026-11-01
    /// spec: nothing that can grow sits above a control it would displace, so a
    /// rejected click, Details or "+N more" never moves Deny or Allow (each move
    /// restarts the 0.8 s settle clock, and the owner's retry would land lower).
    @ViewBuilder
    private func cardRow(_ ticket: HarnessConfirmations.Ticket, now: Date) -> some View {
        let texts = { (kind: HarnessConfirmations.CardLine.Kind) in ticket.cardLines.filter { $0.kind == kind }.map(\.text) }
        let detailsOpen = openDetails.contains(ticket.id)
        let previews = texts(.preview)
        let hiddenPreview = previews.map { TypedTextPreview($0).hiddenCharacters }.max() ?? 0
        let previewOpen = openPreviews.contains(ticket.id)
        let remaining = ticket.expiresAt.timeIntervalSince(now)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // Our own verb, bare: no tile, so the headline is the brightest thing.
                Image(systemName: Self.symbol(for: ticket.verb))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JV.ink2)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 8) {
                    // The consequence, in the words the voice says: "Press "Send" in "Mail"?".
                    Text(texts(.question).joined(separator: " "))
                        .font(JV.display)
                        .tracking(JV.displayTracking)
                        .foregroundStyle(JV.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    // No colour (cyan means proof; D3 keeps amber and red off the
                    // glass): a raised band, a glyph and weight mark a warning.
                    ForEach(Array(texts(.warning).enumerated()), id: \.offset) { _, text in
                        warningBand(text)
                    }
                    // The typed text: a head and an ellipsis here; the whole text
                    // opens BELOW the buttons ("+N more"), never pushing them down.
                    ForEach(Array(previews.enumerated()), id: \.offset) { _, text in
                        let preview = TypedTextPreview(text)
                        Text(preview.hiddenCharacters == 0 ? text : preview.head + "\u{2026}")
                            .font(JV.title)
                            .foregroundStyle(JV.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // App-written names are quoted, not logged: SF Pro, escaped as bound.
                    ForEach(Array(texts(.place).enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(JV.body)
                            .foregroundStyle(JV.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            buttonRow(ticket, remaining: remaining, now: now)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                toggle(detailsOpen ? "Details \u{2303}" : "Details \u{2304}", id: ticket.id, in: $openDetails)
                if hiddenPreview > 0 {
                    toggle(previewOpen ? "Show less" : "+\(hiddenPreview) more", id: ticket.id, in: $openPreviews)
                }
                Spacer(minLength: 8)
                // The quieter third control, only where the card offers it: a
                // destructive question is Allow once and Deny only. Its words are the
                // scope the "Always allowed" list will show for the rule it saves.
                if HarnessConfirmations.offersAlwaysRule(for: ticket) {
                    Button { press("always", ticket, allow: true, scope: .always) } label: {
                        Text(HarnessConfirmations.alwaysButtonTitle(for: ticket))
                            .font(JV.caption)
                            .underline()
                            .foregroundStyle(JV.ink2)
                            .fixedSize()
                            .frame(height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(recordsFrame(of: "always", ticketID: ticket.id))
                }
            }
            .padding(.leading, Self.textInset)
            .padding(.top, -4)
            if previewOpen && hiddenPreview > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(previews.enumerated()), id: \.offset) { _, text in
                        Text(text).font(JV.body).foregroundStyle(JV.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, Self.textInset)
                .transition(.opacity)
            }
            if detailsOpen {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(texts(.effect).enumerated()), id: \.offset) { _, text in
                        Text(text).font(JV.body).foregroundStyle(JV.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    // The kernel's reason: why it asked.
                    Text(verbatim: "Why I asked: \(ticket.reason)")
                        .font(JV.caption).foregroundStyle(JV.ink2).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(texts(.qualifier).enumerated()), id: \.offset) { _, text in
                        Text(text).font(JV.mono).foregroundStyle(JV.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, Self.textInset)
                .transition(.opacity)
            }
            // Below everything clickable: it appears after a click and moves nothing.
            if let rejection = approvalRejections[ticket.id] {
                Text(verbatim: "Not counted: \(rejection)")
                    .font(JV.caption)
                    .foregroundStyle(JV.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.textInset)
            }
        }
        .padding(20)
        .modifier(TracksRowPlacement(ticketID: ticket.id, tracker: placementTracker))
    }

    /// Expiry text in the leading slot, then Deny and Allow once, trailing: the
    /// text's width changes every second and moves neither button (a Spacer
    /// takes up the difference). A destructive question inverts the fills —
    /// Deny filled, Allow once outlined — in the SAME frames, so position memory
    /// holds and only the emphasis changes (owner's D3).
    private func buttonRow(_ ticket: HarnessConfirmations.Ticket, remaining: TimeInterval, now: Date) -> some View {
        let serious = ticket.isDestructive
        let seconds = Int(max(0, remaining).rounded(.up))
        return HStack(spacing: 8) {
            Text(Self.expiryText(expiresAt: ticket.expiresAt, now: now))
                .font(JV.meta)
                .foregroundStyle(remaining <= Self.urgentSeconds ? JV.ink : JV.ink3)
                .accessibilityLabel("\(seconds) seconds left")
            Spacer(minLength: 8)
            Button { press("deny", ticket, allow: false, scope: .once) } label: {
                cardButtonLabel("Deny", filled: serious, width: Self.denyWidth)
            }
            .buttonStyle(.plain)
            Button { press("allowOnce", ticket, allow: true, scope: .once) } label: {
                cardButtonLabel("Allow once", filled: !serious, width: Self.allowWidth)
            }
            .buttonStyle(.plain)
            .background(recordsFrame(of: "allowOnce", ticketID: ticket.id))
        }
    }

    private func cardButtonLabel(_ title: String, filled: Bool, width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: JV.buttonRadius, style: .continuous)
        return Text(title)
            .font(filled ? JV.bodySemibold : JV.bodyMedium)
            .foregroundStyle(filled ? JV.glass : JV.ink)
            .frame(width: width, height: JV.buttonHeight)
            .background(shape.fill(filled ? JV.ink : Color.clear))
            .overlay(shape.strokeBorder(filled ? Color.clear : JV.ink.opacity(0.6), lineWidth: JV.stroke))
            .contentShape(shape)
    }

    private func warningBand(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(JV.bodySemibold)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(JV.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: JV.bandRadius, style: .continuous).fill(JV.raised))
    }

    /// A quiet text control that opens or closes one ticket's part of the card.
    private func toggle(_ title: String, id: String, in set: Binding<Set<String>>) -> some View {
        Button {
            withAnimation(.easeOut(duration: Self.expandSeconds)) {
                if set.wrappedValue.contains(id) { set.wrappedValue.remove(id) } else { set.wrappedValue.insert(id) }
            }
        } label: {
            Text(title)
                .font(JV.caption)
                .foregroundStyle(JV.ink2)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
