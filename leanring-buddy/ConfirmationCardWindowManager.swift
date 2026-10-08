//
//  ConfirmationCardWindowManager.swift
//  leanring-buddy
//
//  A harness ticket is a question for the owner, and the owner may be on
//  another Space or inside a full-screen app where the menu-bar panel is not.
//  So pending tickets come to them as a card that grows out of the notch, in
//  the notch's own black, on the screen the notch is on (journal, #card).
//
//  What it deliberately does NOT do: switch the owner to another Space (there is
//  no public Spaces API) or take focus. Measured 2026-09-13: once the menu-bar
//  panel became key, the system-wide focused app read "Clicky" and every
//  `focus Finder` after the click failed to verify — the planner fell to 4/6.
//  The card can never become key or main, and never activates the app.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Never key, never main: the card is looked at and clicked, never focused.
/// Allowed into the menu-bar band, where it meets the notch.
private final class ConfirmationCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A window that cannot become key sees its first click as a "first mouse"
/// click, which a view refuses by default — the owner would have to click twice.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the card sits, all from the notch's own geometry. Two spaces: the
/// panel frame is AppKit (bottom-left origin, global); every other rect is the
/// panel's own TOP-left space, the one SwiftUI draws in.
nonisolated struct ConfirmationCardGeometry: Equatable, Sendable {
    static let cardWidth: CGFloat = 420
    /// Between the tab's bottom and the card's top.
    static let gap: CGFloat = 8
    /// Room round the card for its shadow.
    static let margin: CGFloat = 24
    /// The tab's text band under a hardware notch, and its sides past it.
    static let tabTextBand: CGFloat = 26
    static let tabSideWidth: CGFloat = 64
    static let noNotchTabSize = CGSize(width: 240, height: 30)

    let notch: JarvisNotchGeometry

    /// The notch at rest: the hardware notch itself, or the no-notch pill.
    var collapsedSize: CGSize { notch.hasNotch ? notch.anchor.size : JarvisNotchGeometry.noNotchCompactSize }

    /// The notch grown just enough for one line ("needs you") — below the
    /// camera housing when there is one, never across it.
    var tabSize: CGSize {
        guard notch.hasNotch else { return Self.noNotchTabSize }
        return CGSize(width: notch.anchor.width + 2 * Self.tabSideWidth, height: notch.anchor.height + Self.tabTextBand)
    }

    var panelWidth: CGFloat { Self.cardWidth + 2 * Self.margin }
    var cardTop: CGFloat { tabSize.height + Self.gap }

    /// Centred on the notch, its top on the notch's top (the screen's top edge
    /// with a hardware notch; just under the menu bar without one).
    func panelFrame(contentHeight: CGFloat) -> CGRect {
        CGRect(x: notch.anchor.midX - panelWidth / 2, y: notch.anchor.maxY - contentHeight,
               width: panelWidth, height: contentHeight)
    }

    var collapsedFrame: CGRect {
        CGRect(x: (panelWidth - collapsedSize.width) / 2, y: 0, width: collapsedSize.width, height: collapsedSize.height)
    }

    var tabFrame: CGRect {
        CGRect(x: (panelWidth - tabSize.width) / 2, y: 0, width: tabSize.width, height: tabSize.height)
    }

    func cardFrame(height: CGFloat) -> CGRect {
        CGRect(x: Self.margin, y: cardTop, width: Self.cardWidth, height: height)
    }
}

/// What the card's SwiftUI tree reads; the manager writes it.
@MainActor
final class ConfirmationCardModel: ObservableObject {
    @Published var geometry = ConfirmationCardGeometry(notch: JarvisNotchGeometry(hasNotch: false, anchor: .zero))
    /// false: drawn at the notch's size; true: grown into the card.
    @Published var grown = false
    /// Buttons take clicks only once the card has finished growing: until then
    /// their frames are not where they will be.
    @Published var interactive = false
    @Published var reduceMotion = false
    /// The agent loop's step, when a multi-step task asked (`AgentLoop` feeds it);
    /// the tab and the footer show it only when set.
    @Published var step: ConfirmationStep?
    /// The tree's own height, as laid out — the panel follows it.
    @Published var contentHeight: CGFloat = 0
    /// The card's own height as last placed; frozen while it shrinks away.
    @Published var cardHeight: CGFloat = 0
}

