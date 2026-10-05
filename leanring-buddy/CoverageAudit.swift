//
//  CoverageAudit.swift
//  leanring-buddy
//
//  `--coverage-audit [--coverage-apps=<bundle id>,…]` (2026-10-06): what the
//  harness can reach straight away in each app, with zero model calls. Per app:
//  bring its existing front window forward (or open one when it has none, and
//  close exactly that one afterwards, by identity), walk AX (`wireDescendants`:
//  never inside a text or password box), OCR a guarded capture of that window
//  (the credential guard runs as for every capture), and index the menu bar.
//  Every OCR text region is classified against the AX frames it sits in
//  (`CoverageClassifier`). Counts only reach disk — never a word of the text.
//  Report: ~/Library/Logs/Clicky/coverage/<ts>/coverage.md + coverage.json.
//  Restores the front app; quits only apps it launched. Read-only: no press,
//  no keystroke, no content change.
//

import AppKit
import ApplicationServices
import Foundation

/// The pure half: which sense can reach a piece of text the owner sees.
nonisolated enum CoverageClassifier {
    enum RegionClass: String, CaseIterable {
        /// Inside an actionable AX element, and an element around it carries these words as its name.
        case axActionable
        /// AX has an element there, but not one that is both actionable and named by these words.
        case axPresent
        /// No AX element smaller than the window's main containers holds it: a vision-click candidate.
        case ocrOnly
        /// No letter or digit at all (an arrow, a bullet): nothing either sense could name.
        case neither
    }

    struct Node: Equatable {
        let frame: CGRect
        let name: String?
        let actionable: Bool
    }

    /// An element covering more than this share of the window is a container (the
    /// window, a web area, a scroll view): being inside it locates nothing.
    static let containerShare: CGFloat = 0.5

    static func classify(text: String, region: CGRect, nodes: [Node], window: CGRect) -> RegionClass {
        let words = RealtimeVoiceVerbs.foldedTokens(text)
        // Not ">= 2": Calculator's "7" and Calendar's "6" are real labels (first audit: 80% "neither").
        guard !words.isEmpty else { return .neither }
        let center = CGPoint(x: region.midX, y: region.midY)
        let windowArea = window.width * window.height
        let around = nodes.filter { node in
            node.frame.width > 0 && node.frame.height > 0
                && (windowArea <= 0 || node.frame.width * node.frame.height < windowArea * containerShare)
                && node.frame.insetBy(dx: -2, dy: -2).contains(center)
        }
        guard !around.isEmpty else { return .ocrOnly }
        let named = around.contains { names($0.name, words) }
        return named && around.contains(where: \.actionable) ? .axActionable : .axPresent
    }

    /// The region's words appear in the element's name (every word for a short
    /// region, half of them for a long one: OCR splits and merges lines).
    static func names(_ name: String?, _ words: [String]) -> Bool {
        guard let name, !words.isEmpty else { return false }
        let nameWords = Set(RealtimeVoiceVerbs.foldedTokens(name))
        guard !nameWords.isEmpty else { return false }
        let hits = words.filter(nameWords.contains).count
        return words.count <= 2 ? hits == words.count : Double(hits) >= Double(words.count) / 2
    }

    /// Actionable elements no OCR region falls in: icons, or text OCR did not read.
    static func iconCount(nodes: [Node], regions: [CGRect]) -> Int {
        nodes.filter { node in
            node.actionable && !regions.contains { node.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: $0.midX, y: $0.midY)) }
        }.count
    }
}

