//
//  VoiceToolProbeMenus.swift
//  leanring-buddy
//
//  `--voice-tool-probe --voice-tool-probe-menus`: the focus and menu verbs
//  (spec slice 4) measured by the owner's per-app-CLASS protocol — two native
//  AppKit apps (Finder, TextEdit) against two non-native ones (Chrome, whose
//  menus are Cocoa over a Chromium window, and Cursor, which is Electron). The
//  hypothesis under test: a menu bar is an NSMenu whatever draws the window, so
//  find -> press works the same in both classes.
//
//  Every run: put the app in a known start state through the harness, bring
//  Finder forward (so the one screenshot a model sees shows Finder, never the
//  owner's Chrome, Cursor or TextEdit content), stream the fixture, then check
//  the outcome with a structure read that does NOT trust the verb — a menu
//  item's checkmark or flipped label re-read through `menus`, a window count
//  through `windows`, frontmost from the harness — and undo it: only windows the
//  count proves the run created are closed, through their own menu item.
//
//  14-16 are ADVERSARIAL: the words share no keyword with the item meant, so
//  they measure the keyword matcher's baseline and whether the model widens its
//  own words on a retry. No synonym or embedding matching, on purpose.
//
//  `--voice-tool-probe-runs=N` (default 5), `--voice-tool-probe-stacks=…`,
//  `--voice-tool-probe-fixtures=06-finder-list-view,…` pick a subset. OpenAI
//  spend is capped at `menuProbeOpenAICostCapUSD`. The post-launch look is off
//  for every run (`sendsFreshLook`), for the privacy reason above.
//

import AppKit
import Foundation

extension VoiceToolProbe {
    static let menuProbeOpenAICostCapUSD = 0.55
    static let menuProbeDefaultRunsPerStack = 5
    static let finderBundleIdentifier = "com.apple.finder"

    enum MenuCheck {
        /// This item carries a checkmark after the run (`AXMenuItemMarkChar`).
        case marked(path: [String])
        /// This item exists after the run: a label that flips ("Hide Path Bar").
        case itemPresent(path: [String])
        /// The app has more windows than before; extras are closed by `closePath`.
        case windowCountRose(closePath: [String])
        /// The app is frontmost.
        case frontmost
    }

    /// A menu item's checkmark and title are refreshed by AppKit's menu
    /// validation, which LAGS an AX press: measured 2026-09-25 (probe
    /// 7D6CDDBB), read straight after pressing View > as Icons, "as List" still
    /// carried its checkmark, and after Hide Path Bar the item still said
    /// "Hide Path Bar" — so pressing it again toggled the bar back on. Every
    /// start state is therefore pressed once and then POLLED until it reads
    /// back, and a start that never reads back is recorded, not assumed.
    enum StartState {
        /// Press this view item, then wait until it carries the checkmark.
        case marked([String])
        /// Wait until `wanted` is listed; if `press` is listed instead, press it once and wait again.
        case label(wanted: [String], press: [String])
    }

    struct MenuScenario {
        let fixture: String
        /// "native" (AppKit) or "nonNative" (Chromium / Electron).
        let appClass: String
        let appName: String
        let bundleIdentifier: String
        let check: MenuCheck
        /// The menu path a correct run presses; nil when the right answer is a focus.
        let expectedPath: [String]?
        /// The start state, set after focusing the app; nil when any state will do.
        let start: StartState?
        /// Launched first if not running (and quit at the end if the probe launched it).
        var launchIfNeeded = false
        /// The words spoken share no keyword with the item meant ("left panel" for
        /// "Hide Sidebar"): the keyword matcher's honest baseline, no synonyms.
        var adversarial = false
    }

