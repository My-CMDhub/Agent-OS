//
//  HarnessGoToFolder.swift
//  leanring-buddy
//
//  `goToFolder`: Finder's Go > Go to Folder…, driven structurally. Owner's
//  ruling 2026-10-11: a read-only task may type a path into that field — it is
//  navigation — and nothing else widens. Every step is what the coordinator
//  measured 2026-10-11:
//    - The menu item opens an `AXSheet` with AXIdentifier `GoToWindow` on the
//      front browser window, or (desktop only) a standalone AXWindow with the
//      same identifier. Its field: `AXTextField`, AXIdentifier `PathTextField`,
//      AXValue settable, pre-filled with the last path.
//    - The panel's own "Close" button returns 0 and does NOTHING; `AXConfirm` on
//      the field returns 0 and does NOTHING. No keystroke is ever sent.
//    - The Finder APPLICATION element has a child `AXFunctionRowTopLevelElement`
//      (Touch Bar emulation): while the panel is up its children are AXButton
//      "Cancel" and AXButton "Go". AXPress "Go" after an AXValue write navigated
//      the window (err 0, ~1 s); AXPress "Cancel" closed the panel. With no panel
//      it holds the window's own controls (View Options, Quick Look, Share…).
//
//  The pure half (path rules, the menu item, the one "Go"/"Cancel", arriving)
//  is unit-tested; the live half is proven by running it.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum HarnessGoToFolder {
    static let finderBundleIdentifier = "com.apple.finder"
    static let maximumPathLength = 1024
    static let goMenuTitle = "Go"
    static let panelIdentifier = "GoToWindow"
    static let fieldIdentifier = "PathTextField"
    static let functionRowRole = "AXFunctionRowTopLevelElement"
    /// ponytail: English titles only, as measured; another language reads as unavailable.
    static let goButtonTitle = "Go"
    static let cancelButtonTitle = "Cancel"
    static let readTimeoutSeconds: Float = 0.5
    static let writeTimeoutSeconds: Float = 1.0
    static let fieldDeadlineSeconds = 1.5
    static let arrivalDeadlineSeconds = 2.0
    static let closeDeadlineSeconds = 0.5
    static let pollIntervalSeconds = 0.05

    // MARK: Pure

    /// Why the path may not be written, nil when it may. Absolute or from `~`
    /// (Finder expands it): a bare name makes Go to Folder pick among its own
    /// suggestions. Never a control character — Return is never typed.
    static func pathProblem(_ path: String) -> String? {
        if path.allSatisfy(\.isWhitespace) { return "empty" }
        if path.count > maximumPathLength { return "longer than \(maximumPathLength) characters" }
        if path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return "a control character" }
        if !path.hasPrefix("/"), !path.hasPrefix("~") { return "not a path starting with / or ~" }
        return nil
    }

    /// The path as Finder will read it: `~` expanded against `home`, `.`/`..` removed.
    /// No file-system access (a symlink is not resolved).
    static func standardized(_ path: String, home: String) -> String {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        let standard = URL(fileURLWithPath: expanded).standardized.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }

    /// The title the front window takes on arriving, nil for the root (shown as the volume's name).
    static func expectedFolderName(_ path: String, home: String) -> String? {
        let standard = standardized(path, home: home)
        return standard == "/" ? nil : (standard as NSString).lastPathComponent
    }

    static func isGoToFolderItem(_ label: String?) -> Bool {
        guard let label else { return false }
        return label == "Go to Folder\u{2026}" || label == "Go to Folder..."
    }

    /// The one index whose title is exactly `title`; nil for none or several.
    static func singleIndex(of title: String, in titles: [String?]) -> Int? {
        let matches = titles.indices.filter { titles[$0] == title }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The measured signature of the Go to Folder panel in the function row: one
    /// "Go" and one "Cancel". An alert's lone Cancel is not it.
    static func isPanelShowing(functionRowTitles titles: [String?]) -> Bool {
        singleIndex(of: goButtonTitle, in: titles) != nil && singleIndex(of: cancelButtonTitle, in: titles) != nil
    }

    struct WindowReading: Equatable {
        var title: String?
        /// AXDocument, a file URL string, when the window publishes one.
        var document: String?
    }

    /// The evidence that the front window is now the folder, nil when it is not
    /// shown to be. A document naming the folder is enough; a title is enough
    /// only when it changed to the folder's name (two folders may share it).
    static func arrival(at path: String, home: String, before: WindowReading?, now: WindowReading?) -> String? {
        guard let now else { return nil }
        let wanted = standardized(path, home: home)
        if let document = now.document, let url = URL(string: document), url.isFileURL,
           standardized(url.path, home: home) == wanted {
            return "the front window's document is the folder"
        }
        if let expected = expectedFolderName(path, home: home), now.title == expected, before?.title != expected {
            return "the front window is now titled \(UntrustedText(expected).forDisplay)"
        }
        return nil
    }

    // MARK: Live

    struct Run {
        var report: [String: Any] = [:]
        /// (error code, message); nil when the window arrived at the folder.
        var failure: (code: String, message: String)?
    }

    /// Presses Go to Folder…, writes the path into the panel's field, presses the
    /// function row's "Go", and waits for the front window to arrive. On every
    /// failure with the panel still up it presses the function row's "Cancel".
    /// Anything else in front (Finder's "can't be found" alert) is left as it is
    /// and reported — never dismissed with a keystroke.
    static func go(to path: String, menuItem: AXUIElement, processIdentifier: pid_t) -> Run {
        var run = Run()
        var timings: [String: Int] = [:]
        func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, readTimeoutSeconds)
        let home = NSHomeDirectory()
        let before = frontWindow(application)

        func fail(_ code: String, _ message: String, cancelWithoutGo: Bool = false) -> Run {
            let cancelled = cancelPanel(application, requireGo: !cancelWithoutGo)
            run.report["cancelPressed"] = cancelled.pressed
            if cancelled.pressed, !cancelled.closed {
                run.failure = ("goToFolderLeftOpen", message + "; Cancel was pressed and the Go to Folder panel is still open — the owner may need to close it")
            } else {
                run.failure = (code, message)
            }
            run.report["timings"] = timings
            return run
        }

        let opening = Date()
        let press = AccessibilityActionPerformer.perform(kAXPressAction, on: menuItem, timeoutInSeconds: 2.0)
        run.report["menuPressAxError"] = press.error.rawValue
        // -25204: the press may be held while the panel animates in; the field decides.
        guard press.error == .success || press.error == .cannotComplete else {
            run.failure = ("goToFolderUnavailable", "Go > Go to Folder… did not press (AXError \(press.error.rawValue)); nothing was typed")
            return run
        }
        var field: AXUIElement?
        let fieldDeadline = Date().addingTimeInterval(fieldDeadlineSeconds)
        repeat {
            field = panelField(application)
            if field == nil { Thread.sleep(forTimeInterval: pollIntervalSeconds) }
        } while field == nil && Date() < fieldDeadline
        timings["openMs"] = milliseconds(since: opening)
        guard let field else {
            return fail("goToFolderUnavailable", "the Go to Folder panel's path field was not found in \(Int(fieldDeadlineSeconds * 1000)) ms; nothing was typed")
        }

        let writing = Date()
        AXUIElementSetMessagingTimeout(field, writeTimeoutSeconds)
        let write = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, path as CFString)
        run.report["writeAxError"] = write.rawValue
        timings["writeMs"] = milliseconds(since: writing)
        guard write == .success else {
            return fail("goToFolderFailed", "the path field did not take the path (AXError \(write.rawValue)); nothing was opened", cancelWithoutGo: true)
        }

        let buttons = functionRowButtons(application)
        run.report["functionRow"] = buttons.map { $0.title.map { UntrustedText($0).forDisplay } ?? "<untitled>" }
        guard let goIndex = singleIndex(of: goButtonTitle, in: buttons.map(\.title)) else {
            return fail("goToFolderUnavailable", "Finder's function row has no single \"Go\" button to press; nothing was opened", cancelWithoutGo: true)
        }
        let going = Date()
        let go = AccessibilityActionPerformer.perform(kAXPressAction, on: buttons[goIndex].element, timeoutInSeconds: 2.0)
        run.report["goPressAxError"] = go.error.rawValue
        guard go.error == .success || go.error == .cannotComplete else {
            return fail("goToFolderFailed", "pressing \"Go\" failed (AXError \(go.error.rawValue))", cancelWithoutGo: true)
        }

        var after: WindowReading?
        var evidence: String?
        let arrivalDeadline = Date().addingTimeInterval(arrivalDeadlineSeconds)
        repeat {
            Thread.sleep(forTimeInterval: pollIntervalSeconds * 2)
            after = frontWindow(application)
            evidence = arrival(at: path, home: home, before: before, now: after)
        } while evidence == nil && Date() < arrivalDeadline
        timings["arriveMs"] = milliseconds(since: going)
        run.report["windowAfter"] = (after?.title).map { UntrustedText($0).forDisplay } ?? NSNull()
        if let evidence {
            run.report["evidence"] = evidence
            run.report["timings"] = timings
            return run
        }
        // Not arrived. The panel still up is cancelled; anything else in front
        // (an alert that the folder can't be found) is the owner's to read.
        if panelField(application) != nil {
            return fail("notObserved", "Finder did not show the folder within \(Int(arrivalDeadlineSeconds * 1000)) ms; the panel was cancelled",
                        cancelWithoutGo: true)
        }
        run.report["leftInFront"] = after.map { "a window titled \(UntrustedText($0.title ?? "").forDisplay)" } ?? NSNull()
        run.report["timings"] = timings
        run.failure = ("notObserved", "Finder did not show the folder within \(Int(arrivalDeadlineSeconds * 1000)) ms; whatever Finder shows "
            + "now (perhaps an alert that the folder can't be found) was left as it is for the owner")
        return run
    }

    /// The focused element, when it is the panel's path field: identity by
    /// AXIdentifier on the field AND its parent, never by title. Unreadable is nil.
    static func panelField(_ application: AXUIElement) -> AXUIElement? {
        guard let focused = element(application, kAXFocusedUIElementAttribute),
              string(focused, kAXIdentifierAttribute) == fieldIdentifier,
              let parent = element(focused, kAXParentAttribute),
              string(parent, kAXIdentifierAttribute) == panelIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(focused, readTimeoutSeconds)
        return focused
    }

    /// The buttons of the app's one function row, in order; empty when there is not exactly one row.
    static func functionRowButtons(_ application: AXUIElement) -> [(title: String?, element: AXUIElement)] {
        let rows = children(application).filter { string($0, kAXRoleAttribute) == functionRowRole }
        guard rows.count == 1 else { return [] }
        // ponytail: the row's direct children, as measured; read deeper if a build nests them.
        return children(rows[0]).filter { string($0, kAXRoleAttribute) == kAXButtonRole as String }
            .map { (string($0, kAXTitleAttribute), $0) }
    }

    /// Presses the function row's single "Cancel" (with `requireGo`, only while it
    /// also shows the panel's "Go"), then waits for the path field to go.
    static func cancelPanel(_ application: AXUIElement, requireGo: Bool) -> (pressed: Bool, closed: Bool) {
        let buttons = functionRowButtons(application)
        let titles = buttons.map(\.title)
        guard let index = singleIndex(of: cancelButtonTitle, in: titles), !requireGo || isPanelShowing(functionRowTitles: titles) else {
            return (false, panelField(application) == nil)
        }
        _ = AccessibilityActionPerformer.perform(kAXPressAction, on: buttons[index].element, timeoutInSeconds: 1.0)
        let deadline = Date().addingTimeInterval(closeDeadlineSeconds)
        while panelField(application) != nil {
            if Date() >= deadline { return (true, false) }
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
        }
        return (true, true)
    }

    /// The app's focused window: its title and AXDocument.
    static func frontWindow(_ application: AXUIElement) -> WindowReading? {
        guard let window = element(application, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, readTimeoutSeconds)
        return WindowReading(title: string(window, kAXTitleAttribute), document: string(window, kAXDocumentAttribute))
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? String : nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }
}
