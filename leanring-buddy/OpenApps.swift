//
//  OpenApps.swift
//  leanring-buddy
//
//  `list_open_apps`: which regular apps are running and how many standard
//  windows each has on this desktop. Never-taught benchmark 2026-10-25: "which
//  apps are open?" was guessed from menu-bar icons and "how many Chrome
//  windows?" from Chrome's Window menu; `NSWorkspace` plus each app's
//  `kAXWindows` is the structured answer. Reads only, in-process like
//  `find_file`, no harness verb. Names only, never window titles (a title can
//  carry a document's or an email's contents).
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum OpenApps {
    struct App: Equatable {
        let name: String?
        let frontmost: Bool
        let hidden: Bool
        /// nil when `kAXWindows` could not be read: unknown, never 0.
        let windowsHere: Int?
    }

    static let note = "windowsHere counts windows on the current desktop only (macOS lists other desktops' windows only when "
        + "the app is in front); minimised windows count; null means the app did not answer, not that it has none. "
        + "App names are the apps' own."

    // MARK: Pure

    /// Frontmost first, then by name. A name that is no plausible label (empty,
    /// document-length, a control character) is withheld and counted, never listed.
    static func toolResult(apps: [App]) -> [String: Any] {
        let listed = apps.filter { $0.name.map { UntrustedText($0).isPlausibleControlLabel } ?? false }
            .sorted { ($0.frontmost ? 0 : 1, $0.name!.lowercased()) < ($1.frontmost ? 0 : 1, $1.name!.lowercased()) }
        var result: [String: Any] = [
            "ok": true,
            "apps": listed.map { app -> [String: Any] in
                ["name": app.name!, "frontmost": app.frontmost, "hidden": app.hidden,
                 "windowsHere": app.windowsHere.map { $0 as Any } ?? NSNull()]
            },
            "note": note
        ]
        if listed.count < apps.count { result["withheld"] = apps.count - listed.count }
        return result
    }

    static func standardWindowCount(_ read: AccessibilityWindows.WindowRead) -> Int? {
        guard read.readSucceeded else { return nil }
        // Standard only: Finder's desktop, panels and dialogs are not windows the owner would count.
        return read.windows.filter { $0.candidate.subrole == kAXStandardWindowSubrole as String }.count
    }

    // MARK: Live (cross-process AX: call off the main thread)

    static func toolResult() -> [String: Any] {
        let frontmost = AccessibilityTreeWalker.focusedApplication()?.processIdentifier
        return toolResult(apps: AccessibilityWindows.runningApplications().map { running in
            App(name: running.candidate.localizedName ?? running.candidate.bundleName,
                frontmost: running.application.processIdentifier == frontmost,
                hidden: running.candidate.isHidden,
                windowsHere: standardWindowCount(AccessibilityWindows.liveWindows(for: running.application)))
        })
    }
}