    static let menuScenarios: [MenuScenario] = [
        MenuScenario(fixture: "06-finder-list-view.wav", appClass: "native", appName: "Finder", bundleIdentifier: finderBundleIdentifier,
                     check: .marked(path: ["View", "as List"]), expectedPath: ["View", "as List"],
                     start: .marked(["View", "as Icons"])),
        MenuScenario(fixture: "07-finder-icon-view.wav", appClass: "native", appName: "Finder", bundleIdentifier: finderBundleIdentifier,
                     check: .marked(path: ["View", "as Icons"]), expectedPath: ["View", "as Icons"],
                     start: .marked(["View", "as List"])),
        MenuScenario(fixture: "08-finder-path-bar.wav", appClass: "native", appName: "Finder", bundleIdentifier: finderBundleIdentifier,
                     check: .itemPresent(path: ["View", "Hide Path Bar"]),
                     expectedPath: ["View", "Show Path Bar"],
                     start: .label(wanted: ["View", "Show Path Bar"], press: ["View", "Hide Path Bar"])),
        MenuScenario(fixture: "09-finder-new-window.wav", appClass: "native", appName: "Finder", bundleIdentifier: finderBundleIdentifier,
                     check: .windowCountRose(closePath: ["File", "Close Window"]), expectedPath: ["File", "New Finder Window"], start: nil),
        MenuScenario(fixture: "10-textedit-bring-up.wav", appClass: "native", appName: "TextEdit", bundleIdentifier: "com.apple.TextEdit",
                     check: .frontmost, expectedPath: nil, start: nil, launchIfNeeded: true),
        MenuScenario(fixture: "11-textedit-new-document.wav", appClass: "native", appName: "TextEdit", bundleIdentifier: "com.apple.TextEdit",
                     check: .windowCountRose(closePath: ["File", "Close"]), expectedPath: ["File", "New"], start: nil, launchIfNeeded: true),
        // Chrome spells it "New window" (read 2026-09-25); Cursor, like AppKit, "New Window".
        MenuScenario(fixture: "12-chrome-new-window.wav", appClass: "nonNative", appName: "Google Chrome", bundleIdentifier: "com.google.Chrome",
                     check: .windowCountRose(closePath: ["File", "Close Window"]), expectedPath: ["File", "New window"], start: nil),
        MenuScenario(fixture: "13-cursor-new-window.wav", appClass: "nonNative", appName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                     check: .windowCountRose(closePath: ["File", "Close Window"]), expectedPath: ["File", "New Window"], start: nil),
        // "cursor" alone was heard as Calculator, Kasa, Terminal, VS Code in 6/10 runs (7D6CDDBB).
        MenuScenario(fixture: "17-cursor-editor-new-window.wav", appClass: "nonNative", appName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                     check: .windowCountRose(closePath: ["File", "Close Window"]), expectedPath: ["File", "New Window"], start: nil),
        MenuScenario(fixture: "14-finder-hide-left-panel.wav", appClass: "native", appName: "Finder", bundleIdentifier: finderBundleIdentifier,
                     check: .itemPresent(path: ["View", "Show Sidebar"]),
                     expectedPath: ["View", "Hide Sidebar"],
                     start: .label(wanted: ["View", "Hide Sidebar"], press: ["View", "Show Sidebar"]), adversarial: true),
        MenuScenario(fixture: "15-finder-rows.wav", appClass: "native", appName: "Finder", bundleIdentifier: finderBundleIdentifier,
                     check: .marked(path: ["View", "as List"]), expectedPath: ["View", "as List"],
                     start: .marked(["View", "as Icons"]), adversarial: true),
        MenuScenario(fixture: "16-finder-path-thing.wav", appClass: "native", appName: "Finder", bundleIdentifier: finderBundleIdentifier,
                     check: .itemPresent(path: ["View", "Hide Path Bar"]),
                     expectedPath: ["View", "Show Path Bar"],
                     start: .label(wanted: ["View", "Show Path Bar"], press: ["View", "Hide Path Bar"]), adversarial: true)
    ]

    // MARK: Harness helpers

    /// One harness request, off main (`answer` blocks).
    static func ask(_ request: [String: Any], _ harnessAnswer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else { return [:] }
        let line = String(decoding: data, as: UTF8.self)
        return RealtimeOpenAppTool.harnessResponseObject(await Task.detached { harnessAnswer(line) }.value)
    }

    private static func outcome(_ response: [String: Any]) -> String {
        response["ok"] as? Bool == true ? "ok" : (response["error"] as? String ?? "unreadable")
    }

    /// Menu items at or below `prefix`, re-focusing the app once if something
    /// else came forward (reading is harmless; the state checked is the app's).
    private static func menuItems(app: String, prefix: [String], _ harnessAnswer: @escaping @Sendable (String) -> String) async
        -> (items: [[String: Any]], refocused: Bool, error: String?) {
        var response = await ask(["verb": "menus", "path": prefix, "expectApp": app], harnessAnswer)
        var refocused = false
        if response["error"] as? String == "frontmostChanged" {
            _ = await ask(["verb": "focus", "app": app], harnessAnswer)
            refocused = true
            response = await ask(["verb": "menus", "path": prefix, "expectApp": app], harnessAnswer)
        }
        return (response["items"] as? [[String: Any]] ?? [], refocused, response["ok"] as? Bool == true ? nil : outcome(response))
    }