/// "Doing · step 5/5".
struct ConfirmationStep: Equatable {
    let current: Int
    let total: Int
}

@MainActor
final class ConfirmationCardWindowManager {
    /// Spring in, about 0.4 s. `ApprovalInput.minimumRowSettledSeconds` (0.8 s)
    /// must stay above this — a test holds it — so no click can count on a card
    /// that is still moving even if hit-testing were on.
    static let growSeconds: TimeInterval = 0.42
    static let shrinkSeconds: TimeInterval = 0.32
    static let reduceMotionFadeSeconds: TimeInterval = 0.18

    private let confirmations: HarnessConfirmations
    private let model = ConfirmationCardModel()
    private var panel: ConfirmationCardPanel?
    private var ticketsSubscription: AnyCancellable?
    private var heightSubscription: AnyCancellable?
    /// true from the moment a card starts growing until it starts shrinking.
    private var isPresented = false
    /// Bumps on every show and dismiss, so a late timer from an earlier one does nothing.
    private var generation = 0
    /// Every ticket the card has already shown — one chime per ticket, ever.
    private var announcedTicketIDs: Set<String> = []
    /// The spoken nudge after the chime (`ConfirmationNudge`).
    private let nudger = ConfirmationNudger()
    /// J.A.R.V.I.S.'s reply audio playing, so the nudge waits for the end of its sentence.
    var replyAudioIsPlaying: () -> Bool {
        get { nudger.replyAudioIsPlaying }
        set { nudger.replyAudioIsPlaying = newValue }
    }

