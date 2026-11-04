//
//  HarnessPanels.swift
//  leanring-buddy
//
//  What an experienced user closes without thinking: a Control Centre panel, an open
//  pop-up menu, a sheet. Measured 2026-11-04 on the Wi-Fi panel (macOS 27.2): the panel is
//  a layer-101 window of Control Centre and takes the focus; NSRunningApplication.activate
//  of another app leaves it open and in front (`focus` 2,054 ms notVerified, so every step
//  in Finder read frontmostChanged, launch U05); a posted Escape closes it and focus
//  returns (3/3); a second click on its icon closes it too, but only its own icon does,
//  and an owner's panel gives no way to know which. Escape knows nothing and needs nothing.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum HarnessPanels {
    static let escapeLine = "{\"keys\":\"escape\",\"verb\":\"key\"}"
    static let readTimeoutSeconds: Float = 0.5

    enum Surface: String { case panel, menu, sheet }

    /// A popup-level window of that process on screen now: Control Centre's panel, an app's open pop-up or menu.
    static func hasPopUpWindow(processIdentifier: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
    }

    static var controlCentrePanelIsOpen: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: AgentLoop.controlCentreBundleIdentifier).first
            .map { hasPopUpWindow(processIdentifier: $0.processIdentifier) } ?? false
    }

    /// What is open over the app in front, nil when nothing is. Unreadable reads as nothing: only ever a reason to close less.
    static func surfaceOpen() -> Surface? {
        guard let front = AccessibilityTreeWalker.focusedApplication() else { return nil }
        if hasPopUpWindow(processIdentifier: front.processIdentifier) {
            return front.bundleIdentifier == AgentLoop.controlCentreBundleIdentifier ? .panel : .menu
        }
        return focusedSheet(processIdentifier: front.processIdentifier) != nil ? .sheet : nil
    }

    static let goToFolderShortcut = "\u{21E7}\u{2318}G"

    /// A Save or Open sheet in front, by the sheet's own description (TextEdit's reads "save", live 2026-11-04).
    static func frontSheetIsFilePanel(processIdentifier: pid_t) -> Bool {
        focusedSheet(processIdentifier: processIdentifier)
            .flatMap { attribute($0, kAXDescriptionAttribute) as? String }.map { ["save", "open"].contains($0.lowercased()) } ?? false
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        AXUIElementSetMessagingTimeout(element, readTimeoutSeconds)
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// The sheet in front. On macOS 27 the app's focused window IS the sheet (AXSheet, parent the AXWindow; live 2026-11-04, TextEdit's Save);
    /// some apps keep the window focused with the sheet as its child.
    private static func focusedSheet(processIdentifier: pid_t) -> AXUIElement? {
        guard let focused = attribute(AXUIElementCreateApplication(processIdentifier), kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let window = focused as! AXUIElement
        if attribute(window, kAXRoleAttribute) as? String == "AXSheet" { return window }
        return ((attribute(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []).first { attribute($0, kAXRoleAttribute) as? String == "AXSheet" }
    }

    /// The panel in front closed, for a request that acts elsewhere. Blocking, off main. True once it has gone.
    static func closeControlCentrePanelInFront() -> Bool {
        guard AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier == AgentLoop.controlCentreBundleIdentifier,
              controlCentrePanelIsOpen else { return false }
        HarnessKeys.post(KeyChord(key: "escape"))
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.05)
            if !controlCentrePanelIsOpen { return true }
        }
        return false
    }
}