    private static func item(_ path: [String], in items: [[String: Any]]) -> [String: Any]? {
        items.first { ($0["path"] as? [String]) == path }
    }

    /// Re-reads `menus` under `prefix` until `holds` (at most `timeoutSeconds`),
    /// because item state lags a press. The ms it took, or nil if it never held.
    private static func waitForMenuState(app: String, prefix: [String], timeoutSeconds: Double = 5,
                                         _ harnessAnswer: @escaping @Sendable (String) -> String,
                                         holds: ([[String: Any]]) -> Bool) async -> Int? {
        let started = uptime
        repeat {
            if holds(await menuItems(app: app, prefix: prefix, harnessAnswer).items) { return milliseconds(from: started, to: uptime) }
            try? await Task.sleep(for: .milliseconds(100))
        } while uptime - started < timeoutSeconds
        return nil
    }

    /// Sets a start state and reads it back; the outcome names how, and how long.
    private static func setStart(_ start: StartState, app: String, _ harnessAnswer: @escaping @Sendable (String) -> String) async -> String {
        switch start {
        case .marked(let path):
            let pressed = outcome(await ask(["verb": "menu", "path": path, "expectApp": app], harnessAnswer))
            let settled = await waitForMenuState(app: app, prefix: Array(path.dropLast()), harnessAnswer) { item(path, in: $0)?["marked"] as? Bool == true }
            return "press:\(pressed),readBack:\(settled.map { "\($0)ms" } ?? "never")"
        case .label(let wanted, let press):
            // First let any earlier press's title settle, so a stale title is never pressed.
            _ = await waitForMenuState(app: app, prefix: Array(wanted.dropLast()), timeoutSeconds: 2, harnessAnswer) { items in
                item(wanted, in: items) != nil
            }
            if item(wanted, in: await menuItems(app: app, prefix: Array(wanted.dropLast()), harnessAnswer).items) != nil { return "alreadyThere" }
            let pressed = outcome(await ask(["verb": "menu", "path": press, "expectApp": app], harnessAnswer))
            let settled = await waitForMenuState(app: app, prefix: Array(wanted.dropLast()), harnessAnswer) { item(wanted, in: $0) != nil }
            return "press:\(pressed),readBack:\(settled.map { "\($0)ms" } ?? "never")"
        }
    }

    /// The app's normal-level windows as the WINDOW SERVER lists them, on every
    /// Space. Not AX: `kAXWindows` is scoped to the active Space and read 0 for
    /// Chrome straight after a focus in the first run (7D6CDDBB), so a count taken
    /// that way "rose" 0 -> 1 on runs where nothing was pressed. Counts need no
    /// Screen Recording; titles are never read.
    static func windowServerCount(bundleIdentifier: String) -> Int? {
        guard let processIdentifier = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.filter { window in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(Int32.init) == processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue, height >= 100 else { return false }
            return true
        }.count
    }

    /// Polls the window server's count until `holds`, because a window opens or
    /// closes a moment after the press returns.
    private static func windowServerCount(bundleIdentifier: String, timeoutSeconds: Double,
                                          until holds: (Int) -> Bool) async -> Int? {
        let started = uptime
        var count = windowServerCount(bundleIdentifier: bundleIdentifier)
        while let current = count, !holds(current), uptime - started < timeoutSeconds {
            try? await Task.sleep(for: .milliseconds(100))
            count = windowServerCount(bundleIdentifier: bundleIdentifier)
        }
        return count
    }

    // MARK: The run

