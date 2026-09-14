//
//  ConfirmationCardWindowManager.swift
//  leanring-buddy
//
//  A harness ticket is a question for the owner, and the owner may be on
//  another Space or inside a full-screen app where the menu-bar panel is not.
//  So pending tickets come to them as a small floating card, top-right of the
//  screen holding the pointer.
//
//  What it deliberately does NOT do: switch the owner to another Space (there is
//  no public Spaces API) or take focus. Measured 2026-09-13: once the menu-bar
//  panel became key, the system-wide focused app read "Clicky" and every
//  `focus Finder` after the click failed to verify — the planner fell to 4/6.
//  The card can never become key or main, and never activates the app.
//

import AppKit
import Combine
import SwiftUI

/// Never key, never main: the card is looked at and clicked, never focused.
private final class ConfirmationCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A window that cannot become key sees its first click as a "first mouse"
/// click, which a view refuses by default — the owner would have to click twice.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ConfirmationCardWindowManager {
    private let confirmations: HarnessConfirmations
    private var panel: ConfirmationCardPanel?
    private var ticketsSubscription: AnyCancellable?

    private let cardWidth: CGFloat = 320
    private let screenEdgeMargin: CGFloat = 12

    init(confirmations: HarnessConfirmations) {
        self.confirmations = confirmations
        // `receive(on: DispatchQueue.main)` delivers on the NEXT run-loop turn,
        // never inside the socket request that opened the ticket: showing a
        // window there pumps the run loop and a second request lands inside the
        // first. It also skips `@Published`'s willSet timing — we read the new
        // list, not the old one.
        ticketsSubscription = confirmations.$tickets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let now = Date()
        let pending = confirmations.tickets.filter { HarnessConfirmations.status(of: $0, now: now) == .pending }
        guard let soonestExpiry = pending.map(\.expiresAt).min() else {
            panel?.orderOut(nil)
            return
        }
        // Expiry publishes nothing, so look again when the soonest ticket lapses.
        DispatchQueue.main.asyncAfter(deadline: .now() + soonestExpiry.timeIntervalSince(now) + 0.1) { [weak self] in
            self?.refresh()
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        positionAtTopRightOfPointerScreen(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> ConfirmationCardPanel {
        let card = ConfirmationPromptView(confirmations: confirmations, includesAnsweredTickets: false)
            .padding(.bottom, 12)
            .frame(width: cardWidth)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.background)
            )
        let hostingView = FirstMouseHostingView(rootView: card)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let cardPanel = ConfirmationCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cardPanel.isFloatingPanel = true
        // `.statusBar` (25) sits above the menu bar (24), floating panels (3)
        // and full-screen app windows, and BELOW pop-up menus (101) and the cursor
        // overlay (`.screenSaver`, 1000): an open menu the owner is reading is
        // never covered, and the buddy still draws on top. Above full-screen apps
        // comes from `.fullScreenAuxiliary`, not from a higher level.
        cardPanel.level = .statusBar
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        cardPanel.hidesOnDeactivate = false
        cardPanel.isExcludedFromWindowsMenu = true
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        cardPanel.hasShadow = true
        cardPanel.contentView = hostingView
        return cardPanel
    }

    private func positionAtTopRightOfPointerScreen(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let height = panel.contentView?.fittingSize.height ?? 160
        // `frame`, not `visibleFrame`, for the top: a full-screen Space hides the
        // menu bar and `visibleFrame` then reaches the top edge. AppKit origin is
        // bottom-left, so the card's origin is its top minus its height.
        let top = screen.frame.maxY - NSStatusBar.system.thickness - screenEdgeMargin
        let right = screen.visibleFrame.maxX - screenEdgeMargin
        panel.setFrame(NSRect(x: right - cardWidth, y: top - height, width: cardWidth, height: height), display: true)
    }
}
