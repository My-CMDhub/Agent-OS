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
        /// Ordinary windows the owner can see now (`windowsOnScreen`); nil: the window list did not read.
        var windowsOnScreen: Int? = nil
        /// Standard windows minimised to the Dock; nil: unknown.
        var minimised: Int? = nil
        var bundleIdentifier: String? = nil
    }

    static let note = "windowsHere counts windows on the current desktop only (macOS lists other desktops' windows only when "
        + "the app is in front); minimised windows count; null means the app did not answer, not that it has none. "
        + "state: inFront, inFrontNoWindow (in front, its last window closed), windowsOnScreen, minimisedOnly, hidden, "
        + "noWindowOnScreen (running with its windows closed, or on another desktop or full screen there), unknown. "
        + "desktopInFront true: the owner is looking at the desktop; Finder draws it, so the system reports Finder in front, "
        + "but no Finder window is on screen: say the desktop is in front, never Finder. App names are the apps' own."

    // MARK: Pure

    /// Frontmost first, then by name. A name that is no plausible label (empty,
    /// document-length, a control character) is withheld and counted, never listed.
    static func toolResult(apps: [App]) -> [String: Any] {
        // Finder in front with none of its windows on screen is the desktop, not Finder (owner 2026-11-01).
        let desktop = apps.contains { $0.frontmost && isDesktop(frontBundle: $0.bundleIdentifier, frontWindowsOnScreen: $0.windowsOnScreen) }
        let shown = apps.map { app in
            desktop && app.frontmost ? App(name: app.name, frontmost: false, hidden: app.hidden, windowsHere: app.windowsHere,
                                           windowsOnScreen: app.windowsOnScreen, minimised: app.minimised) : app
        }
        let listed = shown.filter { $0.name.map { UntrustedText($0).isPlausibleControlLabel } ?? false }
            .sorted { ($0.frontmost ? 0 : 1, $0.name!.lowercased()) < ($1.frontmost ? 0 : 1, $1.name!.lowercased()) }
        var result: [String: Any] = [
            "ok": true,
            "apps": listed.map { app -> [String: Any] in
                ["name": app.name!, "frontmost": app.frontmost, "hidden": app.hidden, "state": state(app),
                 "windowsHere": app.windowsHere.map { $0 as Any } ?? NSNull(),
                 "windowsOnScreen": app.windowsOnScreen.map { $0 as Any } ?? NSNull(),
                 "minimised": app.minimised.map { $0 as Any } ?? NSNull()]
            },
            "desktopInFront": desktop,
            "note": note
        ]
        if listed.count < apps.count { result["withheld"] = apps.count - listed.count }
        return result
    }

    /// What the owner would call this app's state. Hidden (Cmd-H) and minimised windows are not on screen.
    static func state(_ app: App) -> String {
        if app.frontmost { return app.windowsOnScreen == 0 ? "inFrontNoWindow" : "inFront" }
        if app.hidden { return "hidden" }
        guard let onScreen = app.windowsOnScreen else { return "unknown" }
        if onScreen > 0 { return "windowsOnScreen" }
        if (app.minimised ?? 0) > 0 { return "minimisedOnly" }
        return "noWindowOnScreen"
    }

    /// Live 2026-11-01: a minimised Finder window answers subrole `AXDialog`, not `AXStandardWindow`, so a minimised
    /// window counts by `AXMinimized` alone.
    static func minimisedCount(_ read: AccessibilityWindows.WindowRead) -> Int? {
        guard let windows = windowElements(read) else { return nil }
        return windows.filter(\.isMinimized).count
    }

    /// The `AXWindow`s of a read. Finder lists its desktop in `kAXWindows` as an `AXScrollArea` with no subrole (live
    /// 2026-11-01), which made every Finder count unknown; a role that did not read keeps the count unknown.
    static func windowElements(_ read: AccessibilityWindows.WindowRead) -> [AccessibilityWindows.WindowCandidate]? {
        guard read.readSucceeded, !read.windows.contains(where: { $0.candidate.role == "AXUnknown" }) else { return nil }
        return read.windows.map(\.candidate).filter { $0.role == kAXWindowRole as String }
    }

    // MARK: What is in front, as the owner sees it (pure)
    //
    // Owner 2026-11-01: "When my desktop is frontmost, JARVIS reports that Finder is frontmost". Clicking the desktop
    // makes Finder the frontmost PROCESS, because Finder draws the desktop — true, and misleading. This is only what the
    // models are TOLD; every guard (expectApp, policy, frontmostChanged) keeps the real frontmost process.

    enum Front: Equatable {
        /// Finder is the frontmost process and none of its windows is on screen: the owner sees the desktop.
        case desktop
        case app(name: String, windowTitle: String?, fullScreen: Bool)
        /// In front with no window on screen here: its windows closed, minimised or on another desktop; still running.
        case appWithoutWindow(name: String)
    }

    static let finderBundleIdentifier = "com.apple.finder"

    static func isDesktop(frontBundle: String?, frontWindowsOnScreen: Int?) -> Bool {
        frontBundle == finderBundleIdentifier && frontWindowsOnScreen == 0
    }

    /// Ordinary windows of `pid` in an on-screen window list (`.optionOnScreenOnly`: this Space only): layer 0, visible,
    /// non-zero size. A window whose layer does not read counts, so an unreadable list never invents the desktop.
    /// nil: no list (it did not read, or read empty — there is always a menu bar or a full-screen window).
    static func windowsOnScreen(pid: pid_t, in windowList: [[String: Any]]?) -> Int? {
        guard let windowList, !windowList.isEmpty else { return nil }
        return windowList.filter { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return false }
            if (window[kCGWindowAlpha as String] as? NSNumber).map({ $0.doubleValue <= 0 }) == true { return false }
            if let frame = (window[kCGWindowBounds as String] as? [String: Any])
                .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }), frame.width <= 0 || frame.height <= 0 {
                return false
            }
            return (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 == 0
        }.count
    }

    /// nil: nothing honest to say (no plausible name, and not the desktop).
    static func front(bundleIdentifier: String?, name: String?, windowsOnScreen: Int?,
                      focusedWindowTitle: String?, fullScreen: Bool) -> Front? {
        if isDesktop(frontBundle: bundleIdentifier, frontWindowsOnScreen: windowsOnScreen) { return .desktop }
        guard let name, !name.allSatisfy(\.isWhitespace) else { return nil }
        if windowsOnScreen == 0 { return .appWithoutWindow(name: name) }
        let title = focusedWindowTitle.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
        return .app(name: name, windowTitle: title, fullScreen: fullScreen)
    }

    /// The line both models get (voice at key-down, the agent loop every step). App-written text is ALWAYS quoted and
    /// escaped (`forDisplay`): a name or title is never a sentence of ours. `finderMinimised`: on the desktop, Finder's
    /// minimised windows, so "Finder is open" is answered without saying it is in front.
    static func contextLine(_ front: Front, finderMinimised: Int? = nil) -> String {
        let lead = "system context, not the owner's words: "
        switch front {
        case .desktop:
            let minimised = finderMinimised.map { $0 > 0 ? " (\($0) minimised)" : "" } ?? ""
            return lead + "the desktop is in front: no app window has focus. Finder draws the desktop, so the system "
                + "reports Finder in front, but no Finder window is on screen\(minimised); call it the desktop, never say "
                + "Finder is in front or open in front."
        case .app(let name, let title, let fullScreen):
            let window = title.map { ", its window \(UntrustedText($0).forDisplay)" } ?? ""
            return lead + "the app in front is \(UntrustedText(name).forDisplay)\(window)\(fullScreen ? ", full screen" : "")."
        case .appWithoutWindow(let name):
            // Live 2026-11-01: Chrome in front with no window here had a 1440x778 window on another desktop.
            return lead + "the app in front is \(UntrustedText(name).forDisplay), with no window on this desktop "
                + "(its windows are closed, minimised or on another desktop; the app is still running)."
        }
    }

    static func standardWindowCount(_ read: AccessibilityWindows.WindowRead) -> Int? {
        // A window whose subrole did not come back is unknown, not "not a window" (review 2026-10-27: a believable undercount).
        guard let windows = windowElements(read), !windows.contains(where: { $0.subrole == nil && !$0.isMinimized }) else { return nil }
        // Standard or minimised: Finder's desktop, panels and dialogs are not windows the owner would count.
        return windows.filter { $0.isMinimized || $0.subrole == kAXStandardWindowSubrole as String }.count
    }

    // MARK: Live (cross-process AX: call off the main thread)

    static func toolResult() -> [String: Any] {
        let frontmost = AccessibilityTreeWalker.focusedApplication()?.processIdentifier
        let list = onScreenWindowList()
        return toolResult(apps: AccessibilityWindows.runningApplications().map { running in
            let read = AccessibilityWindows.liveWindows(for: running.application)
            return App(name: running.candidate.localizedName ?? running.candidate.bundleName,
                       frontmost: running.application.processIdentifier == frontmost,
                       hidden: running.candidate.isHidden,
                       windowsHere: standardWindowCount(read),
                       windowsOnScreen: windowsOnScreen(pid: running.application.processIdentifier, in: list),
                       minimised: minimisedCount(read),
                       bundleIdentifier: running.application.bundleIdentifier)
        })
    }

    /// The window server's on-screen list for this Space; nil when locked (a lock screen is not the desktop).
    static func onScreenWindowList() -> [[String: Any]]? {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            return nil
        }
        return CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    /// What is in front now, for `application` (the real frontmost process, from `focusedApplication()`). A window title
    /// is withheld for a password manager. One window-list read plus at most three AX reads of that app.
    static func frontNow(_ application: NSRunningApplication) -> Front? {
        let onScreen = windowsOnScreen(pid: application.processIdentifier, in: onScreenWindowList())
        var title: String?
        var fullScreen = false
        if onScreen != 0 {
            let element = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(element, AccessibilityWindows.messagingTimeoutInSeconds)
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                var read: AnyObject?
                if !CredentialGuard.isPasswordManager(application.bundleIdentifier),
                   AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &read) == .success {
                    title = read as? String
                }
                if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &read) == .success {
                    fullScreen = (read as? Bool) == true
                }
            }
        }
        return front(bundleIdentifier: application.bundleIdentifier, name: application.localizedName,
                     windowsOnScreen: onScreen, focusedWindowTitle: title, fullScreen: fullScreen)
    }

    /// The harness reported `bundleIdentifier` in front: is that the desktop (Finder with no window on screen)? One window-list read.
    static func isDesktopInFrontNow(bundleIdentifier: String?) -> Bool {
        guard bundleIdentifier == finderBundleIdentifier,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleIdentifier).first else { return false }
        return isDesktop(frontBundle: bundleIdentifier,
                         frontWindowsOnScreen: windowsOnScreen(pid: finder.processIdentifier, in: onScreenWindowList()))
    }

    /// `contextLine` for the app in front now; nil when there is nothing honest to say.
    static func contextLineNow(_ application: NSRunningApplication) -> String? {
        guard let front = frontNow(application) else { return nil }
        let finderMinimised = front == .desktop ? minimisedCount(AccessibilityWindows.liveWindows(for: application)) : nil
        return contextLine(front, finderMinimised: finderMinimised)
    }
}