    static func runMenuScenarios(harness: HarnessServer, probeID: String) async {
        let logPath = MeasurementLogFile.directoryURL.appendingPathComponent(logFileName).path
        let harnessAnswer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        let runsPerStack = runsPerStackArgument(default: menuProbeDefaultRunsPerStack)
        let selectedStacks = selectedStacksArgument()
        let fixtureFilter = CommandLine.arguments.first { $0.hasPrefix("--voice-tool-probe-fixtures=") }
            .map { Set($0.dropFirst("--voice-tool-probe-fixtures=".count).split(separator: ",").map { String($0) + ".wav" }) }
        let scenarios = menuScenarios.filter { fixtureFilter?.contains($0.fixture) ?? true }
        // A lower cap for a re-run, so a session's total stays under its budget.
        let openAICapUSD = CommandLine.arguments.first { $0.hasPrefix("--voice-tool-probe-cap-usd=") }
            .flatMap { Double($0.dropFirst("--voice-tool-probe-cap-usd=".count)) }.map { min($0, menuProbeOpenAICostCapUSD) } ?? menuProbeOpenAICostCapUSD

        JarvisNotch.shared.frontmostWitness = { HarnessServer.frontmostBundleIdentifier() }
        defer { JarvisNotch.shared.frontmostWitness = nil }

        // Finder's own view state, put back at the end: the probe flips the
        // owner's view mode and path bar and must not leave them flipped.
        _ = await ask(["verb": "focus", "app": "Finder"], harnessAnswer)
        let finderViewBefore = await menuItems(app: "Finder", prefix: ["View"], harnessAnswer).items
        let viewModeBefore = finderViewBefore.first { ($0["marked"] as? Bool) == true && (($0["path"] as? [String])?.last?.hasPrefix("as ") ?? false) }?["path"] as? [String]
        let pathBarShownBefore = finderViewBefore.contains { ($0["path"] as? [String]) == ["View", "Hide Path Bar"] }
        let sidebarHiddenBefore = finderViewBefore.contains { ($0["path"] as? [String]) == ["View", "Show Sidebar"] }
        let launchedByProbe = Set(scenarios.filter { $0.launchIfNeeded }.map(\.bundleIdentifier)
            .filter { NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })

        appendLine([
            "kind": "start", "probeId": probeID, "mode": "menus", "fixtures": scenarios.map(\.fixture), "runsPerStack": runsPerStack,
            "openAICostCapUSD": openAICapUSD, "harnessSession": HarnessServer.sessionIdentifier,
            "finderViewModeBefore": viewModeBefore ?? NSNull(), "finderPathBarShownBefore": pathBarShownBefore,
            "finderSidebarHiddenBefore": sidebarHiddenBefore
        ])

        var openAISpentUSD = 0.0
        var runLines: [[String: Any]] = []
        for scenario in scenarios {
            guard let (clip16k, clip24k) = clips(forFixture: scenario.fixture) else {
                appendLine(["kind": "fixtureUnreadable", "probeId": probeID, "fixture": scenario.fixture])
                continue
            }
            for runNumber in 1...runsPerStack {
                let order: [VoiceStackChoice] = runNumber % 2 == 1 ? [.openAIRealtime, .geminiLive] : [.geminiLive, .openAIRealtime]
                for stack in order where selectedStacks.contains(stack) {
                    if stack == .openAIRealtime, openAISpentUSD > openAICapUSD { continue }
                    let (line, spentUSD) = await measureMenuRun(
                        scenario: scenario, stack: stack, runNumber: runNumber, probeID: probeID,
                        clip: stack == .openAIRealtime ? clip24k : clip16k, harnessAnswer: harnessAnswer)
                    openAISpentUSD += spentUSD
                    appendLine(line)
                    runLines.append(line)
                    print("🧪 menu probe: \(scenario.fixture) \(stack.rawValue) #\(runNumber) chain=\(line["chain"] ?? "-") check=\(line["checkPassed"] ?? "-")")
                }
            }
        }

        // Put Finder back as it was, then quit what the probe launched.
        _ = await ask(["verb": "focus", "app": "Finder"], harnessAnswer)
        var restored: [String] = []
        if let viewModeBefore { restored.append(await setStart(.marked(viewModeBefore), app: "Finder", harnessAnswer)) }
        restored.append(await setStart(pathBarShownBefore ? .label(wanted: ["View", "Hide Path Bar"], press: ["View", "Show Path Bar"])
                                                          : .label(wanted: ["View", "Show Path Bar"], press: ["View", "Hide Path Bar"]), app: "Finder", harnessAnswer))
        restored.append(await setStart(sidebarHiddenBefore ? .label(wanted: ["View", "Show Sidebar"], press: ["View", "Hide Sidebar"])
                                                           : .label(wanted: ["View", "Hide Sidebar"], press: ["View", "Show Sidebar"]), app: "Finder", harnessAnswer))
        appendLine(["kind": "finderRestored", "probeId": probeID, "steps": restored])
        for bundleIdentifier in launchedByProbe {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).forEach { $0.terminate() }
        }

