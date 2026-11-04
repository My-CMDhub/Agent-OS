//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    /// Posted as the panel opens: it starts on Standby, never on a sub-page left open.
    static let jarvisPanelWillShow = Notification.Name("jarvisPanelWillShow")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, so its Voice menu and buttons take the first click.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let confirmations: HarnessConfirmations
    private let panelWidth: CGFloat = CompanionPanelView.width
    private let panelHeight: CGFloat = 380
    /// The SwiftUI content's own height, as last laid out.
    private var contentHeight: CGFloat = 0

    init(companionManager: CompanionManager, confirmations: HarnessConfirmations) {
        self.companionManager = companionManager
        self.confirmations = confirmations
        super.init()
        createStatusItem()

        // Harness tickets never open this panel: `ConfirmationCardWindowManager`
        // asks on whatever Space the owner is on, and it is the only surface that
        // answers (owner's D2, 2026-11-01). This panel only says one is waiting.
        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = Self.makeArcMenuBarIcon()
        button.toolTip = "J.A.R.V.I.S."
        button.setAccessibilityLabel("J.A.R.V.I.S.")
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// The open arc (spec §2.5): a 300° ring with its gap at one o'clock, 18 x 18,
    /// 1.6 pt round-capped stroke, as a template so the menu bar tints it. Static:
    /// the notch carries state, the menu bar only says who lives here.
    static func makeArcMenuBarIcon() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath()
            // AppKit angles: counter-clockwise from 3 o'clock, y up. One o'clock is
            // 60°, so a 60° gap centred there runs 30°...90°; the arc is the rest.
            path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 6.6, startAngle: 90, endAngle: 390,
                           clockwise: false)
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        // The rules live in the keychain, not in this view: read them as the panel opens.
        confirmations.refreshAlwaysRules()
        JarvisPermissions.shared.startWatching()
        NotificationCenter.default.post(name: .jarvisPanelWillShow, object: nil)
        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        JarvisPermissions.shared.stopWatching()
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        // The panel follows the content's own height, top-anchored under the
        // status item. Before 2026-11-01 the height was read once per show from
        // `fittingSize`, so a list that grew or shrank while open (a new ticket,
        // an "Always" saved, a rule removed) was clipped or left a gap.
        let companionPanelView = CompanionPanelView(companionManager: companionManager, confirmations: confirmations)
            .frame(width: panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { [weak self] _, height in
                    guard let self, height > 0, height != self.contentHeight else { return }
                    self.contentHeight = height
                    self.positionPanelBelowStatusItem()
                }
            })
            .frame(maxHeight: .infinity, alignment: .top)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        // The frame is `positionPanelBelowStatusItem`'s alone. A hosting view that
        // IS the contentView gets macOS 27's window-size bridge, which resizes the
        // window to the root on every layout (see `ConfirmationCardWindowManager`,
        // b7631a7). Measured 2026-11-01 with two tickets pending: 965 pt on a 900 pt screen.
        hostingView.sizingOptions = []
        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = container
        panel = menuBarPanel
    }

    /// Never past the bottom of the screen: the rules list scrolls inside its
    /// own cap, so only an unusual stack of pending tickets can reach this.
    nonisolated static func panelHeight(content: CGFloat, statusItemBottom: CGFloat, screenVisibleBottom: CGFloat,
                                        gap: CGFloat) -> CGFloat {
        max(0, min(content, statusItemBottom - gap - screenVisibleBottom))
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4
        // Before the first layout reports a height, a fresh hosting view measures
        // it: the live one has no intrinsic size (`sizingOptions = []`), and a
        // panel placed at its fittingSize came up 0 pt tall and never laid out.
        let content = contentHeight > 0 ? contentHeight
            : NSHostingView(rootView: CompanionPanelView(companionManager: companionManager, confirmations: confirmations)
                .frame(width: panelWidth)).fittingSize.height
        let screenBottom = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0
        let actualPanelHeight = Self.panelHeight(content: content, statusItemBottom: statusItemFrame.minY,
                                                 screenVisibleBottom: screenBottom, gap: gapBelowMenuBar)

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }
                if JarvisPermissions.shared.holdsPanelOpen { return }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
