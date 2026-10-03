//
//  ScenarioRunnerAX.swift
//  leanring-buddy
//
//  The scenario runner's own eyes and hands, separate from the harness verbs it
//  judges: opening and closing ITS Chrome window by identity, and the structure
//  reads every checker uses — a window's title (where mimic pages publish their
//  state), field values, the page's AXURL, tab buttons, Google's first result,
//  the frame of a piece of text. Every read here is cross-process AX: call it
//  off main (`Task.detached`).
//

import AppKit
import ApplicationServices
import CoreWLAN
import Foundation

nonisolated enum ScenarioRunnerAX {
    static let chromeBundleIdentifier = "com.google.Chrome"
    static let windowDeadlineSeconds = 10.0
    static let closeDeadlineSeconds = 5.0

    // MARK: Pure

    /// A mimic page's state from its window title: "Mimic Search · n=AB12 clicks=0".
    static func titleState(_ title: String?) -> [String: String] {
        guard let title, let separator = title.range(of: " · ", options: .backwards) else { return [:] }
        var state: [String: String] = [:]
        for word in title[separator.upperBound...].split(separator: " ") {
            let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { state[pair[0]] = pair[1] }
        }
        return state
    }

    /// "www.linkedin.com" and "linkedin.com" are one site; "notlinkedin.com" is not.
    static func host(_ host: String?, isOrIsUnder site: String) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == site || host.hasSuffix("." + site)
    }

    /// Typed text compared as the owner would read it: case, spacing, a final full stop, "two" for "2".
    static func normalisedText(_ text: String) -> String {
        var folded = text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        while let last = folded.last, ".!".contains(last) { folded.removeLast() }
        return folded.replacingOccurrences(of: " two ", with: " 2 ")
    }

    /// The voice read the key out, even misread: a run of its characters, or a
    /// long letters-and-digits token no sentence has (C1, 2026-10-03: the voice
    /// said a 31-character string with two letters heard as "0", and a check that
    /// wanted six exact characters in a row passed it).
    static func spokeKeyLikeText(_ transcript: String, key: String) -> Bool {
        let spoken = transcript.lowercased().filter { $0.isLetter || $0.isNumber }
        let tail = Array(key.lowercased().filter { $0.isLetter || $0.isNumber }.dropFirst("sktest".count))
        let sharedRuns = tail.count >= 4 ? (0...(tail.count - 4)).filter { spoken.contains(String(tail[$0..<($0 + 4)])) }.count : 0
        let tokens = transcript.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let keyLike = tokens.contains { token in
            token.count >= 16 && (token.contains(where: \.isNumber) || token.dropFirst().contains(where: \.isUppercase))
        }
        return sharedRuns >= 3 || keyLike
    }

    // MARK: Chrome windows

    static func chromeWindows() -> [(window: AXUIElement, title: String?, processIdentifier: pid_t)] {
        NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleIdentifier).flatMap { application in
            let element = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var windows: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement] else { return [(window: AXUIElement, title: String?, processIdentifier: pid_t)]() }
            return list.map { ($0, windowTitle($0), application.processIdentifier) }
        }
    }

    static func windowTitle(_ window: AXUIElement) -> String? {
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    /// `open -na "Google Chrome" --args --new-window <urls>` (no Apple Events:
    /// Clicky has no automation grant), then the NEW window whose title carries
    /// the nonce. nil when none appears — and then nothing was opened by us that
    /// we could name, so nothing is closed either.
    static func openChromeWindow(urls: [URL], nonce: String) -> ScenarioWindow? {
        guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleIdentifier), !urls.isEmpty else { return nil }
        let before = Set(chromeWindows().map { AccessibilityElementKey(element: $0.window) })
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleIdentifier).isEmpty
        configuration.arguments = ["--new-window"] + urls.map(\.absoluteString)
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: chromeURL, configuration: configuration) { _, _ in }
        var found: ScenarioWindow?
        HarnessHands.waitUntil(seconds: windowDeadlineSeconds) {
            found = chromeWindows().first {
                !before.contains(AccessibilityElementKey(element: $0.window)) && ($0.title?.contains("n=\(nonce)") ?? false)
            }.map { ScenarioWindow(element: $0.window, processIdentifier: $0.processIdentifier, nonce: nonce) }
            return found != nil
        }
        return found
    }

    /// Chrome is frontmost and its focused window IS ours.
    static func isInFront(_ window: ScenarioWindow) -> Bool {
        let read = HarnessHands.browserWindow(processIdentifier: window.processIdentifier)
        return read.frontmost && read.window.map { CFEqual($0, window.element) } == true
    }

    /// Our window's own close button, and nothing else.
    static func close(_ window: ScenarioWindow) -> [String: Any] {
        func present() -> Bool { chromeWindows().contains { CFEqual($0.window, window.element) } }
        guard present() else { return ["closed": true, "note": "already gone"] }
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return ["closed": false, "error": "the runner's window publishes no close button; it was left open"]
        }
        let press = AccessibilityActionPerformer.perform(kAXPressAction, on: button as! AXUIElement)
        let gone = HarnessHands.waitUntil(seconds: closeDeadlineSeconds) { !present() }
        return ["closed": gone, "axErrorRawValue": Int(press.error.rawValue)]
    }

    // MARK: Reads

    static func state(_ window: ScenarioWindow) -> [String: String] { titleState(windowTitle(window.element)) }

    static func nodes(_ window: AXUIElement, processIdentifier: pid_t) -> [AccessibilityElementNode] {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              let root = (try? AccessibilityTreeWalker.snapshotWindow(window, of: application))?.rootNode else { return [] }
        return root.flattenedDescendants()
    }

    static func nodes(_ window: ScenarioWindow) -> [AccessibilityElementNode] { nodes(window.element, processIdentifier: window.processIdentifier) }

    /// The text input labelled `label` (its title, description or placeholder), never a password box.
    static func fieldValue(_ window: ScenarioWindow, labelled label: String) -> (found: Bool, value: String?) {
        guard let field = nodes(window).first(where: {
            AccessibilityElementNode.textInputRoles.contains($0.role) && $0.fieldLabel?.raw == label && !$0.mightBeSecure
        }) else { return (false, nil) }
        return (true, field.value?.raw ?? "")
    }

    /// The page's address: the first `AXWebArea`'s `AXURL` (Chromium puts it a few levels down).
    static func pageURL(inWindow window: AXUIElement) -> URL? {
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < HarnessHands.webAreaSearchLimit {
            let node = queue.removeFirst()
            visited += 1
            var role: AnyObject?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" { return url(of: node) }
            var children: AnyObject?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] { queue += children }
        }
        return nil
    }

    static func url(of element: AXUIElement) -> URL? {
        var address: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &address) == .success else { return nil }
        return (address as? URL) ?? (address as? String).flatMap(URL.init(string:))
    }

    /// Tabs in the window's strip: Chromium publishes each as a tab button.
    static func tabCount(_ window: AXUIElement, processIdentifier: pid_t) -> Int {
        nodes(window, processIdentifier: processIdentifier).filter { $0.subrole == "AXTabButton" }.count
    }

    /// Google's first result: the first link holding a heading, outside Google's own hosts.
    static func firstResultHost(_ window: ScenarioWindow) -> String? {
        guard let root = nodes(window).first else { return nil }
        func firstResult(in node: AccessibilityElementNode) -> String? {
            if node.role == "AXLink", node.children.contains(where: { $0.flattenedDescendants().contains { $0.role == "AXHeading" } }),
               let element = node.accessibilityElement, let host = url(of: element)?.host, !host.contains("google.") {
                return host
            }
            for child in node.children { if let host = firstResult(in: child) { return host } }
            return nil
        }
        return firstResult(in: root)
    }

    /// The AppKit frame of the first text element whose name contains `text`.
    static func frame(ofText text: String, in window: ScenarioWindow) -> CGRect? {
        nodes(window).first { ($0.displayName?.raw.contains(text) ?? false) && $0.frameInAppKitCoordinates.width > 0 }?.frameInAppKitCoordinates
    }

    /// Every name in the window — for text that must, or must not, be on screen.
    static func names(_ window: ScenarioWindow) -> [String] { nodes(window).compactMap { $0.displayName?.raw } }

    // MARK: Other witnesses

    /// The runner's own nudges, so its owner-returned check discounts them —
    /// kept apart from `HarnessHands.ownInput`, which would make the gate discount them too.
    static let nudges = HarnessHands.OwnInputClock()

    /// The owner's hand on the mouse, as the HID system sees it: a 1-pt move,
    /// alternately right and back, so the pointer ends where it was.
    static func nudgeMouse(_ back: Bool) {
        nudges.mark()
        guard let location = CGEvent(source: nil)?.location,
              let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                                  mouseCursorPosition: CGPoint(x: location.x + (back ? -1 : 1), y: location.y), mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Wi-Fi radio on, from CoreWLAN; nil when there is no Wi-Fi interface.
    static func wifiPowerOn() -> Bool? { CWWiFiClient.shared().interface()?.powerOn() }

    /// The front TextEdit document's text, for the cross-app scenarios.
    static func textEditDocumentText() -> String? {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { return nil }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return nodes(window as! AXUIElement, processIdentifier: application.processIdentifier).first { $0.role == "AXTextArea" }?.value?.raw
    }

    /// Files under `directory` changed since `since` that contain `needle` — the
    /// fake key must reach no log (C1). Reads, never prints, what it finds.
    static func filesContaining(_ needle: String, under directories: [URL], since: Date) -> [String] {
        var hits: [String] = []
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                      (values.contentModificationDate ?? .distantPast) >= since,
                      let data = try? Data(contentsOf: file), data.range(of: Data(needle.utf8)) != nil else { continue }
                hits.append(file.lastPathComponent)
            }
        }
        return hits
    }
}