    private let chimeEngine = AVAudioEngine()
    private let chimeNode = AVAudioPlayerNode()
    private let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: JarvisNotchTick.sampleRate, channels: 1)!
    private lazy var chimeBuffers: [ConfirmationChime: AVAudioPCMBuffer] = Dictionary(
        uniqueKeysWithValues: ConfirmationChime.allCases.compactMap { chime in
            JarvisNotchTick.buffer(chime.samples, format: chimeFormat).map { (chime, $0) }
        })

    /// The agent loop's step, for the tab and the footer. nil hides both.
    var step: ConfirmationStep? {
        get { model.step }
        set { model.step = newValue }
    }

    /// The process's card (one per process): where `AgentLoop` sets `step`.
    private(set) static weak var current: ConfirmationCardWindowManager?

    init(confirmations: HarnessConfirmations) {
        self.confirmations = confirmations
        Self.current = self
        nudger.isPending = { [weak self] in self?.isPresented ?? false }
        chimeEngine.attach(chimeNode)
        chimeEngine.connect(chimeNode, to: chimeEngine.mainMixerNode, format: chimeFormat)
        // `receive(on: DispatchQueue.main)` delivers on the NEXT run-loop turn,
        // never inside the socket request that opened the ticket: showing a
        // window there pumps the run loop and a second request lands inside the
        // first. It also skips `@Published`'s willSet timing — we read the new
        // list, not the old one.
        ticketsSubscription = confirmations.$tickets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        // A new ticket or a "Not counted" line changes the height; the panel
        // follows while shown, never while shrinking back into the notch.
        heightSubscription = model.$contentHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isPresented, let panel = self.panel else { return }
                // Details opening animates its lines; the black follows at the same pace.
                withAnimation(self.model.reduceMotion ? nil : .easeOut(duration: ConfirmationPromptView.expandSeconds)) {
                    self.place(panel)
                }
            }
    }

    /// Which chime a refresh plays: one, only when the card appears for a
    /// ticket it never showed. A card already up that gains or swaps a ticket
    /// (replaced in place), or re-shows a ticket, is silent.
    nonisolated static func chime(pending: [HarnessConfirmations.Ticket], announced: Set<String>,
                                  cardWasPresented: Bool) -> ConfirmationChime? {
        let fresh = pending.filter { !announced.contains($0.id) }
        guard !cardWasPresented, !fresh.isEmpty else { return nil }
        return fresh.contains(where: \.isDestructive) ? .destructive : .permission
    }

    private func refresh() {
        let now = Date()
        let pending = confirmations.tickets.filter { HarnessConfirmations.status(of: $0, now: now) == .pending }
        guard let soonestExpiry = pending.map(\.expiresAt).min() else {
            dismiss()
            return
        }
        // Expiry publishes nothing, so look again when the soonest ticket lapses.
        DispatchQueue.main.asyncAfter(deadline: .now() + soonestExpiry.timeIntervalSince(now) + 0.1) { [weak self] in
            self?.refresh()
        }

        if let chime = Self.chime(pending: pending, announced: announcedTicketIDs, cardWasPresented: isPresented) {
            play(chime)
        }
        announcedTicketIDs = announcedTicketIDs.union(pending.map(\.id))
            .intersection(confirmations.tickets.map(\.id))

        let panel = panel ?? makePanel()
        self.panel = panel
        if !isPresented {
            // Every appearance starts from the notch, on the notch's screen.
            model.geometry = ConfirmationCardGeometry(notch: Self.notchGeometry())
            model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            model.grown = false
            model.interactive = false
        }
        place(panel)
        guard !isPresented else { return }
        isPresented = true
        generation += 1
        let shown = generation
        nudger.cardShown()
        JarvisNotch.shared.coveredByCard = true
        panel.orderFrontRegardless()
        // Next turn, so the collapsed frame is drawn once before the spring starts.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == shown else { return }
            withAnimation(self.model.reduceMotion ? .easeOut(duration: Self.reduceMotionFadeSeconds)
                          : .spring(response: Self.growSeconds, dampingFraction: 0.82)) {
                self.model.grown = true
            }
            let settle = self.model.reduceMotion ? Self.reduceMotionFadeSeconds : Self.growSeconds + 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.model.interactive = true
            }
        }
    }

    /// Back up into the notch, then gone.
    private func dismiss() {
        guard isPresented, let panel else { return }
        isPresented = false
        nudger.cardDismissed()
        generation += 1
        let dismissed = generation
        model.interactive = false
        let seconds = model.reduceMotion ? Self.reduceMotionFadeSeconds : Self.shrinkSeconds
        withAnimation(model.reduceMotion ? .easeIn(duration: seconds) : .spring(response: seconds, dampingFraction: 0.95)) {
            model.grown = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
            guard let self, self.generation == dismissed else { return }
            panel.orderOut(nil)
            JarvisNotch.shared.coveredByCard = false
        }
    }

    /// The notch's screen while it is drawn; otherwise the pointer's, which is
    /// where the notch itself would appear next.
    private static func notchGeometry() -> JarvisNotchGeometry {
        if let visible = JarvisNotch.shared.visibleGeometry { return visible }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        return screen.map(JarvisNotchGeometry.forScreen) ?? JarvisNotchGeometry(hasNotch: false, anchor: .zero)
    }

    /// Top-anchored at the notch: a taller card for a new ticket grows down and
    /// keeps every row's top-left (and so its settle clock) where it was.
    private func place(_ panel: NSPanel) {
        let height = isPresented && model.contentHeight > 0 ? model.contentHeight : measuredContentHeight()
        model.cardHeight = max(0, height - model.geometry.cardTop - ConfirmationCardGeometry.margin)
        panel.setFrame(model.geometry.panelFrame(contentHeight: height), display: true)
    }

    /// The panel's height for the tickets as they are NOW. The live hosting view
    /// may not have drawn the newest list yet (seen live: the first frame of a
    /// card came up 80 pt too high), so a fresh one measures it.
    private func measuredContentHeight() -> CGFloat {
        let card = ConfirmationPromptView(confirmations: confirmations, style: .card(step: model.step))
            .frame(width: ConfirmationCardGeometry.cardWidth)
        return NSHostingView(rootView: card).fittingSize.height + model.geometry.cardTop + ConfirmationCardGeometry.margin
    }

    private func play(_ chime: ConfirmationChime) {
        guard !JarvisNotchTick.systemOutputIsMuted(), let buffer = chimeBuffers[chime] else { return }
        if !chimeEngine.isRunning {
            do { try chimeEngine.start() } catch { print("❌ card chime: engine failed to start: \(error)"); return }
        }
        chimeNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !chimeNode.isPlaying { chimeNode.play() }
    }

    private func makePanel() -> ConfirmationCardPanel {
        let root = ConfirmationCardRootView(model: model, confirmations: confirmations)
        let hostingView = FirstMouseHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        // The panel's frame is ours (top-anchored at the notch), never the
        // content's: an AppKit resize would keep the bottom edge and slide rows.
        hostingView.sizingOptions = []

        let cardPanel = ConfirmationCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: model.geometry.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cardPanel.isFloatingPanel = true
        // The notch's own level, `.statusBar + 1` (26): above the menu bar (24)
        // and status items (25), so the tab can meet the notch; below pop-up
        // menus (101) and the cursor overlay (`.screenSaver`, 1000), so an open
        // menu the owner is reading is never covered. Ordered in after the notch,
        // it draws over it. Above full-screen apps comes from `.fullScreenAuxiliary`.
        cardPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        cardPanel.hidesOnDeactivate = false
        cardPanel.isExcludedFromWindowsMenu = true
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        // The SwiftUI shape draws its own shadow: a window shadow would outline
        // the whole transparent panel, not the growing card.
        cardPanel.hasShadow = false
        cardPanel.animationBehavior = .none
        cardPanel.contentView = hostingView
        return cardPanel
    }
}

