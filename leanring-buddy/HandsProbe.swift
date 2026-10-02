//
//  HandsProbe.swift
//  leanring-buddy
//
//  `--hands-probe`: the hands (H1) on a page this probe writes itself. It writes
//  one local HTML page — a login form with a "Log In" button that changes the
//  page's text, a signup form (First name / Last name / Email / Company), a
//  contenteditable composer, a plain search box, a Google-style result (a
//  heading inside a link) and a Quill editor like LinkedIn's — opens it
//  in a NEW Chrome window it records by identity, runs `click`, `type` (each
//  method forced once, and the defaults) and `openURL` through
//  `HarnessServer.answer(line:)`, checks every step with its own structure read
//  (never the verb's own verification), writes one JSON summary (0600) to
//  ~/Library/Logs/Clicky/hands-probe/, closes ONLY its window and quits.
//
//  Safety: clicks and keystrokes are real, so this runs WITHOUT
//  --harness-dry-run (and refuses with it: a dry run would measure nothing) —
//  but only on its own window. Before every step it checks that Chrome is in
//  front with THAT window focused, and stops otherwise; every request carries
//  `expectApp`. The window is found by a nonce in its title that was not there
//  before, held as an AX element, and closed by its own close button — never a
//  count, never another window (CLAUDE.md: cleanup undoes WHAT it created). No
//  Apple Events: Clicky has no automation grant or entitlement, so the window is
//  opened the way `open -na "Google Chrome" --args --new-window` does it. The
//  openURL step goes to https://example.com (IANA's reserved page); if its tab
//  lands outside the probe's window it is reported, never touched.
//  Lengths and outcomes only: the summary never carries typed text.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum HandsProbe {
    static let chromeBundleIdentifier = "com.google.Chrome"
    static let windowDeadlineSeconds = 10.0
    static let pageLoadDeadlineSeconds = 10.0
    static let closeDeadlineSeconds = 5.0
    static let openURLTarget = "https://example.com/"
    /// LinkedIn's share box (2026-10-02): a Quill editor whose placeholder is CSS `::before` content.
    static let quillPlaceholder = "Share your thoughts..."

    static var directoryURL: URL {
        MeasurementLogFile.directoryURL.appendingPathComponent("hands-probe", isDirectory: true)
    }

    /// One step: a request, what the probe expects of the verb, and the
    /// independent structure check run after it.
    struct Step {
        let name: String
        let request: [String: Any]
        /// The text typed, for the length check only; never written out.
        var typed: String? = nil
        /// A refusal is the pass for a negative step.
        var expectRefusal: Bool = false
        /// The page text a click must produce.
        var expectStatus: String? = nil
        /// Record what the focused field publishes BEFORE the request (lengths, the placeholder, the caret).
        var measureFocusedField: Bool = false
        /// Record the walk's chain down to the element with this name BEFORE the request.
        var measureChainTo: String? = nil
    }

    static func run(harness: HarnessServer) async {
        await Task.detached { runBlocking(harness: harness) }.value
        MeasurementLogFile.waitForPendingWrites()
    }

    // MARK: Pure

    static func page(nonce: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>hands-probe \(nonce)</title>
        <style>
        body{font:14px -apple-system,sans-serif;margin:10px}
        section{display:inline-block;vertical-align:top;width:290px;margin:4px;padding:6px;border:1px solid #bbb}
        h3{margin:2px 0 6px} input,div[contenteditable]{display:block;width:250px;margin:4px 0;padding:4px}
        div[contenteditable]{min-height:36px;border:1px solid #888}
        .ql-editor p{margin:0} .ql-editor.ql-blank::before{content:attr(data-placeholder);color:#888;font-style:italic;position:absolute;pointer-events:none}
        </style></head><body>
        <section><h3>Login form</h3>
        <input aria-label="Username" placeholder="Username" autocomplete="off">
        <input type="password" aria-label="Password" placeholder="Password" autocomplete="off">
        <button id="login" type="button">Log In</button><p id="status">Not signed in</p></section>
        <section><h3>Signup form</h3>
        <input aria-label="First name" placeholder="First name" autocomplete="off">
        <input aria-label="Last name" placeholder="Last name" autocomplete="off">
        <input type="email" aria-label="Email" placeholder="Email" autocomplete="off">
        <input aria-label="Company" placeholder="Company" autocomplete="off"></section>
        <section><h3>Composer</h3>
        <div contenteditable="true" role="textbox" aria-multiline="true" aria-label="What do you want to talk about?"></div></section>
        <section><h3>Search box</h3><input type="search" aria-label="Search" placeholder="Search" autocomplete="off"></section>
        <section><h3>Search result</h3>
        <a href="#probe-result" id="result"><h3>Probe result title</h3><div><cite>example.com › probe</cite></div></a>
        <p id="rstatus">Result not opened</p></section>
        <section><h3>Rich editor</h3>
        <div id="quill" class="ql-editor ql-blank" contenteditable="true" role="textbox" aria-multiline="true"
         aria-label="Quill composer" data-placeholder="\(quillPlaceholder)"><p><br></p></div></section>
        <script>let n=0;document.getElementById('login').addEventListener('click',()=>{n++;document.getElementById('status').textContent='Log In pressed '+n})
        let r=0;document.getElementById('result').addEventListener('click',e=>{e.preventDefault();r++;document.getElementById('rstatus').textContent='Result opened '+r})
        const q=document.getElementById('quill');q.addEventListener('input',()=>q.classList.toggle('ql-blank',q.textContent.length===0))</script>
        </body></html>
        """
    }

    static func steps(chrome: String) -> [Step] {
        func request(_ fields: [String: Any]) -> [String: Any] { fields.merging(["expectApp": chrome]) { current, _ in current } }
        return [
            Step(name: "click Log In (default)", request: request(["verb": "click", "title": "Log In"])),
            Step(name: "click Log In (forced click)", request: request(["verb": "click", "title": "Log In", "method": "click"])),
            Step(name: "type First name (default)", request: request(["verb": "type", "title": "First name", "text": "Ada"]), typed: "Ada"),
            Step(name: "type Last name (forced keystrokes)",
                 request: request(["verb": "type", "title": "Last name", "text": "Lovelace", "method": "keystrokes"]), typed: "Lovelace"),
            Step(name: "type Email (default)", request: request(["verb": "type", "title": "Email", "text": "ada@example.com"]),
                 typed: "ada@example.com"),
            Step(name: "type Company (forced keystrokes)",
                 request: request(["verb": "type", "title": "Company", "text": "Analytical Engines Ltd", "method": "keystrokes"]),
                 typed: "Analytical Engines Ltd"),
            Step(name: "type Username (forced axWrite)",
                 request: request(["verb": "type", "title": "Username", "text": "probe-user", "method": "axWrite"]), typed: "probe-user"),
            Step(name: "type composer (default)",
                 request: request(["verb": "type", "title": "What do you want to talk about?",
                                   "text": "Hello from the hands probe, typing into a composer 👋"]),
                 typed: "Hello from the hands probe, typing into a composer 👋"),
            Step(name: "click Search field (default)", request: request(["verb": "click", "title": "Search"])),
            Step(name: "type focused search (default)", request: request(["verb": "type", "target": "focused", "text": "linkedin"]),
                 typed: "linkedin"),
            // Live 2026-10-02: a Google result's title is a heading inside its link.
            Step(name: "click result heading (no card)",
                 request: request(["verb": "click", "title": "Probe result title", "role": "AXHeading"]), expectStatus: "Result opened 1",
                 measureChainTo: "Probe result title"),
            // Live 2026-10-02: LinkedIn's empty Quill composer refused caretNotAtEnd.
            Step(name: "click Quill composer", request: request(["verb": "click", "title": "Quill composer"])),
            Step(name: "type focused Quill (default)", request: request(["verb": "type", "target": "focused", "text": "Probe into Quill"]),
                 typed: "Probe into Quill", measureFocusedField: true),
            Step(name: "type Password (must refuse)", request: request(["verb": "type", "title": "Password", "text": "x"]),
                 expectRefusal: true),
            Step(name: "click Password (must refuse)", request: request(["verb": "click", "title": "Password"]), expectRefusal: true),
            Step(name: "openURL example.com", request: ["verb": "openURL", "url": openURLTarget, "app": chrome])
        ]
    }

    /// Counts by method, for the summary's headline.
    static func methodCounts(_ results: [[String: Any]]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for result in results { if let method = result["method"] as? String { counts[method, default: 0] += 1 } }
        return counts
    }

    // MARK: The run

    private static func runBlocking(harness: HarnessServer) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let nonce = String(UUID().uuidString.prefix(8))
        var summary: [String: Any] = ["kind": "handsProbe", "timestamp": stamp, "nonce": nonce, "session": HarnessServer.sessionIdentifier]
        // A run that does nothing still writes why.
        defer { write(summary, named: "hands-probe-\(stamp).json") }

        guard !CommandLine.arguments.contains("--harness-dry-run") else {
            summary["outcome"] = "refused"
            summary["reason"] = "the hands probe measures real clicks and keystrokes on its own window; run it without --harness-dry-run"
            return
        }
        guard !SecureInputState.current().isOn else {
            summary["outcome"] = "refused"
            summary["reason"] = "secure input is on — the owner is typing a password"
            return
        }
        guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleIdentifier) else {
            summary["outcome"] = "noChrome"
            return
        }

        let pageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-hands-probe-\(nonce)", isDirectory: true)
        let pageURL = pageDirectory.appendingPathComponent("hands-probe.html")
        defer { try? FileManager.default.removeItem(at: pageDirectory) }
        do {
            try FileManager.default.createDirectory(at: pageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(page(nonce: nonce).utf8).write(to: pageURL)
        } catch {
            summary["outcome"] = "pageNotWritten"
            summary["error"] = String(describing: error)
            return
        }

        let chromeWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleIdentifier).isEmpty
        summary["chromeWasRunning"] = chromeWasRunning
        let windowsBefore = Set(chromeWindows().map { AccessibilityElementKey(element: $0.window) })

        // `open -na "Google Chrome" --args --new-window <page>`: a second instance
        // hands the command line to the running browser and exits.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = chromeWasRunning
        configuration.arguments = ["--new-window", pageURL.absoluteString]
        configuration.activates = true
        let openStartedAt = Date()
        NSWorkspace.shared.openApplication(at: chromeURL, configuration: configuration) { _, _ in }

        var probeWindow: (window: AXUIElement, processIdentifier: pid_t)?
        HarnessHands.waitUntil(seconds: windowDeadlineSeconds) {
            probeWindow = chromeWindows().first {
                !windowsBefore.contains(AccessibilityElementKey(element: $0.window)) && ($0.title?.contains(nonce) ?? false)
            }.map { ($0.window, $0.processIdentifier) }
            return probeWindow != nil
        }
        guard let probeWindow else {
            summary["outcome"] = "windowNotFound"
            summary["note"] = "no new Chrome window titled with the nonce appeared; nothing was clicked, typed or closed"
            return
        }
        summary["windowMs"] = Int(Date().timeIntervalSince(openStartedAt) * 1000)
        // From here the window exists, so it is closed on every path out.
        defer { summary["cleanup"] = close(probeWindow.window, processIdentifier: probeWindow.processIdentifier) }

        let loaded = HarnessHands.waitUntil(seconds: pageLoadDeadlineSeconds) {
            probeWindowInFront(probeWindow) && windowNames(processIdentifier: probeWindow.processIdentifier).contains("Log In")
        }
        guard loaded else {
            summary["outcome"] = "pageNotReady"
            summary["note"] = "the probe window did not show the page's Log In button in front within \(Int(pageLoadDeadlineSeconds)) s"
            return
        }

        var results: [[String: Any]] = []
        var aborted: String?
        for (index, step) in steps(chrome: chromeBundleIdentifier).enumerated() {
            // Never act on anything but this window: the owner may have moved on.
            guard probeWindowInFront(probeWindow) else {
                aborted = "the probe window was not in front before step \(index + 1); nothing more was done"
                break
            }
            results.append(runStep(step, index: index, harness: harness, probeWindow: probeWindow))
        }

        summary["steps"] = results
        summary["methodCounts"] = methodCounts(results)
        summary["passed"] = results.filter { $0["checkPassed"] as? Bool == true }.count
        summary["total"] = steps(chrome: chromeBundleIdentifier).count
        summary["outcome"] = aborted == nil ? "ran" : "aborted"
        if let aborted { summary["abort"] = aborted }
    }

    private static func runStep(_ step: Step, index: Int, harness: HarnessServer,
                                probeWindow: (window: AXUIElement, processIdentifier: pid_t)) -> [String: Any] {
        var request = step.request
        request["id"] = "hands-probe-\(index + 1)"
        let line = (try? JSONSerialization.data(withJSONObject: request)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let titleBefore = windowTitle(probeWindow.window)
        let fieldBefore = step.measureFocusedField ? focusedFieldFacts(processIdentifier: probeWindow.processIdentifier) : nil
        let chainBefore = step.measureChainTo.map(chainFacts)
        let startedAt = Date()
        let response = (try? JSONSerialization.jsonObject(with: Data(harness.answer(line: line).utf8))) as? [String: Any] ?? [:]
        let verification = response["verification"] as? [String: Any]
        var entry: [String: Any] = [
            "step": step.name,
            "verb": request["verb"] ?? NSNull(),
            "forcedMethod": request["method"] ?? NSNull(),
            "ok": response["ok"] ?? NSNull(),
            "error": response["error"] ?? NSNull(),
            "method": response["method"] ?? NSNull(),
            "kernel": (response["kernel"] as? [String: Any])?["decision"] ?? NSNull(),
            "verification": verification?["status"] ?? NSNull(),
            "evidence": verification?["evidence"] ?? NSNull(),
            "focus": (response["focus"] as? [String: Any])?["method"] ?? NSNull(),
            "ms": Int(Date().timeIntervalSince(startedAt) * 1000)
        ]
        for key in ["resolveMs", "actMs", "verifyMs", "verifyWalks"] { entry[key] = response[key] ?? NSNull() }
        if let fieldBefore { entry["fieldBefore"] = fieldBefore }
        if let chainBefore { entry["chainBefore"] = chainBefore }
        if let resolved = response["resolved"] as? [String: Any] { entry["resolvedRole"] = resolved["role"] ?? NSNull() }
        if let from = response["retargetedFrom"] as? [String: Any] { entry["retargetedFromRole"] = from["role"] ?? NSNull() }
        entry["message"] = response["message"] ?? NSNull()
        if let performed = response["performed"] as? [String: Any] {
            // Lengths, counts and codes only: `performed` never carries text.
            entry["performed"] = performed
        }

        // The independent check: a fresh structure read, never the verb's own word.
        var check: [String: Any]
        if step.expectRefusal {
            check = ["kind": "refused", "passed": response["ok"] as? Bool == false && response["performed"] == nil]
        } else if request["verb"] as? String == "openURL" {
            var titleAfter: String?
            let landed = HarnessHands.waitUntil(seconds: HarnessHands.openURLDeadlineSeconds) {
                titleAfter = windowTitle(probeWindow.window)
                return titleAfter != nil && titleAfter != titleBefore
            }
            check = ["kind": "probeWindowRetitled", "landedInProbeWindow": landed, "passed": landed && response["ok"] as? Bool == true]
            if !landed { check["warning"] = "the page may have opened outside the probe window; it was not touched" }
        } else if let typed = step.typed {
            let field = request["target"] as? String == "focused" ? focusedField(processIdentifier: probeWindow.processIdentifier)
                : field(named: request["title"] as? String ?? "", processIdentifier: probeWindow.processIdentifier)
            // A paragraph editor's own trailing line break is not typed text.
            let length = field?.value?.raw.trimmingCharacters(in: .newlines).count
            check = ["kind": "fieldValueLength", "expected": typed.count, "actual": length ?? NSNull(),
                     "passed": length == typed.count && response["ok"] as? Bool == true]
        } else if let expected = step.expectStatus {
            let seen = HarnessHands.waitUntil(seconds: 2) { windowNames(processIdentifier: probeWindow.processIdentifier).contains(expected) }
            check = ["kind": "statusText", "expected": expected, "passed": seen && response["ok"] as? Bool == true]
        } else if request["title"] as? String == "Log In" {
            let expected = "Log In pressed \(index + 1)"
            let seen = HarnessHands.waitUntil(seconds: 2) { windowNames(processIdentifier: probeWindow.processIdentifier).contains(expected) }
            check = ["kind": "statusText", "expected": expected, "passed": seen && response["ok"] as? Bool == true]
        } else {
            let focused = focusedField(processIdentifier: probeWindow.processIdentifier)
            let onSearch = focused?.fieldLabel?.raw == request["title"] as? String
            check = ["kind": "focusedField", "passed": onSearch && response["ok"] as? Bool == true]
        }
        entry["independentCheck"] = check
        entry["checkPassed"] = check["passed"] as? Bool ?? false
        return entry
    }

    // MARK: Structure reads

    private static func chromeWindows() -> [(window: AXUIElement, title: String?, processIdentifier: pid_t)] {
        NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleIdentifier).flatMap { application in
            let element = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var windows: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement] else { return [(window: AXUIElement, title: String?, processIdentifier: pid_t)]() }
            return list.map { ($0, windowTitle($0), application.processIdentifier) }
        }
    }

    private static func windowTitle(_ window: AXUIElement) -> String? {
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    /// Chrome is the frontmost app and its focused window IS the probe's.
    private static func probeWindowInFront(_ probeWindow: (window: AXUIElement, processIdentifier: pid_t)) -> Bool {
        let read = HarnessHands.browserWindow(processIdentifier: probeWindow.processIdentifier)
        return read.frontmost && read.window.map { CFEqual($0, probeWindow.window) } == true
            && AccessibilityTreeWalker.focusedApplication()?.processIdentifier == probeWindow.processIdentifier
    }

    /// Every name in the focused window, by a fresh walk.
    private static func windowNames(processIdentifier: pid_t) -> Set<String> {
        guard let root = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?.rootNode else { return [] }
        return Set(root.flattenedDescendants().compactMap { $0.displayName?.raw })
    }

    /// The probe page's text input called `name`, by a fresh walk.
    private static func field(named name: String, processIdentifier: pid_t) -> AccessibilityElementNode? {
        guard let root = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?.rootNode else { return nil }
        return root.flattenedDescendants().first {
            AccessibilityElementNode.textInputRoles.contains($0.role) && $0.fieldLabel?.raw == name && !$0.mightBeSecure
        }
    }

    /// What the focused field publishes, on the probe's own page: its value's
    /// length and whether it IS the placeholder, `AXPlaceholderValue`, the caret,
    /// `AXNumberOfCharacters`, and its children's roles.
    private static func focusedFieldFacts(processIdentifier: pid_t) -> [String: Any] {
        guard let element = HarnessHands.focusedElement(processIdentifier: processIdentifier) else { return ["focused": false] }
        func copy(_ attribute: String) -> AnyObject? {
            var out: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
        }
        let value = AccessibilityTypePerformer.stringValue(of: element)
        let range = AccessibilityTypePerformer.selectedRange(of: element)
        let children = (copy(kAXChildrenAttribute) as? [AXUIElement]) ?? []
        let childRoles = children.map { child -> String in
            var role: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            return role as? String ?? "?"
        }
        func describe(_ element: AXUIElement, depth: Int) -> [String: Any] {
            var names: CFArray?
            AXUIElementCopyAttributeNames(element, &names)
            func read(_ attribute: String) -> AnyObject? {
                var out: AnyObject?
                return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
            }
            var entry: [String: Any] = [
                "role": read(kAXRoleAttribute) as? String ?? NSNull(),
                "attributes": (names as? [String]) ?? [],
                "classList": (read("AXDOMClassList") as? [String]) ?? NSNull(),
                "domIdentifier": read("AXDOMIdentifier") as? String ?? NSNull(),
                "valueLength": (read(kAXValueAttribute) as? String)?.count ?? NSNull(),
                "title": read(kAXTitleAttribute) as? String ?? NSNull(),
                "description": read(kAXDescriptionAttribute) as? String ?? NSNull()
            ]
            if depth < 2 {
                entry["children"] = ((read(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { describe($0, depth: depth + 1) }
            }
            return entry
        }
        return [
            "tree": describe(element, depth: 0),
            "role": copy(kAXRoleAttribute) as? String ?? NSNull(),
            "valueLength": value?.count ?? NSNull(),
            "valueUTF16": value.map { Array($0.utf16).prefix(40).map(Int.init) } ?? NSNull(),
            "valueIsPlaceholder": value == quillPlaceholder,
            "placeholderValue": copy(kAXPlaceholderValueAttribute) as? String ?? NSNull(),
            "numberOfCharacters": copy(kAXNumberOfCharactersAttribute) as? Int ?? NSNull(),
            "selectedRange": range.map { ["location": $0.location, "length": $0.length] } ?? NSNull(),
            "childRoles": childRoles
        ]
    }

    /// The walk's chain from the window down to the first element called `name`:
    /// role, name and published actions per level (the probe's own page).
    private static func chainFacts(_ name: String) -> [[String: Any]] {
        guard let root = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?.rootNode,
              let node = root.flattenedDescendants().first(where: { $0.displayName?.raw == name }),
              let chain = ElementReachability.ancestorChain(to: node, from: root) else { return [] }
        return chain.suffix(6).map {
            ["role": $0.role, "name": $0.displayName?.raw ?? NSNull(), "actions": $0.publishedActionNames]
        }
    }

    private static func focusedField(processIdentifier: pid_t) -> AccessibilityElementNode? {
        guard let node = AccessibilityTypePerformer.focusedNode(), !node.mightBeSecure else { return nil }
        return node
    }

    // MARK: Cleanup — this window and nothing else

    private static func close(_ window: AXUIElement, processIdentifier: pid_t) -> [String: Any] {
        func present() -> Bool {
            chromeWindows().contains { CFEqual($0.window, window) }
        }
        guard present() else { return ["closed": true, "note": "the window was already gone"] }
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return ["closed": false, "error": "the probe window publishes no close button; it was left open"]
        }
        let press = AccessibilityActionPerformer.perform(kAXPressAction, on: button as! AXUIElement)
        let gone = HarnessHands.waitUntil(seconds: closeDeadlineSeconds) { !present() }
        return ["closed": gone, "axErrorRawValue": Int(press.error.rawValue),
                "note": gone ? "only the probe's own window was closed" : "the probe window is still open; nothing else was tried"]
    }

    // MARK: Output

    private static func write(_ summary: [String: Any], named name: String) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let line = MeasurementLogFile.jsonLine(summary)
            ?? #"{"kind":"handsProbe","outcome":"summaryNotSerialisable"}"#
        _ = MeasurementLogFile.appendOwnerOnly(Data((line + "\n").utf8), to: directoryURL.appendingPathComponent(name))
        print("🧪 hands probe: \(summary["outcome"] ?? "?") -> \(directoryURL.path)")
    }
}
