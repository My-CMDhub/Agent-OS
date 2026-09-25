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
        /// The name fits more than one app, so the right answer is to ask: no
        /// window rose in any of these apps (extras are closed by `closePath`).
        case noNewWindow(apps: [String], closePath: [String])
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
        // "code" is VS Code's menu-bar name and a word of another installed app's
        // name: the gold answer is a question, never a press (Jev replay: both
        // choosers picked Cursor at 0.90-0.92). Outside the class verdicts.
        MenuScenario(fixture: "18-code-new-window.wav", appClass: "ambiguousName", appName: "Finder", bundleIdentifier: finderBundleIdentifier,
                     check: .noNewWindow(apps: ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode"], closePath: ["File", "Close Window"]),
                     expectedPath: nil, start: nil),
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
        windowServerWindowNumbers(bundleIdentifier: bundleIdentifier)?.count
    }

    /// The same windows' numbers, front to back; `onScreenOnly` for the one in
    /// front. A number is a window's identity: a count is not — one new Chrome
    /// window adds THREE such surfaces (6D5164BC: 1 -> 4), so closing "until the
    /// count is back" overshot into the owner's own windows (9BC0CACB, 4 -> 8 -> 0).
    static func windowServerWindowNumbers(bundleIdentifier: String, onScreenOnly: Bool = false) -> [Int]? {
        windowServerWindows(bundleIdentifier: bundleIdentifier, onScreenOnly: onScreenOnly)?.map(\.number)
    }

    /// Numbers with bounds (window-server coordinates: top-left origin, like AX).
    static func windowServerWindows(bundleIdentifier: String, onScreenOnly: Bool = false) -> [(number: Int, bounds: CGRect)]? {
        guard let processIdentifier = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(Int32.init) == processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.height >= 100,
                  let number = window[kCGWindowNumber as String] as? Int else { return nil }
            return (number, bounds)
        }
    }

    // MARK: Cleanup guards (pure)

    /// Only a press that could have made a window buys a close: the fixture's
    /// own path, or a "New…" item. A stray press elsewhere (a view toggle, a
    /// wrong-app press) never licenses closing anything.
    nonisolated static func pressCountsTowardCloseBudget(path: [String]?, expectedPath: [String]?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        if path == expectedPath { return true }
        return RealtimeVoiceVerbs.foldedTokens(path.last ?? "").first == "new"
    }

    /// Windows that existed before the run and the window server no longer
    /// lists. An unreadable list, or an app that is gone, loses all of them.
    nonisolated static func preexistingWindowsMissing(before: Set<Int>, after: [Int]?) -> Set<Int> {
        guard let after else { return before }
        return before.subtracting(after)
    }

    /// The harness's main window (AppKit coordinates) is the window-server
    /// window in front (top-left): the one Close Window acts on is the one
    /// the numbers say is new. Two points of slack for rounding.
    nonisolated static func sameWindow(harnessMainFrame: CGRect, windowServerBounds: CGRect, primaryDisplayHeight: CGFloat) -> Bool {
        let flipped = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(windowServerBounds, primaryDisplayHeightInPoints: primaryDisplayHeight)
        return abs(flipped.minX - harnessMainFrame.minX) <= 2 && abs(flipped.minY - harnessMainFrame.minY) <= 2
            && abs(flipped.width - harnessMainFrame.width) <= 2 && abs(flipped.height - harnessMainFrame.height) <= 2
    }

    /// The main, unminimized window's frame from a `windows` answer. The wire
    /// keys are x, y, w, h (`HarnessServer.frameJSON`); reading "width" found
    /// nothing, so probe 27BA20D2 refused all 5 Chrome closes.
    nonisolated static func harnessMainFrame(fromWindowsResponse response: [String: Any]) -> CGRect? {
        guard let main = (response["windows"] as? [[String: Any]])?.first(where: { $0["main"] as? Bool == true && $0["minimized"] as? Bool != true }),
              let frame = main["frame"] as? [String: Any],
              let x = frame["x"] as? Double, let y = frame["y"] as? Double,
              let width = frame["w"] as? Double, let height = frame["h"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    enum CleanupStep: Equatable {
        case close(window: Int)
        /// The main window is one the owner had (or the budget is spent): stop.
        case done
        /// Which window Close Window would hit cannot be pinned to one number.
        case refuse(String)
    }

    /// Close Window acts on the harness's MAIN window, so the window to judge
    /// is the one on-screen window-server window with the main window's frame
    /// — not the front-most surface. Probe 44322BA6: full-screen Chrome puts a
    /// 1440x166 toolbar surface in front of every window, so "the front
    /// surface is the main window" refused 3 of 3 closes. Close only when that
    /// one window is new; the owner's window as main means stop.
    nonisolated static func nextCleanupStep(onScreen: [(number: Int, bounds: CGRect)], harnessMainFrame: CGRect?, primaryDisplayHeight: CGFloat,
                                            before: Set<Int>, closed: Int, atMost: Int) -> CleanupStep {
        guard closed < min(atMost, 3) else { return .done }
        guard let harnessMainFrame else { return .refuse("harnessMainWindowUnread") }
        let matches = onScreen.filter { sameWindow(harnessMainFrame: harnessMainFrame, windowServerBounds: $0.bounds, primaryDisplayHeight: primaryDisplayHeight) }
        guard matches.count == 1, let main = matches.first else { return .refuse("mainWindowNotOneOnScreenWindow:\(matches.count)") }
        return before.contains(main.number) ? .done : .close(window: main.number)
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
        // What the model SAID, owner-only (0600), so a flagged receipt claim can
        // be read and judged; the run log still carries no model text.
        let answersFile = VoiceStackBenchmark.openOwnerOnlyAnswersFile(
            at: MeasurementLogFile.directoryURL.appendingPathComponent("voice-tool-probe-answers-\(probeID).jsonl"))
        defer { try? answersFile?.close() }
        var runLines: [[String: Any]] = []
        var abort: String?
        scenarioLoop: for scenario in scenarios {
            guard let (clip16k, clip24k) = clips(forFixture: scenario.fixture) else {
                appendLine(["kind": "fixtureUnreadable", "probeId": probeID, "fixture": scenario.fixture])
                continue
            }
            for runNumber in 1...runsPerStack {
                let order: [VoiceStackChoice] = runNumber % 2 == 1 ? [.openAIRealtime, .geminiLive] : [.geminiLive, .openAIRealtime]
                for stack in order where selectedStacks.contains(stack) {
                    if stack == .openAIRealtime, openAISpentUSD > openAICapUSD { continue }
                    let (line, spentUSD, said) = await measureMenuRun(
                        scenario: scenario, stack: stack, runNumber: runNumber, probeID: probeID,
                        clip: stack == .openAIRealtime ? clip24k : clip16k, harnessAnswer: harnessAnswer)
                    openAISpentUSD += spentUSD
                    appendLine(line)
                    if let answersFile, let answerLine = MeasurementLogFile.jsonLine([
                        "probeId": probeID, "turnId": line["turnId"] ?? NSNull(), "fixture": scenario.fixture, "stack": stack.rawValue,
                        "run": runNumber, "said": said.said, "heard": said.heard
                    ]) {
                        try? answersFile.write(contentsOf: Data((answerLine + "\n").utf8))
                    }
                    runLines.append(line)
                    print("🧪 menu probe: \(scenario.fixture) \(stack.rawValue) #\(runNumber) chain=\(line["chain"] ?? "-") check=\(line["checkPassed"] ?? "-")")
                    // A window the owner had open is gone: stop everything, close nothing more.
                    if let reason = line["abort"] as? String {
                        abort = reason
                        break scenarioLoop
                    }
                }
            }
        }

        if let abort {
            appendLine(["kind": "probeAborted", "probeId": probeID, "reason": abort,
                        "message": "a window that existed before the run is gone; the probe stopped at once and restored nothing"])
            for summaryLine in menuSummaries(runLines, probeID: probeID, openAISpentUSD: openAISpentUSD) { appendLine(summaryLine) }
            print("🛑🛑🛑 menu probe ABORTED: \(abort) — a pre-existing window disappeared. Nothing more was pressed, closed or restored. -> \(logPath)")
            return
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
    ) async -> (line: [String: Any], spentUSD: Double, said: (said: String, heard: String)) {
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
        var windowNumbersBefore: [String: Set<Int>] = [:]
        switch scenario.check {
        case .windowCountRose: windowNumbersBefore[scenario.bundleIdentifier] = windowServerWindowNumbers(bundleIdentifier: scenario.bundleIdentifier).map(Set.init)
        case .noNewWindow(let apps, _):
            for bundleIdentifier in apps { windowNumbersBefore[bundleIdentifier] = windowServerWindowNumbers(bundleIdentifier: bundleIdentifier).map(Set.init) }
        default: break
        }
        let windowsBefore = windowNumbersBefore[scenario.bundleIdentifier]?.count
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
            return (line, 0, ("", ""))
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
        // The app check's key number: a press that landed in an app other than
        // the one the fixture means (for an ask fixture, any press at all), and
        // presses the model AIMED at another app, landed or not.
        let targetBundle: String? = { if case .noNewWindow = scenario.check { return nil }; return scenario.bundleIdentifier }()
        line["wrongAppPresses"] = presses.filter { press in
            press.dispatch?.harnessConfirmed == true && (press.dispatch?.harnessResponse?["bundleIdentifier"] as? String) != targetBundle
        }.count
        // A press the heard check refused never reached the app check, so its aim is resolved here.
        func aimedBundle(_ press: RealtimeToolDecision) -> String? {
            if let bundle = (press.dispatch?.appCheck?["resolvedBundleId"] as? String) ?? (press.dispatch?.harnessResponse?["bundleIdentifier"] as? String) {
                return bundle
            }
            if case .resolved(let bundle, _)? = press.call.appName.map(RealtimeVoiceVerbs.appIdentity(named:)) { return bundle }
            return nil
        }
        line["wrongAppPressAttempts"] = presses.filter { aimedBundle($0) != targetBundle }.count
        // Every acting call (open, focus, press) the heard check refused, whatever the reason.
        line["heardRefusedActingCalls"] = turn.decisions.filter { decision in
            RealtimeVoiceVerbs.isActingTool(decision.call.name) && decision.dispatch?.heardCheck?["refused"] as? Bool == true
        }.count
        line["appChecks"] = turn.decisions.compactMap { $0.dispatch?.appCheck?["outcome"] as? String }
        line["autoFocus"] = turn.decisions.compactMap { $0.dispatch?.autoFocus }
        line["actingOutcome"] = lastActing.map { $0.dispatch.map { $0.harnessConfirmed ? "ok" : ($0.result["error"] as? String ?? "failed") } ?? "unanswered" } ?? "noActingTool"

        // The independent check, then the undo — never more closes than presses that went through there.
        func okPresses(in bundleIdentifier: String) -> Int {
            presses.filter {
                $0.dispatch?.harnessConfirmed == true && $0.dispatch?.harnessResponse?["bundleIdentifier"] as? String == bundleIdentifier
                    && pressCountsTowardCloseBudget(path: $0.call.path, expectedPath: scenario.expectedPath)
            }.count
        }
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
            let cleanup = await closeWindowsTheRunCreated(app: scenario.appName, bundleIdentifier: scenario.bundleIdentifier,
                                                          before: windowNumbersBefore[scenario.bundleIdentifier],
                                                          atMost: okPresses(in: scenario.bundleIdentifier), closePath: closePath, harnessAnswer)
            check["closed"] = cleanup.closed
            if let closeError = cleanup.error { check["closeError"] = closeError }
            if let abort = cleanup.abort { line["abort"] = abort }
        case .noNewWindow(let apps, let closePath):
            var rose: [String] = []
            var closedByApp: [String: Int] = [:]
            for bundleIdentifier in apps {
                let before = windowNumbersBefore[bundleIdentifier]
                let after = windowServerCount(bundleIdentifier: bundleIdentifier)
                guard let before, let after, after > before.count else { continue }
                rose.append(bundleIdentifier)
                // expectApp by bundle identifier: VS Code's menu bar says "Code".
                let cleanup = await closeWindowsTheRunCreated(app: bundleIdentifier, bundleIdentifier: bundleIdentifier,
                                                              before: before, atMost: okPresses(in: bundleIdentifier),
                                                              closePath: closePath, harnessAnswer)
                closedByApp[bundleIdentifier] = cleanup.closed
                if let abort = cleanup.abort { line["abort"] = abort; break }
            }
            // Asking is the only pass: no window rose, and no press, focus or open went through.
            let actedOk = turn.decisions.contains { RealtimeVoiceVerbs.isActingTool($0.call.name) && $0.dispatch?.harnessConfirmed == true }
            check = ["kind": "noNewWindow", "rose": rose, "closed": closedByApp, "actedOk": actedOk,
                     "passed": rose.isEmpty && !actedOk]
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
        return (line, spentUSD, (connection.turn.transcript, connection.turn.heardText))
    }

    /// Closes a window only while the harness's main window (the one Close
    /// Window acts on) is exactly one on-screen window that did not exist
    /// before the run (by number), only if that window is then gone,
    /// and never more times than presses that could have made one (`atMost`).
    /// After every close, every window that existed before must still be
    /// listed; if one is not, `abort` says so and nothing more is closed —
    /// the caller stops the whole probe. A window opened some other way
    /// (open_app) is left, and shows in the count for a person to close.
    private static func closeWindowsTheRunCreated(app: String, bundleIdentifier: String, before: Set<Int>?, atMost: Int, closePath: [String],
                                                  _ harnessAnswer: @escaping @Sendable (String) -> String) async
        -> (closed: Int, error: String?, abort: String?) {
        guard let before else { return (0, nil, nil) }
        var closed = 0
        while true {
            // The budget before anything else: with nothing to close, never bring the app forward.
            guard closed < min(atMost, 3) else { return (closed, nil, nil) }
            // Focus first, then read which window is main (the one Close Window acts on).
            _ = await ask(["verb": "focus", "app": app], harnessAnswer)
            let listing = await ask(["verb": "windows", "app": app, "expectApp": app], harnessAnswer)
            switch nextCleanupStep(onScreen: windowServerWindows(bundleIdentifier: bundleIdentifier, onScreenOnly: true) ?? [],
                                   harnessMainFrame: harnessMainFrame(fromWindowsResponse: listing),
                                   primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height,
                                   before: before, closed: closed, atMost: atMost) {
            case .done:
                return (closed, nil, nil)
            case .refuse(let reason):
                return (closed, reason, nil)
            case .close(let front):
                let beforeClose = Set(windowServerWindowNumbers(bundleIdentifier: bundleIdentifier) ?? [])
                let response = await ask(["verb": "menu", "path": closePath, "expectApp": app], harnessAnswer)
                let started = uptime
                while response["ok"] as? Bool == true, windowServerWindowNumbers(bundleIdentifier: bundleIdentifier)?.contains(front) == true,
                      uptime - started < 2 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let missing = preexistingWindowsMissing(before: before, after: windowServerWindowNumbers(bundleIdentifier: bundleIdentifier))
                if !missing.isEmpty {
                    return (closed, outcome(response), "preexistingWindowGone:\(bundleIdentifier):\(missing.count)of\(before.count)")
                }
                guard response["ok"] as? Bool == true, windowServerWindowNumbers(bundleIdentifier: bundleIdentifier)?.contains(front) == false else {
                    return (closed, outcome(response), nil)
                }
                closed += 1
                // Closing a full-screen window adds a NEW surface for the slide out of its
                // Space (~0.6 s, polled 2026-09-25). The next run read one as "before", saw
                // it go, and aborted on the probe's own window (88AC1E84, 536FCCDB): so wait
                // (<= 3 s) until nothing is listed that was not there before this close.
                let closeSettled = uptime
                while uptime - closeSettled < 3,
                      windowServerWindowNumbers(bundleIdentifier: bundleIdentifier).map({ !Set($0).isSubset(of: beforeClose) }) == true {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
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
                "wrongAppPresses": group.reduce(0) { $0 + (($1["wrongAppPresses"] as? Int) ?? 0) },
                "wrongAppPressAttempts": group.reduce(0) { $0 + (($1["wrongAppPressAttempts"] as? Int) ?? 0) },
                "heardChecks": group.flatMap { ($0["heardChecks"] as? [String]) ?? [] }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 },
                "heardRefusedActingCalls": group.reduce(0) { $0 + (($1["heardRefusedActingCalls"] as? Int) ?? 0) },
                "heardArrivalMs": VoiceBenchStatistics.distribution(of: group.map { ($0["marksMs"] as? [String: Any])?["heardArrivalMs"] as? Int })
                    .map { ["n": $0.count, "medianMs": $0.medianMs, "p95Ms": $0.p95Ms] as [String: Any] } ?? NSNull(),
                "appChecks": group.flatMap { ($0["appChecks"] as? [String]) ?? [] }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 },
                // reason -> count, and how the triggered ones went: "focusStatus/retried".
                "autoFocus": group.flatMap { ($0["autoFocus"] as? [[String: Any]]) ?? [] }.reduce(into: [String: Int]()) { counts, gate in
                    let outcome = gate["triggered"] as? Bool == true ? "/\(gate["focusStatus"] as? String ?? "-")/retried:\(gate["retried"] as? Bool ?? false)" : ""
                    counts["\(gate["reason"] as? String ?? "-")\(outcome)", default: 0] += 1
                },
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