@MainActor
enum CoverageAudit {
    /// Variety over volume: AppKit, Electron, Catalyst/SwiftUI, document, settings, media.
    /// No password manager, nothing finance-related (owner, 2026-10-06).
    static let defaultApps = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.calculator", "com.apple.Notes",
        "com.apple.iCal", "com.apple.ActivityMonitor", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92",
        "com.anthropic.claudefordesktop", "com.google.Chrome", "com.apple.Music", "com.apple.FontBook",
        // Not Freeform: launching it, and reopening it, each made a new board (runs 20-14-36Z, 20-32-50Z).
        "com.apple.Dictionary", "com.apple.reminders", "com.microsoft.VSCode",
        "com.apple.weather", "notion.id",
    ]
    static let forbidden: Set<String> = ["com.apple.Passwords", "com.apple.stocks", "com.1password.1password", "com.agilebits.onepassword7"]

    static func run() async {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = MeasurementLogFile.directoryURL.appendingPathComponent("coverage/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var meta: [String: Any] = ["timestamp": stamp]
        var rows: [[String: Any]] = []
        let original = NSWorkspace.shared.frontmostApplication
        let runStart = ProcessInfo.processInfo.systemUptime
        defer {
            original?.activate()
            write(meta: meta, rows: rows, to: directory)
            print("🗺️ coverage audit: \(meta["outcome"] ?? "?") -> \(directory.path)")
        }
        guard AXIsProcessTrusted() else { meta["outcome"] = "refused"; meta["reason"] = "no Accessibility permission"; return }
        let apps = CommandLine.arguments.first { $0.hasPrefix("--coverage-apps=") }
            .map { $0.dropFirst("--coverage-apps=".count).split(separator: ",").map(String.init) } ?? defaultApps
        for bundle in apps where !forbidden.contains(bundle) {
            // The owner came back: input newer than the run's start (activation posts none).
            if ScenarioRunner.secondsSinceLastInput() + 1 < ProcessInfo.processInfo.systemUptime - runStart {
                meta["outcome"] = "ownerReturned"
                break
            }
            rows.append(await audit(bundle))
            print("🗺️ \(bundle): \(rows.last?["status"] ?? "?")")
        }
        if meta["outcome"] == nil { meta["outcome"] = "ran" }
    }

    nonisolated static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    /// The app's front AXWindow. Never Finder's desktop: it is listed with the windows,
    /// is not an AXWindow, and read as "Finder, 2 nodes, 116 OCR-only regions" (2026-10-06).
    nonisolated static func frontWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success, let value,
               CFGetTypeID(value) == AXUIElementGetTypeID(), isWindow(value as! AXUIElement) { return (value as! AXUIElement) }
        }
        return windows(of: pid).first(where: isWindow)
    }

    /// A window this run opened, closed by its own close button while that same element
    /// answers; gone only when the window server no longer describes it (3bc43b2), and
    /// every close leaves an audit line, since it bypasses the harness (6fb005c).
    nonisolated static func close(_ window: AXUIElement, pid: pid_t, why: String) -> [String: Any] {
        let number = ScenarioRunnerAX.windowNumber(of: window, processIdentifier: pid)
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button,
              CFGetTypeID(button) == AXUIElementGetTypeID() else {
            HarnessServer.auditDirectClose(tool: "CoverageAudit.close", processIdentifier: pid, windowNumber: number, why: why + " (no close button: left open)", closed: false)
            return ["closed": false, "error": "no close button", "windowNumber": number ?? NSNull()]
        }
        let press = AccessibilityActionPerformer.perform(kAXPressAction, on: button as! AXUIElement)
        let gone = HarnessHands.waitUntil(seconds: ScenarioRunnerAX.closeDeadlineSeconds) {
            var role: AnyObject?
            let elementGone = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) != .success
            return number.map { !VoiceToolProbe.windowExists($0) } ?? elementGone
        }
        HarnessServer.auditDirectClose(tool: "CoverageAudit.close", processIdentifier: pid, windowNumber: number, why: why, closed: gone)
        return ["closed": gone, "axErrorRawValue": Int(press.error.rawValue), "windowNumber": number ?? NSNull()]
    }

    nonisolated static func isWindow(_ element: AXUIElement) -> Bool {
        var role: AnyObject?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success && role as? String == kAXWindowRole
    }

    static func waitFor(seconds: Double, _ check: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return check()
    }

    static func audit(_ bundle: String) async -> [String: Any] {
        var row: [String: Any] = ["bundle": bundle]
        var launched = false
        var app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        if app == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { row["status"] = "notInstalled"; return row }
            app = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            launched = app != nil
        }
        guard let app else { row["status"] = "launchFailed"; return row }
        row["name"] = app.localizedName ?? bundle
        row["launchedByAudit"] = launched
        let pid = app.processIdentifier
        defer { if launched { app.terminate() } }

        app.activate()
        let front = await waitFor(seconds: 5) { AccessibilityTreeWalker.focusedApplication()?.processIdentifier == pid }
        row["broughtForward"] = front
        let before = Set(windows(of: pid).map(AccessibilityElementKey.init))
        var openedByAudit: [AXUIElement] = []
        let reopened = frontWindow(of: pid) == nil
        if reopened {
            // `open -b` on a running app is a reopen: most apps answer with a new window.
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-b", bundle]
            try? open.run()
            open.waitUntilExit()
            _ = await waitFor(seconds: 4) { frontWindow(of: pid) != nil }
            openedByAudit = windows(of: pid).filter { !before.contains(AccessibilityElementKey(element: $0)) }
        }
        row["windowsOpenedByAudit"] = openedByAudit.count
        if let window = frontWindow(of: pid) {
            try? await Task.sleep(for: .milliseconds(launched ? 1500 : 600))
            row.merge(await measure(window, of: app)) { _, new in new }
        } else {
            row["status"] = "noWindow"
        }
        if !launched && reopened {
            // Ours by identity, then any window of ours that appeared late (835dfb4): never left behind.
            let ours = openedByAudit
            let closed = await Task.detached { ours.filter(isWindow).map { close($0, pid: pid, why: "coverage audit: the window its reopen opened") } }.value
            row["windowsClosed"] = closed.filter { $0["closed"] as? Bool == true }.count
            row["lateWindows"] = await Task.detached {
                ScenarioRunnerAX.sweepLateWindows(waitSeconds: 3, find: {
                    windows(of: pid).filter { isWindow($0) && !before.contains(AccessibilityElementKey(element: $0)) }
                }, close: { close($0, pid: pid, why: "coverage audit: a late window from its reopen") })
            }.value
        }
        return row
    }

    static func walk(_ window: AXUIElement, of app: NSRunningApplication) async -> Result<AccessibilityWindowSnapshot, Error> {
        await Task.detached { Result { try AccessibilityTreeWalker.snapshotWindow(window, of: app) } }.value
    }

    /// The three senses on one window. Read-only, except the Help menu, opened and closed by its own press.
    static func measure(_ window: AXUIElement, of app: NSRunningApplication) async -> [String: Any] {
        var row: [String: Any] = [:]
        // First contact, as the app is.
        if case .success(let first) = await walk(window, of: app) {
            row["nodesFirstContact"] = first.nodeCount
            row["actionableFirstContact"] = first.rootNode?.wireDescendants().filter(\.isActionable).count ?? 0
        }
        // Chromium builds its tree only for an assistive client: ask, as the harness does, then walk again.
        let pid = app.processIdentifier
        let manual = await Task.detached { AccessibilityTreeWalker.requestManualAccessibility(from: AXUIElementCreateApplication(pid)).rawValue }.value
        row["manualAccessibilityWrite"] = manual
        if manual == 0 { try? await Task.sleep(for: .milliseconds(1500)) }

        // Sense 1: the AX walk.
        let walked = await walk(window, of: app)
        guard case .success(let snapshot) = walked else {
            if case .failure(let error) = walked { row["status"] = "walkFailed"; row["error"] = "\(error)" }
            return row
        }
        let all = snapshot.rootNode?.wireDescendants() ?? []
        let windowFrame = snapshot.rootNode?.frameInAppKitCoordinates ?? .zero
        let nodes = all.map { CoverageClassifier.Node(frame: $0.frameInAppKitCoordinates, name: $0.listedName?.raw, actionable: $0.isActionable) }
        row["axMs"] = Int((snapshot.walkDurationInSeconds * 1000).rounded())
        row["nodes"] = snapshot.nodeCount
        row["depth"] = snapshot.deepestLevelReached
        row["stopReasons"] = snapshot.walkStopReasons.map(\.rawValue).sorted()
        row["nodesWithoutFrame"] = snapshot.nodesWithoutReadableFrame
        row["subtreesLost"] = snapshot.subtreesLostToFailedReads
        row["actionable"] = all.filter(\.isActionable).count
        row["pressable"] = all.filter { $0.publishedActionNames.contains(kAXPressAction as String) && $0.frameInAppKitCoordinates.width > 0 }.count
        row["textFields"] = all.filter { AccessibilityElementNode.textInputRoles.contains($0.role) || $0.mightBeSecure }.count
        row["windowPoints"] = "\(Int(windowFrame.width))x\(Int(windowFrame.height))"

        // Sense 2: OCR of the guarded capture, the window's region only.
        let captureStart = ProcessInfo.processInfo.systemUptime
        var lines: [OCRLine] = []
        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            row["captureMs"] = Int(((ProcessInfo.processInfo.systemUptime - captureStart) * 1000).rounded())
            if let capture = captures.max(by: { $0.displayFrame.intersection(windowFrame).width * $0.displayFrame.intersection(windowFrame).height
                < $1.displayFrame.intersection(windowFrame).width * $1.displayFrame.intersection(windowFrame).height }) {
                row["guard"] = capture.secretGuard?.outcome ?? "none"; row["redactions"] = capture.secretGuard?.drawn.count ?? 0
                let ocrStart = ProcessInfo.processInfo.systemUptime
                let jpeg = capture.imageData, display = capture.displayFrame
                let read = await Task.detached { ScreenOCR.recognize(jpeg: jpeg, region: display) }.value
                row["ocrMs"] = Int(((ProcessInfo.processInfo.systemUptime - ocrStart) * 1000).rounded())
                lines = read.filter { windowFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            }
        } catch let withheld as ScreenSecretGuard.Withheld {
            row["captureWithheld"] = withheld.report.reason ?? "unknown"
        } catch {
            row["captureFailed"] = "\(error)"
        }
        var classes = Dictionary(uniqueKeysWithValues: CoverageClassifier.RegionClass.allCases.map { ($0.rawValue, 0) })
        for line in lines {
            classes[CoverageClassifier.classify(text: line.text, region: line.frame, nodes: nodes, window: windowFrame).rawValue, default: 0] += 1
        }
        row["ocrRegions"] = lines.count
        row["regions"] = classes
        row["iconsNoText"] = lines.isEmpty ? NSNull() : CoverageClassifier.iconCount(nodes: nodes, regions: lines.map(\.frame)) as Any

        // Sense 3: the menu bar.
        let menu = await Task.detached { () -> [String: Any] in
            guard let bar = AccessibilityMenu.menuBarNode(for: app) else { return ["menuError": "no menu bar"] }
            let listing = AccessibilityMenu.list(from: bar, pathSoFar: [], children: AccessibilityMenu.liveChildren,
                                                 deadline: Date().addingTimeInterval(AccessibilityMenu.listingTimeLimitInSeconds))
            let help = listing.items.filter { $0.path.first.map { RealtimeVoiceVerbs.foldedTokens($0) == ["help"] } ?? false }
            return ["menuMs": listing.milliseconds, "menuItems": listing.items.count,
                    "menuEnabled": listing.items.filter(\.isEnabled).count,
                    "menuShortcuts": listing.items.filter { $0.shortcut != nil }.count,
                    "menuStopReasons": listing.stopReasons,
                    "helpItems": help.count,
                    "helpSearchFields": help.filter { AccessibilityElementNode.textInputRoles.contains($0.role) }.count]
        }.value
        row.merge(menu) { _, new in new }
        row.merge(await Task.detached { helpMenuOpened(app) }.value) { _, new in new }
        row["status"] = "ok"
        return row
    }

    /// Whether the Help menu's search field exists once the menu is OPEN (a closed listing
    /// never shows one). Opened by pressing the Help bar item, closed by pressing it again;
    /// `helpClosed` reads its AXSelected back. Never a keystroke.
    nonisolated static func helpMenuOpened(_ app: NSRunningApplication) -> [String: Any] {
        guard let bar = AccessibilityMenu.menuBarNode(for: app),
              let help = AccessibilityMenu.liveChildren(of: bar).last(where: { $0.label.map { RealtimeVoiceVerbs.foldedTokens($0) == ["help"] } ?? false }),
              let item = help.element else { return ["helpMenu": "none"] }
        AXUIElementSetMessagingTimeout(item, 0.5)
        let pressed = AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue
        Thread.sleep(forTimeInterval: 0.6)
        var queue = [help], seen = 0, fields = 0
        while !queue.isEmpty, seen < 80 {
            let node = queue.removeFirst()
            seen += 1
            if AccessibilityElementNode.textInputRoles.contains(node.role) { fields += 1 }
            queue += AccessibilityMenu.liveChildren(of: node)
        }
        var selected: AnyObject?
        AXUIElementCopyAttributeValue(item, kAXSelectedAttribute as CFString, &selected)
        let wasOpen = selected as? Bool
        // 2026-10-06 first run: a second press left it selected in 18 of 18 apps; then AXCancel on the open AXMenu.
        var closedBy = "notOpen"
        if wasOpen == true {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.4)
            AXUIElementCopyAttributeValue(item, kAXSelectedAttribute as CFString, &selected)
            closedBy = (selected as? Bool) == false ? "secondPress" : "stillOpen"
            if closedBy == "stillOpen", let menu = AccessibilityMenu.liveChildren(of: help).first?.element {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                Thread.sleep(forTimeInterval: 0.4)
                AXUIElementCopyAttributeValue(item, kAXSelectedAttribute as CFString, &selected)
                if (selected as? Bool) == false { closedBy = "cancelOnMenu" }
            }
        }
        return ["helpPress": pressed, "helpOpened": wasOpen ?? NSNull(), "helpSearchFieldsOpen": fields, "helpClosedBy": closedBy]
    }

    static func write(meta: [String: Any], rows: [[String: Any]], to directory: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: ["run": meta, "apps": rows], options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: directory.appendingPathComponent("coverage.json").path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("coverage.md").path,
                                       contents: Data(markdown(meta: meta, rows: rows).utf8), attributes: [.posixPermissions: 0o600])
    }

    nonisolated static func markdown(meta: [String: Any], rows: [[String: Any]]) -> String {
        func cell(_ value: Any?) -> String {
            switch value {
            case let number as Int: return "\(number)"
            case let text as String: return text
            case let list as [String]: return list.isEmpty ? "—" : list.joined(separator: ", ")
            default: return "—"
            }
        }
        var text = "# Coverage audit \(meta["timestamp"] ?? "")\n\nOutcome: \(meta["outcome"] ?? "?")\n\n"
        let truncated = rows.filter { !(($0["stopReasons"] as? [String]) ?? []).isEmpty || !(($0["menuStopReasons"] as? [String]) ?? []).isEmpty }
        if !truncated.isEmpty {
            text += "> **THESE COUNTS ARE A FLOOR, NOT A MEASUREMENT for: "
                + truncated.map { "\(cell($0["name"])) (\(cell($0["stopReasons"])); menu \(cell($0["menuStopReasons"])))" }.joined(separator: "; ") + "**\n\n"
        }
        text += "| app | status | first contact nodes/actionable | nodes | actionable | pressable | text fields | OCR regions | AX actionable | AX present | OCR only | neither | icons (no text) | menu items | enabled | shortcuts | help search (closed/open) | AX ms | capture ms | OCR ms | menu ms | stop |\n"
        text += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for row in rows {
            let regions = row["regions"] as? [String: Int] ?? [:]
            let total = max(row["ocrRegions"] as? Int ?? 0, 1)
            func share(_ key: String) -> String {
                guard let count = regions[key], row["ocrRegions"] as? Int ?? 0 > 0 else { return "—" }
                return "\(count) (\(count * 100 / total)%)"
            }
            let status = [cell(row["status"]), row["captureWithheld"].map { "capture withheld: \($0)" }, row["error"].map { "\($0)" }]
                .compactMap { $0 }.joined(separator: "; ")
            text += "| \(cell(row["name"] ?? row["bundle"])) | \(status) | \(cell(row["nodesFirstContact"]))/\(cell(row["actionableFirstContact"])) | \(cell(row["nodes"])) | \(cell(row["actionable"])) | \(cell(row["pressable"])) | "
                + "\(cell(row["textFields"])) | \(cell(row["ocrRegions"])) | \(share("axActionable")) | \(share("axPresent")) | \(share("ocrOnly")) | "
                + "\(share("neither")) | \(cell(row["iconsNoText"])) | \(cell(row["menuItems"])) | \(cell(row["menuEnabled"])) | \(cell(row["menuShortcuts"])) | "
                + "\(cell(row["helpSearchFields"]))/\(cell(row["helpSearchFieldsOpen"])) | \(cell(row["axMs"])) | \(cell(row["captureMs"])) | \(cell(row["ocrMs"])) | \(cell(row["menuMs"])) | "
                + "\(cell(row["stopReasons"])) |\n"
        }
        return text
    }
}