        for summaryLine in menuSummaries(runLines, probeID: probeID, openAISpentUSD: openAISpentUSD) { appendLine(summaryLine) }
        print("🧪 menu probe: finished (OpenAI estimated US$\(openAISpentUSD)) -> \(logPath)")
    }

    private static func measureMenuRun(
        scenario: MenuScenario, stack: VoiceStackChoice, runNumber: Int, probeID: String,
        clip: VoiceBenchPCMClip, harnessAnswer: @escaping @Sendable (String) -> String
    ) async -> (line: [String: Any], spentUSD: Double) {
        var line: [String: Any] = [
            "kind": "menuRun", "probeId": probeID, "fixture": scenario.fixture, "appClass": scenario.appClass,
            "app": scenario.appName, "stack": stack.rawValue, "run": runNumber, "adversarial": scenario.adversarial
        ]

        // Start state. The window baseline is read with the app in front, where
        // its windows are listed (`kAXWindows` is scoped to the active Space).
        var setup: [String] = []
        if scenario.launchIfNeeded, NSRunningApplication.runningApplications(withBundleIdentifier: scenario.bundleIdentifier).isEmpty {
            setup.append("launch:" + outcome(await ask(["verb": "launch", "app": scenario.appName], harnessAnswer)))
        }
        setup.append("focus:" + outcome(await ask(["verb": "focus", "app": scenario.appName], harnessAnswer)))
        if let start = scenario.start { setup.append("start:" + (await setStart(start, app: scenario.appName, harnessAnswer))) }
        var windowsBefore: Int?
        if case .windowCountRose = scenario.check { windowsBefore = windowServerCount(bundleIdentifier: scenario.bundleIdentifier) }
        // The check's control: read BEFORE the model acts (after the start state
        // read back), it must fail. One that already reads "done" is never a pass.
        switch scenario.check {
        case .marked(let path), .itemPresent(let path):
            let read = await menuItems(app: scenario.appName, prefix: Array(path.dropLast()), harnessAnswer)
            let item = read.items.first { ($0["path"] as? [String]) == path }
            if case .marked = scenario.check {
                line["checkPassedBeforeRun"] = item?["marked"] as? Bool == true
            } else {
                line["checkPassedBeforeRun"] = item != nil
            }
        default:
            break
        }
        setup.append("focusFinder:" + outcome(await ask(["verb": "focus", "app": "Finder"], harnessAnswer)))
        line["setup"] = setup
        line["windowsBefore"] = windowsBefore ?? NSNull()

        guard let screenshot = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen) else {
            line["errorKind"] = "captureFailed"
            return (line, 0)
        }
        let connection = RealtimeVoiceConnection(stack: stack, harnessAnswer: harnessAnswer)
        connection.sendsFreshLook = false
        defer { connection.close() }
        line.merge(await runTurn(on: connection, clip: clip, screenshotJPEG: screenshot.imageData)) { _, new in new }
        let turn = connection.turn

        // The chain: which tools, in which order, and was each press one it was offered.
        let tools = turn.decisions.map(\.call.name)
        let firstFind = tools.firstIndex(of: RealtimeVoiceVerbs.findMenuItemsName)
        let firstPress = tools.firstIndex(of: RealtimeVoiceVerbs.pressMenuName)
        let presses = turn.decisions.filter { $0.call.name == RealtimeVoiceVerbs.pressMenuName }
        let chose = presses.map { RealtimeDecisionTrace.choseFromOffered(path: $0.call.path, offered: $0.offeredBeforeCall) }
        line["tools"] = tools
        line["expectedPathKnown"] = scenario.expectedPath != nil
        if scenario.expectedPath != nil {
            if let firstPress, let firstFind, firstFind < firstPress {
                line["chain"] = "findThenPress"
            } else {
                line["chain"] = firstPress != nil ? "pressWithoutFind" : firstFind != nil ? "findOnly" : "noMenuTool"
            }
        } else {
            line["chain"] = tools.contains(RealtimeVoiceVerbs.focusAppName) ? "focus"
                : tools.contains(RealtimeOpenAppTool.name) ? "openApp" : "noTool"
        }
        line["presses"] = presses.count
        line["choseFromOffered"] = chose.map { $0.map { $0 as Any } ?? NSNull() }
        line["pressedExpectedPath"] = presses.contains { $0.call.path == scenario.expectedPath }
        line["offeredExpectedPath"] = turn.decisions.contains { $0.dispatch?.menuOffer?.candidates.contains { $0.path == scenario.expectedPath } == true }
        // Did the MODEL widen its words? Every find's words, and a retry with different ones.
        let finds = turn.decisions.filter { $0.call.name == RealtimeVoiceVerbs.findMenuItemsName }
        line["findWords"] = finds.map { $0.call.words ?? "" }
        line["findCalls"] = finds.count
        line["findOfferedCounts"] = finds.map { $0.dispatch?.menuOffer?.candidates.count ?? -1 }
        line["retriedFindWithNewWords"] = Set(finds.map { RealtimeVoiceVerbs.foldedTokens($0.call.words ?? "").joined(separator: " ") }).count > 1
        let lastActing = turn.decisions.last { RealtimeVoiceVerbs.isActingTool($0.call.name) }
        line["actingOutcome"] = lastActing.map { $0.dispatch.map { $0.harnessConfirmed ? "ok" : ($0.result["error"] as? String ?? "failed") } ?? "unanswered" } ?? "noActingTool"

        // The independent check, then the undo.
        var check: [String: Any]
        switch scenario.check {
        case .marked(let path):
            // Polled, not read once: the mark lags the press (see `StartState`).
            let read = await menuItems(app: scenario.appName, prefix: Array(path.dropLast()), harnessAnswer)
            let settled = await waitForMenuState(app: scenario.appName, prefix: Array(path.dropLast()), timeoutSeconds: 3, harnessAnswer) {
                item(path, in: $0)?["marked"] as? Bool == true
            }
            check = ["kind": "menuMark", "path": path, "passed": settled != nil, "readBackMs": settled ?? NSNull(),
                     "refocused": read.refocused, "readError": read.error ?? NSNull()]
        case .itemPresent(let path):
            let read = await menuItems(app: scenario.appName, prefix: Array(path.dropLast()), harnessAnswer)
            let settled = await waitForMenuState(app: scenario.appName, prefix: Array(path.dropLast()), timeoutSeconds: 3, harnessAnswer) {
                item(path, in: $0) != nil
            }
            check = ["kind": "menuLabel", "path": path, "passed": settled != nil, "readBackMs": settled ?? NSNull(),
                     "refocused": read.refocused, "readError": read.error ?? NSNull()]
        case .windowCountRose(let closePath):
            let after = windowServerCount(bundleIdentifier: scenario.bundleIdentifier)
            let passed = { if let before = windowsBefore, let after { return after > before }; return false }()
            check = ["kind": "windowServerCount", "before": windowsBefore ?? NSNull(), "after": after ?? NSNull(), "passed": passed]
            // Close only what the count proves this run created, newest (key) first,
            // re-counting after each so a close that did nothing stops the loop.
            var closed = 0
            if let before = windowsBefore, var current = after {
                while current > before, closed < 3 {
                    var response = await ask(["verb": "menu", "path": closePath, "expectApp": scenario.appName], harnessAnswer)
                    if response["error"] as? String == "frontmostChanged" {
                        _ = await ask(["verb": "focus", "app": scenario.appName], harnessAnswer)
                        response = await ask(["verb": "menu", "path": closePath, "expectApp": scenario.appName], harnessAnswer)
                    }
                    let previous = current
                    guard response["ok"] as? Bool == true,
                          let next = await windowServerCount(bundleIdentifier: scenario.bundleIdentifier, timeoutSeconds: 2, until: { $0 < previous }),
                          next < current else {
                        check["closeError"] = outcome(response)
                        break
                    }
                    current = next
                    closed += 1
                }
            }
            check["closed"] = closed
        case .frontmost:
            let frontmost = HarnessServer.frontmostBundleIdentifier()
            check = ["kind": "frontmost", "expected": scenario.bundleIdentifier, "actual": frontmost ?? NSNull(),
                     "passed": frontmost == scenario.bundleIdentifier]
        }
        line["independentCheck"] = check
        line["checkPassed"] = check["passed"] as? Bool ?? false

        let turnID = UUID().uuidString
        line["turnId"] = turnID
        RealtimeDecisionTrace.append(turn.decisions, turnID: turnID, stack: stack.rawValue, source: "probe",
                                     releasedUptime: turn.lastAudioSentUptime, probeID: probeID,
                                     fixture: scenario.fixture, expectedPath: scenario.expectedPath, independentCheck: check)
        let spentUSD = stack == .openAIRealtime ? connection.estimatedOpenAIUSD : 0
        if stack == .openAIRealtime { line["estimatedCostUSD"] = spentUSD }
        return (line, spentUSD)
    }

    // MARK: Summary

    /// One line per fixture x stack and per class x stack. Counts and timings only.
    static func menuSummaries(_ lines: [[String: Any]], probeID: String, openAISpentUSD: Double) -> [[String: Any]] {
        func summarise(_ group: [[String: Any]], keys: [String: Any]) -> [String: Any] {
            func count(_ key: String) -> Int { group.filter { $0[key] as? Bool == true }.count }
            func tally(_ key: String) -> [String: Int] {
                group.reduce(into: [:]) { counts, line in counts[(line[key] as? String) ?? "-", default: 0] += 1 }
            }
            let chose = group.flatMap { ($0["choseFromOffered"] as? [Any]) ?? [] }
            let spoken = group.map { ($0["marksMs"] as? [String: Any])?["totalToFirstSpokenResultMs"] as? Int }
            let distribution = VoiceBenchStatistics.distribution(of: spoken)
            var line: [String: Any] = [
                "kind": "menuSummary", "probeId": probeID, "runs": group.count,
                "chain": tally("chain"),
                "presses": group.reduce(0) { $0 + (($1["presses"] as? Int) ?? 0) },
                "choseFromOffered": chose.filter { $0 as? Bool == true }.count,
                "choseOutsideOffered": chose.filter { $0 as? Bool == false }.count,
                "pressWithNothingOffered": chose.filter { $0 is NSNull }.count,
                "offeredExpectedPath": count("offeredExpectedPath"),
                "runsWithFind": group.filter { ($0["findCalls"] as? Int ?? 0) > 0 }.count,
                "retriedFindWithNewWords": count("retriedFindWithNewWords"),
                "pressedExpectedPath": count("pressedExpectedPath"),
                "checkPassed": count("checkPassed"),
                // Must be 0: the check already passing before the model acted.
                "checkPassedBeforeRun": count("checkPassedBeforeRun"),
                "actingOutcomes": tally("actingOutcome"),
                "proofViolations": group.reduce(0) { $0 + (($1["proofViolations"] as? Int) ?? 0) },
                "claimedSuccessWithoutReceipt": count("claimedSuccessWithoutReceipt"),
                "errorKinds": group.compactMap { $0["errorKind"] as? String }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 },
                "releaseToSpokenMs": distribution.map { ["n": $0.count, "medianMs": $0.medianMs, "p95Ms": $0.p95Ms] as [String: Any] } ?? NSNull()
            ]
            line.merge(keys) { _, new in new }
            return line
        }
        var summaries: [[String: Any]] = []
        let stacks = Array(Set(lines.compactMap { $0["stack"] as? String })).sorted()
        let fixtures = lines.compactMap { $0["fixture"] as? String }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for fixture in fixtures {
            for stack in stacks {
                let group = lines.filter { $0["fixture"] as? String == fixture && $0["stack"] as? String == stack }
                if !group.isEmpty { summaries.append(summarise(group, keys: ["fixture": fixture, "stack": stack])) }
            }
        }
        // Class verdicts on the plain fixtures only; adversarial ones get their own rows.
        for appClass in ["native", "nonNative"] {
            for stack in stacks {
                let group = lines.filter { $0["appClass"] as? String == appClass && $0["stack"] as? String == stack && $0["adversarial"] as? Bool != true }
                if !group.isEmpty { summaries.append(summarise(group, keys: ["appClass": appClass, "stack": stack])) }
            }
        }
        for adversarial in [false, true] {
            for stack in stacks {
                let group = lines.filter { ($0["adversarial"] as? Bool ?? false) == adversarial && $0["stack"] as? String == stack
                    && $0["expectedPathKnown"] as? Bool == true }
                if !group.isEmpty { summaries.append(summarise(group, keys: ["wording": adversarial ? "adversarial" : "plain", "stack": stack])) }
            }
        }
        summaries.append(["kind": "menuSummary", "probeId": probeID, "estimatedOpenAICostUSD": openAISpentUSD])
        return summaries
    }
}