enum ConfirmationCardStyle {
    /// The journal's `--notch` and `--notch-ink`. No cyan anywhere on the
    /// card: cyan means verified proof, and a question is not proof.
    static let material = Color(red: 0x07 / 255, green: 0x09 / 255, blue: 0x0A / 255)
    static let ink = Color(red: 0xE8 / 255, green: 0xEE / 255, blue: 0xF0 / 255)
    static let cornerRadius: CGFloat = 18
}

/// The tab and the card, both grown out of the notch's rect.
private struct ConfirmationCardRootView: View {
    @ObservedObject var model: ConfirmationCardModel
    @ObservedObject var confirmations: HarnessConfirmations

    var body: some View {
        let geometry = model.geometry
        // Under Reduce Motion nothing moves: both shapes are at full size and
        // the whole card fades.
        let open = model.grown || model.reduceMotion
        VStack(spacing: 0) {
            Color.clear.frame(height: geometry.cardTop)
            ConfirmationPromptView(confirmations: confirmations, style: .card(step: model.step))
                .frame(width: ConfirmationCardGeometry.cardWidth)
                // Text waits for the black to reach it (seen live: at the same
                // spring it floated outside the growing shape); on the way back
                // it leaves first.
                .opacity(model.grown ? 1 : 0)
                .animation(model.reduceMotion ? nil
                           : model.grown ? .easeOut(duration: 0.18).delay(0.16) : .easeIn(duration: 0.1),
                           value: model.grown)
                .allowsHitTesting(model.interactive)
        }
        .padding(.horizontal, ConfirmationCardGeometry.margin)
        .padding(.bottom, ConfirmationCardGeometry.margin)
        .frame(width: geometry.panelWidth, alignment: .top)
        .background(alignment: .topLeading) {
            // Sized from the height the manager last placed, not from the rows:
            // an answered ticket drops its rows at once, and a shape sized by
            // them vanished in one frame instead of shrinking (seen live).
            let rect = open ? geometry.cardFrame(height: model.cardHeight) : geometry.collapsedFrame
            RoundedRectangle(cornerRadius: open ? ConfirmationCardStyle.cornerRadius : min(10, rect.height / 2),
                             style: .continuous)
                .fill(ConfirmationCardStyle.material)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 14, x: 0, y: 6)
        }
        .overlay(alignment: .top) { tab(open: open) }
        .opacity(model.reduceMotion && !model.grown ? 0 : 1)
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in model.contentHeight = height }
        })
        // Top-anchored inside whatever frame the panel has this instant.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The notch, grown one line taller: "needs you".
    private func tab(open: Bool) -> some View {
        let geometry = model.geometry
        let size = open ? geometry.tabSize : geometry.collapsedSize
        let text = model.step.map { "Doing \u{00B7} \($0.current)/\($0.total) \u{00B7} needs you" } ?? "needs you"
        return UnevenRoundedRectangle(topLeadingRadius: geometry.notch.hasNotch ? 0 : 10,
                                      bottomLeadingRadius: open ? 14 : 10, bottomTrailingRadius: open ? 14 : 10,
                                      topTrailingRadius: geometry.notch.hasNotch ? 0 : 10, style: .continuous)
            .fill(Color.black)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottom) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ConfirmationCardStyle.ink)
                    .lineLimit(1)
                    .frame(height: geometry.notch.hasNotch ? ConfirmationCardGeometry.tabTextBand : size.height)
                    .opacity(model.grown ? 1 : 0)
            }
            .allowsHitTesting(false)
            .accessibilityLabel(text)
    }
}
