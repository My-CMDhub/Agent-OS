//
//  GeneralitySuite.swift
//  leanring-buddy
//
//  `--generality-suite [--generality-ids=G01,G02] [--agent-model=gemini-3.8-flash] [--generality-no-files]`
//  (2026-10-06): about twenty tasks over ten-plus apps, each a GENERAL pattern
//  (menu command, list, search field, text entry, settings navigation, dialog,
//  long-list scroll, value read, cross-app, shortcut-reachable command, tabs),
//  each run ONCE through the agent loop with the goal as the owner's words
//  (`AgentLoopProbe.goalRun`). Every task is judged by its own checker reading
//  AX, files or app state in this process — the loop's claim is recorded,
//  never believed; for a read, the spoken answer is compared with a truth read
//  independently. Two held-out apps (Font Book, Dictionary) are named by no
//  code path or prompt outside this file and the coverage audit's list.
//  `voiceScenarios` reuses the same checkers through the scenario runner's
//  spoken fixtures (`--scenario-run --scenario-ids=V01,…`), which also
//  measures delegation: whether the voice model handed the task to do_task.
//
//  Safety: may CREATE "JARVIS test …" items (a note, a reminder, a TextEdit file)
//  and leave them; never sends, posts, invites or deletes. Afterwards it closes
//  only windows that appeared during the task (window-server numbers, any Space,
//  never an AX window seen before, never an edited one) and quits only apps the
//  task launched; new files in ~/Desktop and ~/Documents are listed, never removed.
//  Same start gate as the runner: 120 s owner idle; stops when the owner returns.
//  Report: ~/Library/Logs/Clicky/generality/<ts>/results.json (0600).
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum GeneralitySuite {
    struct SuiteTask {
        let id: String
        let pattern: String
        let words: String
        /// Bundles whose new windows are closed afterwards (or which are quit when the task launched them).
        let apps: [String]
        var heldOut = false
        var findOut = false
        /// A creation task's items: counted right before the task and again at the check, which
        /// passes only on MORE (`createdVerdict`). Presence alone passed on an earlier run's leftovers.
        var created: (bundle: String, match: @Sendable (AccessibilityElementNode) -> Bool)? = nil
        /// A `~/JARVIS-sandbox` task (`LaunchSuite.swift`): the fixture is written fresh before it, the checker gets
        /// `sandboxBefore`/`sandboxAfter` listings, and these paths (what the task was asked to create) are removed after.
        var sandbox: Set<String>? = nil
        /// World reads taken right before the goal run, merged into what the checker gets
        /// (async: E01/E04 launch a quit app behind to read it, `readLaunchingIfNeeded`).
        /// `pre` returning a string under `skipReasonKey` skips the task before the goal run.
        var pre: (() async -> [String: Any])? = nil
        /// (spoken answer, the goal run's report) -> evidence with "passed".
        let check: (_ spoken: String, _ run: [String: Any]) async -> [String: Any]
    }

    nonisolated static let skipReasonKey = "skipReason"
    nonisolated static let finder = "com.apple.finder", settings = "com.apple.systempreferences", notes = "com.apple.Notes",
               reminders = "com.apple.reminders", calendar = "com.apple.iCal", calculator = "com.apple.calculator",
               activity = "com.apple.ActivityMonitor", xcode = "com.apple.dt.Xcode", textEdit = "com.apple.TextEdit",
               fontBook = "com.apple.FontBook", dictionary = "com.apple.Dictionary", cursor = "com.todesktop.230313mzl4w4u92",
               weather = "com.apple.weather", chrome = "com.google.Chrome"

    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    static let tasks: [SuiteTask] = [
        SuiteTask(id: "G01", pattern: "settings pane navigation + read value", words: "what version of macOS is this Mac running? check in System Settings",
                  apps: [settings]) { spoken, _ in answer(spoken, has: [macOSVersion], truth: macOSVersion) },
        SuiteTask(id: "G02", pattern: "menu command (view mode)", words: "open a new Finder window on my Downloads folder and show it as a list",
                  apps: [finder]) { _, _ in
                      let list = await read { windowHas(finder, title: "Downloads") { $0.role == "AXOutline" } }
                      return verdict(list == true, ["downloadsWindowInListView": list as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G03", pattern: "read a count from a list", words: "how many items are in my Downloads folder?",
                  apps: [finder]) { spoken, _ in
                      // No truth, no pass: V03 once "passed" by finding "?" in its own answer (run 20-25-47Z).
                      guard let count = truthArgument("downloads") else { return verdict(false, ["truth": "missing: pass --generality-truth-downloads=<n>"]) }
                      return answer(spoken, has: [count], truth: count)
                  },
        SuiteTask(id: "G04", pattern: "create item + text entry", words: "create a new note in Notes titled JARVIS test 1 with the line hello",
                  apps: [notes], created: (notes, { $0.listedName?.raw.contains("JARVIS test 1") == true })) { _, run in createdVerdict(run) },
        SuiteTask(id: "G05", pattern: "create item (list app)", words: "create a reminder called JARVIS test reminder",
                  apps: [reminders], created: (reminders, { node in
                      [node.listedName?.raw, node.value?.raw].contains { $0?.contains("JARVIS test reminder") == true } })) { _, run in createdVerdict(run) },
        SuiteTask(id: "G06", pattern: "tab / segmented control switch", words: "switch Calendar to the month view",
                  apps: [calendar]) { _, _ in
                      let month = await read { appHas(calendar) { $0.listedName?.raw == "Month" && $0.selected == true } }
                      return verdict(month == true, ["monthSelected": month as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G07", pattern: "Help-menu search", words: "open the Help menu in Calculator and search it for memory",
                  apps: [calculator]) { spoken, run in
                      helpSearchVerdict(calls: run["calls"] as? [[String: Any]] ?? [], spoken: spoken)
                  },
        SuiteTask(id: "G08", pattern: "sort / read a table", words: "which process is using the most memory right now? check Activity Monitor",
                  apps: [activity]) { spoken, _ in
                      let top = topMemoryWords()
                      return answer(spoken, has: top, truth: top.joined(separator: "/"))
                  },
        SuiteTask(id: "G09", pattern: "read a folder count (file tree)", words: "how many files and folders are directly inside the scripts folder of the Heyclicky repo?",
                  apps: [finder, cursor]) { spoken, _ in
                      let count = scriptsCount()
                      return answer(spoken, has: [count], truth: count)
                  },
        SuiteTask(id: "G10", pattern: "button grid + read display", words: "use Calculator to work out 17 times 23",
                  apps: [calculator]) { spoken, _ in
                      let shown = await read { appHas(calculator) { node in [node.listedName?.raw, node.value?.raw].contains { $0?.contains("391") == true } } }
                      var result = answer(spoken, has: ["391"], truth: "391")
                      result["calculatorShows391"] = shown as Any? ?? NSNull()
                      result["passed"] = shown == true && result["passed"] as? Bool == true
                      return result
                  },
        SuiteTask(id: "G11", pattern: "read a toolbar value (IDE)", words: "which scheme is selected in Xcode?",
                  apps: [xcode]) { spoken, _ in answer(spoken, has: ["leanring-buddy", "leanring buddy", "learning buddy", "leanring"], truth: "leanring-buddy") },
        SuiteTask(id: "G12", pattern: "search field + list (held out)", words: "how many styles does the Helvetica family have in Font Book?",
                  apps: [fontBook], heldOut: true) { spoken, _ in
                      let count = NSFontManager.shared.availableMembers(ofFontFamily: "Helvetica")?.count ?? -1
                      return answer(spoken, has: ["\(count)"], truth: "\(count)")
                  },
        SuiteTask(id: "G13", pattern: "search field + read result (held out)", words: "look up the word serendipity in the Dictionary app and tell me what it means",
                  apps: [dictionary], heldOut: true) { spoken, _ in
                      let shown = await read { appHas(dictionary) { $0.listedName?.raw.lowercased().contains("serendipity") == true } }
                      var result = answer(spoken, has: ["chance", "accident", "fortunate", "luck", "happy"], truth: "occurrence by chance in a happy way")
                      result["dictionaryShowsWord"] = shown as Any? ?? NSNull()
                      result["passed"] = shown == true && result["passed"] as? Bool == true
                      return result
                  },
        SuiteTask(id: "G14", pattern: "settings navigation + read a radio state", words: "is my Mac's appearance set to light or dark? check System Settings",
                  apps: [settings]) { spoken, _ in
                      // UserDefaults(suiteName: globalDomain) read nil here and called a Dark Mac "light" (run 20-16-12Z): .standard searches the global domain.
                      let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                      return answer(spoken, has: [dark ? "dark" : "light"], truth: dark ? "dark" : "light")
                  },
        SuiteTask(id: "G15", pattern: "text entry + save dialog", words: "make a new TextEdit document that says JARVIS test 3 and save it to the Desktop named JARVIS test 3",
                  apps: [textEdit]) { _, _ in
                      let saved = await read { documentURLs(textEdit).contains { $0.contains("Desktop/JARVIS%20test%203") } }
                      return verdict(saved == true, ["savedOnDesktop": saved as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G16", pattern: "scroll a long list to an off-screen row", words: "open the Privacy and Security settings",
                  apps: [settings]) { _, _ in
                      let titles = await read { windowTitles(settings) } ?? []
                      return verdict(titles.contains("Privacy & Security"), ["windowTitles": titles])
                  },
        SuiteTask(id: "G17", pattern: "menu command opening an info panel", words: "show me the Get Info window for my Downloads folder",
                  apps: [finder]) { _, _ in
                      let titles = await read { windowTitles(finder) } ?? []
                      return verdict(titles.contains("Downloads Info"), ["infoWindowOpen": titles.contains("Downloads Info")])
                  },
        SuiteTask(id: "G18", pattern: "shortcut-reachable command (Go menu)", words: "open a Finder window showing the Applications folder",
                  apps: [finder]) { _, _ in
                      let titles = await read { windowTitles(finder) } ?? []
                      return verdict(titles.contains("Applications"), ["applicationsWindow": titles.contains("Applications")])
                  },
        SuiteTask(id: "G19", pattern: "find out (connector-answerable)", words: "what's the weather like in Sydney right now?",
                  apps: [weather, chrome], findOut: true) { spoken, _ in
                      let hasTemperature = spoken.range(of: #"\d+\s*(°|degrees|celsius)"#, options: [.regularExpression, .caseInsensitive]) != nil
                      return verdict(hasTemperature, ["answerHasTemperature": hasTemperature, "truth": "unverifiable (no independent weather read)"])
                  },
        SuiteTask(id: "G20", pattern: "find out (connector-answerable)", words: "who originally created the Swift programming language?",
                  apps: [chrome], findOut: true) { spoken, _ in answer(spoken, has: ["Lattner"], truth: "Chris Lattner") },
        SuiteTask(id: "G21", pattern: "cross-app copy", words: "find out which macOS version this Mac runs and write it in a new note titled JARVIS test 2",
                  apps: [settings, notes], created: (notes, { $0.listedName?.raw.contains("JARVIS test 2") == true })) { _, run in
                      let version = macOSVersion
                      let withVersion = await read { appHas(notes) { node in [node.listedName?.raw, node.value?.raw].contains { $0?.contains(version) == true } } }
                      var result = createdVerdict(run)
                      result["versionInNotes"] = withVersion as Any? ?? NSNull()
                      result["passed"] = withVersion == true && result["passed"] as? Bool == true
                      return result
                  },
    ]

    // MARK: Checker helpers (each reads in-process; only booleans and counts are reported)

    nonisolated static func verdict(_ passed: Bool, _ evidence: [String: Any] = [:]) -> [String: Any] {
        evidence.merging(["passed": passed]) { _, new in new }
    }

    /// A read answer: the spoken words carry one of the truths (case-folded).
    /// A creation passed only when the matching count grew; an unreadable count never passes.
    static func createdVerdict(before: Int?, after: Int?) -> [String: Any] {
        guard let before else { return ["passed": false, "countBeforeUnreadable": true, "countAfter": after as Any? ?? NSNull()] }
        guard let after else { return ["passed": false, "countBefore": before, "countAfterUnreadable": true] }
        return ["passed": after > before, "countBefore": before, "countAfter": after]
    }

    static func createdVerdict(_ run: [String: Any]) -> [String: Any] {
        createdVerdict(before: run["countBefore"] as? Int, after: run["countAfter"] as? Int)
    }

    /// Matching nodes across the app's windows on this Space; 0 when the app is not running,
    /// nil when a read failed (never absence). Counts VISIBLE list rows only: an item scrolled
    /// out of a long list is missed, and a selection change can add an editor node — the owner's
    /// leftovers are few. A quit app reads 0 here; `countBeforeLaunchingIfNeeded` launches it first.
    /// The before count with the app's own leftovers in it. These tasks start with the app QUIT
    /// (the suite quits what it launched), and a quit app reads 0 — so yesterday's "JARVIS test
    /// reminder" counted as created when the task launched Reminders (review of e9ff3fa,
    /// 2026-10-12). Launch it behind, count once a window reads (10 s), quit it again so the task starts
    /// as before; anything that does not happen in time is nil, never 0.
    static func countBeforeLaunchingIfNeeded(_ bundle: String, _ match: @escaping @Sendable (AccessibilityElementNode) -> Bool) async -> Int? {
        await readLaunchingIfNeeded(bundle) { appCount(bundle, match) }
    }

    /// Any read of an app that may be quit, by the same launch-behind-and-quit rule.
    static func readLaunchingIfNeeded<T: Sendable>(_ bundle: String, _ body: @escaping @Sendable () -> T?) async -> T? {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first != nil {
            return await Task.detached { body() }.value
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else { return nil }
        var read: T?
        for _ in 0..<50 {   // 10 s: a cold first launch of Reminders took over 5 s (G05 20-05-26Z)
            try? await Task.sleep(for: .milliseconds(200))
            let pid = app.processIdentifier
            let windows = await Task.detached { CoverageAudit.windows(of: pid).count }.value
            // A window can read before its content has loaded: a nil read is asked again until the deadline.
            if windows > 0, let value = await Task.detached(operation: { body() }).value { read = value; break }
        }
        app.terminate()
        for _ in 0..<15 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(200)) }
        return app.isTerminated ? read : nil
    }

    nonisolated static func appCount(_ bundle: String, _ match: (AccessibilityElementNode) -> Bool) -> Int? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return 0 }
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value)
        guard error == .success || error == .noValue else { return nil }
        var count = 0
        for window in value as? [AXUIElement] ?? [] {
            guard let root = (try? AccessibilityTreeWalker.snapshotWindow(window, of: app))?.rootNode else { return nil }
            count += root.flattenedDescendants().filter(match).count
        }
        return count
    }

    static func answer(_ spoken: String, has truths: [String], truth: String) -> [String: Any] {
        let folded = spoken.lowercased()
        // A number must stand alone: "6" is not a hit inside "16 degrees" or "2026".
        let hit = truths.contains { truth in
            guard !truth.isEmpty else { return false }
            guard truth.allSatisfy({ $0.isNumber || $0 == "." }) else { return folded.contains(truth.lowercased()) }
            return folded.range(of: "(?<![0-9.])" + NSRegularExpression.escapedPattern(for: truth) + "(?![0-9])", options: .regularExpression) != nil
        }
        return ["passed": hit, "truth": truth, "answerLength": spoken.count]
    }

    static func truthArgument(_ key: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix("--generality-truth-\(key)=") }.map { String($0.dropFirst("--generality-truth-\(key)=".count)) }
    }

    static func read<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T? {
        await Task.detached { body() }.value
    }

    nonisolated static func pid(_ bundle: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
    }

    nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? String : nil
    }

    nonisolated static func windowTitles(_ bundle: String) -> [String] {
        guard let pid = pid(bundle) else { return [] }
        return CoverageAudit.windows(of: pid).compactMap { string($0, kAXTitleAttribute) }
    }

    nonisolated static func documentURLs(_ bundle: String) -> [String] {
        guard let pid = pid(bundle) else { return [] }
        return CoverageAudit.windows(of: pid).compactMap { string($0, kAXDocumentAttribute) }
    }

    nonisolated static func walk(_ window: AXUIElement, _ bundle: String) -> [AccessibilityElementNode] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              let snapshot = try? AccessibilityTreeWalker.snapshotWindow(window, of: app) else { return [] }
        return snapshot.rootNode?.flattenedDescendants() ?? []
    }

    /// Any node of any of the app's windows on this Space.
    nonisolated static func appHas(_ bundle: String, _ match: (AccessibilityElementNode) -> Bool) -> Bool {
        guard let pid = pid(bundle) else { return false }
        return CoverageAudit.windows(of: pid).contains { walk($0, bundle).contains(where: match) }
    }

    nonisolated static func windowHas(_ bundle: String, title: String, _ match: (AccessibilityElementNode) -> Bool) -> Bool {
        guard let pid = pid(bundle) else { return false }
        return CoverageAudit.windows(of: pid).filter { string($0, kAXTitleAttribute) == title }.contains { walk($0, bundle).contains(where: match) }
    }

    /// G07 by outcome and meaning (owner: checkers judge intent): an ok
    /// search_help whose words hold "memory", and an answer naming one thing it
    /// returned — a topic or menu item sharing two significant words with the
    /// answer (all of them, for a one-word item). Opening the menu proves nothing.
    nonisolated static func helpSearchVerdict(calls: [[String: Any]], spoken: String) -> [String: Any] {
        let searches = calls.filter { $0["tool"] as? String == RealtimeVoiceVerbs.searchHelpName && $0["ok"] as? Bool == true
            && RealtimeVoiceVerbs.foldedTokens($0["words"] as? String ?? "").contains("memory") }
        let found = searches.flatMap { $0["found"] as? [String] ?? [] }
        let said = Set(RealtimeVoiceVerbs.foldedTokens(spoken))
        let named = found.first { entry in
            let words = Set(RealtimeVoiceVerbs.foldedTokens(entry).filter { $0.count >= 3 }).subtracting(RealtimeVoiceVerbs.ignoredQueryWords)
            return !words.isEmpty && words.filter { word in said.contains { RealtimeVoiceVerbs.tokensMatch(word, $0) } }.count >= min(2, words.count)
        }
        return ["passed": named != nil, "memorySearches": searches.count, "resultsReturned": found.count]
    }

    /// Words naming the five biggest processes by memory footprint, the figure
    /// Activity Monitor's Memory column shows (RSS ranked differently, 2026-10-06).
    /// `top` reads every process's footprint without root; its names are cut at 16 chars.
    nonisolated static func topMemoryWords() -> [String] {
        let top = Process()
        top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        top.arguments = ["-l", "1", "-o", "mem", "-n", "5", "-stats", "mem,command"]
        let pipe = Pipe()
        top.standardOutput = pipe
        try? top.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        top.waitUntilExit()
        return topMemoryWords(topOutput: String(decoding: data, as: UTF8.self))
    }

    /// Rows after the `MEM COMMAND` header, in `top`'s own order (sorted by mem).
    nonisolated static func topMemoryWords(topOutput: String) -> [String] {
        let lines = topOutput.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let header = lines.lastIndex(where: { $0.hasPrefix("MEM") }) else { return [] }
        return lines[(header + 1)...].prefix(5).compactMap { line in
            line.split(separator: " ", maxSplits: 1).dropFirst().first?.split(separator: " ").first.map(String.init)
        }.filter { $0.count >= 4 }
    }

    nonisolated static func scriptsCount() -> String {
        let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts")
        let entries = (try? FileManager.default.contentsOfDirectory(at: scripts, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return "\(entries.count)"
    }

    // MARK: Undo by identity

    struct Before {
        var running: Set<String> = []
        var windows: [String: [(number: Int, bounds: CGRect)]] = [:]
        var axWindows: [String: Set<AccessibilityElementKey>] = [:]
        var files: Set<String>?
    }

    static func before(_ apps: [String]) -> Before {
        var state = Before()
        for app in apps {
            if let pid = pid(app) {
                state.running.insert(app)
                state.axWindows[app] = Set(CoverageAudit.windows(of: pid).map(AccessibilityElementKey.init))
            }
            state.windows[app] = VoiceToolProbe.windowServerWindows(bundleIdentifier: app) ?? []
        }
        return state
    }

    /// Closes the AX windows of window-server windows that appeared during the task, unless
    /// edited (a save prompt is the owner's), and reports the rest by title; quits apps the
    /// task launched; lists files it left in ~/Desktop and ~/Documents. Never a count.
    static func undo(_ state: Before, apps: [String]) async -> [String: Any] {
        var closed = 0, quit: [String] = [], left: [String] = []
        for app in apps {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else { continue }
            if !state.running.contains(app) {
                running.terminate()
                quit.append(app)
                continue
            }
            let pid = running.processIdentifier, oldElements = state.axWindows[app] ?? []
            let after = VoiceToolProbe.windowServerSurfaces(bundleIdentifier: app) ?? []
            for window in openedWindows(before: state.windows[app] ?? [], after: after) {
                let why = await Task.detached { () -> String? in
                    guard let match = CoverageAudit.windows(of: pid).first(where: { ScenarioRunnerAX.windowNumber(of: $0, processIdentifier: pid) == window.number }),
                          !oldElements.contains(AccessibilityElementKey(element: match)) else { return "no new AX window with its number" }
                    if ScenarioRunnerReal.hasUnsavedEdits(match) == true { return "unsaved edits" }
                    let done = CoverageAudit.close(match, pid: pid, why: "generality suite: a window that appeared during the task")["closed"] as? Bool == true
                    return done ? nil : "did not close"
                }.value
                if let why { left.append("\(window.title ?? "window \(window.number)"): \(why)") } else { closed += 1 }
            }
        }
        var files: Any = "skipped (--generality-no-files)"
        if !skipsUserFolders {
            let now = await Task.detached { userFolderEntries() }.value
            files = now.flatMap { now in state.files.map { newEntries(before: $0, after: now) } } ?? "unreadable"
        }
        return ["windowsClosed": closed, "appsQuit": quit, "newWindowsLeft": left, "filesCreated": files]
    }

    /// Windows the task opened: a window-server number (any Space) not there before. Never
    /// judged by frame: G15's File > New landed in the frame of the window it had just closed.
    nonisolated static func openedWindows(before: [(number: Int, bounds: CGRect)], after: [WindowServerSurface]) -> [WindowServerSurface] {
        let old = Set(before.map(\.number))
        return after.filter { !old.contains($0.number) && $0.bounds.width > 100 && $0.bounds.height > 60 }
    }

    /// `--generality-no-files`: an unattended run before Clicky has a Files & Folders grant —
    /// the first read of ~/Desktop raises a TCC prompt that blocks until someone answers it.
    nonisolated static var skipsUserFolders: Bool { CommandLine.arguments.contains("--generality-no-files") }

    /// Top-level names in ~/Desktop and ~/Documents; nil when a read fails (no diff beats a false one).
    nonisolated static func userFolderEntries() -> Set<String>? {
        guard !skipsUserFolders else { return nil }
        var names: Set<String> = []
        for folder in ["Desktop", "Documents"] {
            let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder).path
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
            names.formUnion(entries.map { "\(folder)/\($0)" })
        }
        return names
    }

    nonisolated static func newEntries(before: Set<String>, after: Set<String>) -> [String] { after.subtracting(before).sorted() }

    // MARK: Run

    static func run(harness: HarnessServer, confirmations: HarnessConfirmations) async {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let launch = CommandLine.arguments.contains("--launch-suite")
        let directory = MeasurementLogFile.directoryURL.appendingPathComponent("\(launch ? "launch" : "generality")/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var meta: [String: Any] = ["timestamp": stamp, "model": AgentLoopModel.firstModel(.configured), "provider": AgentModelProvider.configured.rawValue,
                                   "suite": launch ? "launch" : "generality"]
        var results: [[String: Any]] = []
        let url = directory.appendingPathComponent("results.json")
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: ["run": meta, "tasks": results], options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
        var filesCreated: [String: [String]] = [:]
        defer {
            meta["filesCreated"] = filesCreated
            save()
            print("🧭 generality suite: \(meta["outcome"] ?? "?") -> \(directory.path)" + (filesCreated.isEmpty ? "" : " | files created (left for the owner): \(filesCreated)"))
        }
        if let refusal = ScenarioRunner.refusalToStart() {
            meta["outcome"] = "refused"
            meta["reason"] = refusal
            return
        }
        let wanted = CommandLine.arguments.first { $0.hasPrefix("--generality-ids=") }
            .map { Set($0.dropFirst("--generality-ids=".count).split(separator: ",").map(String.init)) }
        let runStart = ProcessInfo.processInfo.systemUptime
        for task in launch ? launchTasks : tasks where wanted?.contains(task.id) ?? true {
            let idle = ScenarioRunner.secondsSinceLastInput()
            let ours = min(HarnessHands.ownInput.secondsSinceLastPost ?? .infinity, ProcessInfo.processInfo.systemUptime - runStart)
            if idle + 1 < ours {
                meta["outcome"] = "ownerReturned"
                meta["reason"] = "stopped before \(task.id)"
                break
            }
            // A neutral start: Finder in front, as when the owner asks from the desktop.
            NSRunningApplication.runningApplications(withBundleIdentifier: finder).first?.activate()
            try? await Task.sleep(for: .seconds(1))
            var state = before(task.apps)
            state.files = await Task.detached { userFolderEntries() }.value
            let created = task.created
            var countBefore: Int?? = nil
            if let created { countBefore = .some(await countBeforeLaunchingIfNeeded(created.bundle, created.match)) }
            var result: [String: Any] = ["id": task.id, "pattern": task.pattern, "words": task.words, "heldOut": task.heldOut, "findOut": task.findOut]
            var sandboxBefore: [String: String]?
            if task.sandbox != nil {
                let fixture = Sandbox.setUp(known: Sandbox.knownNames)
                guard let listing = fixture.listing else {
                    result["status"] = "skipped"
                    result["reason"] = "~/JARVIS-sandbox holds items this suite did not create (left for the owner): \(fixture.unknown)"
                    results.append(result)
                    save()
                    print("🧭 \(task.id): skipped — sandbox not clean: \(fixture.unknown)")
                    continue
                }
                sandboxBefore = listing
            }
            let pre = await task.pre?() ?? [:]
            // A pre-read that cannot make the task provable stops it BEFORE the agent acts (E01/E02, 2026-10-14).
            if let reason = pre[skipReasonKey] as? String {
                result["status"] = "skipped"
                result["reason"] = reason
                result["cleanup"] = await undo(state, apps: task.apps)
                if let asked = task.sandbox { _ = Sandbox.tearDown(known: Set(Sandbox.manifest.keys).union(asked)) }
                results.append(result)
                save()
                print("🧭 \(task.id): skipped — \(reason)")
                continue
            }
            let run = await AgentLoopProbe.goalRun(words: task.words, harness: harness, confirmations: confirmations)
            result.merge(run) { current, _ in current }
            let spoken = run["spoken"] as? String ?? ""
            result["modelCalls"] = modelCalls(run: run["run"] as? String ?? "")
            var checked = run.merging(pre) { current, _ in current }
            if let sandboxBefore {
                checked["sandboxBefore"] = sandboxBefore
                checked["sandboxAfter"] = Sandbox.listing() as Any? ?? NSNull()
            }
            if let created {
                checked["countBefore"] = (countBefore ?? nil) as Any
                checked["countAfter"] = await Task.detached { appCount(created.bundle, created.match) }.value
            }
            result["check"] = await task.check(spoken, checked)
            result["status"] = (result["check"] as? [String: Any])?["passed"] as? Bool == true ? "passed" : "failed"
            let cleanup = await undo(state, apps: task.apps)
            result["cleanup"] = cleanup
            if let asked = task.sandbox {
                let down = Sandbox.tearDown(known: Set(Sandbox.manifest.keys).union(asked))
                result["sandboxCleanup"] = ["removed": down.removed, "left": down.left]
                if !down.left.isEmpty { print("🧭 \(task.id): left in ~/JARVIS-sandbox for the owner (not ours to delete): \(down.left)") }
            }
            // Files are reported, never removed: the owner decides (G15 left two on the Desktop unseen).
            let files = cleanup["filesCreated"] as? [String] ?? [], left = cleanup["newWindowsLeft"] as? [String] ?? []
            if !files.isEmpty { filesCreated[task.id] = files }
            results.append(result)
            save()
            print("🧭 \(task.id): \(result["status"] ?? "?") \(run["outcome"] ?? "?") \(run["wallMs"] ?? "?") ms"
                  + (files.isEmpty ? "" : " | files created: \(files)") + (left.isEmpty ? "" : " | windows left: \(left)"))
            try? await Task.sleep(for: .seconds(1))
        }
        if meta["outcome"] == nil { meta["outcome"] = "ran" }
    }

    /// Model calls of one run: its step lines that carry a model time (batched actions share one call).
    static func modelCalls(run: String) -> Int {
        let url = MeasurementLogFile.directoryURL.appendingPathComponent(AgentLoop.traceFileName)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["run"] as? String == run && $0["kind"] as? String == "step" && ($0["modelMs"] as? Int ?? 0) > 0 }.count
    }

    // MARK: The voice path: the same checkers, spoken (`--scenario-run --scenario-ids=V01,…`)

    static let voiceIDs = ["G01": "V01", "G03": "V03", "G10": "V10", "G16": "V16", "G20": "V20"]

    static var voiceScenarios: [RunnerScenario] {
        tasks.compactMap { task in
            guard let id = voiceIDs[task.id] else { return nil }
            return RunnerScenario(id: id, start: .finderFront, quitIfLaunched: task.apps.filter { $0 != finder }, check: { _, outcome in
                let spoken = outcome.transcript
                var result = await task.check(spoken, [:])
                result["delegated"] = outcome.voiceDecisions.contains { $0.call.name == RealtimeVoiceVerbs.doTaskName }
                result["voiceTools"] = outcome.voiceDecisions.map(\.call.name)
                result["taskSteps"] = outcome.agentReport?.steps ?? 0
                return result
            })
        }
    }
}
