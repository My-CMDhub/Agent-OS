//
//  GeneralitySuite.swift
//  leanring-buddy
//
//  `--generality-suite [--generality-ids=G01,G02] [--agent-model=gemini-3.8-flash]`
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
//  matched to the AX window by frame) and quits only apps the task launched.
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
        /// (spoken answer) -> evidence with "passed".
        let check: (String) async -> [String: Any]
    }

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
                  apps: [settings]) { spoken in answer(spoken, has: [macOSVersion], truth: macOSVersion) },
        SuiteTask(id: "G02", pattern: "menu command (view mode)", words: "open a new Finder window on my Downloads folder and show it as a list",
                  apps: [finder]) { _ in
                      let list = await read { windowHas(finder, title: "Downloads") { $0.role == "AXOutline" } }
                      return verdict(list == true, ["downloadsWindowInListView": list as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G03", pattern: "read a count from a list", words: "how many items are in my Downloads folder?",
                  apps: [finder]) { spoken in
                      // No truth, no pass: V03 once "passed" by finding "?" in its own answer (run 20-25-47Z).
                      guard let count = truthArgument("downloads") else { return verdict(false, ["truth": "missing: pass --generality-truth-downloads=<n>"]) }
                      return answer(spoken, has: [count], truth: count)
                  },
        SuiteTask(id: "G04", pattern: "create item + text entry", words: "create a new note in Notes titled JARVIS test 1 with the line hello",
                  apps: [notes]) { _ in
                      let found = await read { appHas(notes) { $0.listedName?.raw.contains("JARVIS test 1") == true } }
                      return verdict(found == true, ["noteVisible": found as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G05", pattern: "create item (list app)", words: "create a reminder called JARVIS test reminder",
                  apps: [reminders]) { _ in
                      let found = await read { appHas(reminders) { node in
                          [node.listedName?.raw, node.value?.raw].contains { $0?.contains("JARVIS test reminder") == true } } }
                      return verdict(found == true, ["reminderVisible": found as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G06", pattern: "tab / segmented control switch", words: "switch Calendar to the month view",
                  apps: [calendar]) { _ in
                      let month = await read { appHas(calendar) { $0.listedName?.raw == "Month" && $0.selected == true } }
                      return verdict(month == true, ["monthSelected": month as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G07", pattern: "Help-menu search", words: "open the Help menu in Calculator and search it for memory",
                  apps: [calculator]) { _ in
                      let typed = await read { helpSearchLength(calculator) } ?? nil
                      return verdict((typed ?? 0) > 0, ["helpSearchLength": typed as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G08", pattern: "sort / read a table", words: "which process is using the most memory right now? check Activity Monitor",
                  apps: [activity]) { spoken in
                      let top = topMemoryWords()
                      return answer(spoken, has: top, truth: top.joined(separator: "/"))
                  },
        SuiteTask(id: "G09", pattern: "read a folder count (file tree)", words: "how many files and folders are directly inside the scripts folder of the Heyclicky repo?",
                  apps: [finder, cursor]) { spoken in
                      let count = scriptsCount()
                      return answer(spoken, has: [count], truth: count)
                  },
        SuiteTask(id: "G10", pattern: "button grid + read display", words: "use Calculator to work out 17 times 23",
                  apps: [calculator]) { spoken in
                      let shown = await read { appHas(calculator) { node in [node.listedName?.raw, node.value?.raw].contains { $0?.contains("391") == true } } }
                      var result = answer(spoken, has: ["391"], truth: "391")
                      result["calculatorShows391"] = shown as Any? ?? NSNull()
                      result["passed"] = shown == true && result["passed"] as? Bool == true
                      return result
                  },
        SuiteTask(id: "G11", pattern: "read a toolbar value (IDE)", words: "which scheme is selected in Xcode?",
                  apps: [xcode]) { spoken in answer(spoken, has: ["leanring-buddy", "leanring buddy", "learning buddy", "leanring"], truth: "leanring-buddy") },
        SuiteTask(id: "G12", pattern: "search field + list (held out)", words: "how many styles does the Helvetica family have in Font Book?",
                  apps: [fontBook], heldOut: true) { spoken in
                      let count = NSFontManager.shared.availableMembers(ofFontFamily: "Helvetica")?.count ?? -1
                      return answer(spoken, has: ["\(count)"], truth: "\(count)")
                  },
        SuiteTask(id: "G13", pattern: "search field + read result (held out)", words: "look up the word serendipity in the Dictionary app and tell me what it means",
                  apps: [dictionary], heldOut: true) { spoken in
                      let shown = await read { appHas(dictionary) { $0.listedName?.raw.lowercased().contains("serendipity") == true } }
                      var result = answer(spoken, has: ["chance", "accident", "fortunate", "luck", "happy"], truth: "occurrence by chance in a happy way")
                      result["dictionaryShowsWord"] = shown as Any? ?? NSNull()
                      result["passed"] = shown == true && result["passed"] as? Bool == true
                      return result
                  },
        SuiteTask(id: "G14", pattern: "settings navigation + read a radio state", words: "is my Mac's appearance set to light or dark? check System Settings",
                  apps: [settings]) { spoken in
                      // UserDefaults(suiteName: globalDomain) read nil here and called a Dark Mac "light" (run 20-16-12Z): .standard searches the global domain.
                      let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                      return answer(spoken, has: [dark ? "dark" : "light"], truth: dark ? "dark" : "light")
                  },
        SuiteTask(id: "G15", pattern: "text entry + save dialog", words: "make a new TextEdit document that says JARVIS test 3 and save it to the Desktop named JARVIS test 3",
                  apps: [textEdit]) { _ in
                      let saved = await read { documentURLs(textEdit).contains { $0.contains("Desktop/JARVIS%20test%203") } }
                      return verdict(saved == true, ["savedOnDesktop": saved as Any? ?? NSNull()])
                  },
        SuiteTask(id: "G16", pattern: "scroll a long list to an off-screen row", words: "open the Privacy and Security settings",
                  apps: [settings]) { _ in
                      let titles = await read { windowTitles(settings) } ?? []
                      return verdict(titles.contains("Privacy & Security"), ["windowTitles": titles])
                  },
        SuiteTask(id: "G17", pattern: "menu command opening an info panel", words: "show me the Get Info window for my Downloads folder",
                  apps: [finder]) { _ in
                      let titles = await read { windowTitles(finder) } ?? []
                      return verdict(titles.contains("Downloads Info"), ["infoWindowOpen": titles.contains("Downloads Info")])
                  },
        SuiteTask(id: "G18", pattern: "shortcut-reachable command (Go menu)", words: "open a Finder window showing the Applications folder",
                  apps: [finder]) { _ in
                      let titles = await read { windowTitles(finder) } ?? []
                      return verdict(titles.contains("Applications"), ["applicationsWindow": titles.contains("Applications")])
                  },
        SuiteTask(id: "G19", pattern: "find out (connector-answerable)", words: "what's the weather like in Sydney right now?",
                  apps: [weather, chrome], findOut: true) { spoken in
                      let hasTemperature = spoken.range(of: #"\d+\s*(°|degrees|celsius)"#, options: [.regularExpression, .caseInsensitive]) != nil
                      return verdict(hasTemperature, ["answerHasTemperature": hasTemperature, "truth": "unverifiable (no independent weather read)"])
                  },
        SuiteTask(id: "G20", pattern: "find out (connector-answerable)", words: "who originally created the Swift programming language?",
                  apps: [chrome], findOut: true) { spoken in answer(spoken, has: ["Lattner"], truth: "Chris Lattner") },
        SuiteTask(id: "G21", pattern: "cross-app copy", words: "find out which macOS version this Mac runs and write it in a new note titled JARVIS test 2",
                  apps: [settings, notes]) { _ in
                      let version = macOSVersion
                      let titled = await read { appHas(notes) { $0.listedName?.raw.contains("JARVIS test 2") == true } }
                      let withVersion = await read { appHas(notes) { node in [node.listedName?.raw, node.value?.raw].contains { $0?.contains(version) == true } } }
                      return verdict(titled == true && withVersion == true, ["noteTitled": titled as Any? ?? NSNull(), "versionInNotes": withVersion as Any? ?? NSNull()])
                  },
    ]

    // MARK: Checker helpers (each reads in-process; only booleans and counts are reported)

    static func verdict(_ passed: Bool, _ evidence: [String: Any] = [:]) -> [String: Any] {
        evidence.merging(["passed": passed]) { _, new in new }
    }

    /// A read answer: the spoken words carry one of the truths (case-folded).
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

    /// The length of what is typed in the Help menu's search field (menus are read whether open or not).
    nonisolated static func helpSearchLength(_ bundle: String) -> Int? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              let bar = AccessibilityMenu.menuBarNode(for: app),
              let help = AccessibilityMenu.liveChildren(of: bar).last(where: { $0.label.map { RealtimeVoiceVerbs.foldedTokens($0) == ["help"] } ?? false })
        else { return nil }
        var queue = [help], seen = 0
        while !queue.isEmpty, seen < 60 {
            let node = queue.removeFirst()
            seen += 1
            if AccessibilityElementNode.textInputRoles.contains(node.role), let element = node.element {
                return string(element, kAXValueAttribute)?.count ?? 0
            }
            queue += AccessibilityMenu.liveChildren(of: node)
        }
        return nil
    }

    /// Words naming the five biggest processes by resident memory ("Claude", "Xcode"…).
    nonisolated static func topMemoryWords() -> [String] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "rss=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int, String)? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let rss = Int(parts[0]) else { return nil }
            return (rss, (String(parts[1]) as NSString).lastPathComponent)
        }
        return rows.sorted { $0.0 > $1.0 }.prefix(5).compactMap { $0.1.split(separator: " ").first.map(String.init) }
            .filter { $0.count >= 4 }
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
    }

    static func before(_ apps: [String]) -> Before {
        var state = Before()
        for app in apps {
            if pid(app) != nil { state.running.insert(app) }
            state.windows[app] = VoiceToolProbe.windowServerWindows(bundleIdentifier: app) ?? []
        }
        return state
    }

    nonisolated static func rawFrame(_ window: AXUIElement) -> CGRect? {
        var position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Closes the AX windows matching a window-server window that appeared during the task
    /// (and no window there before); quits apps the task launched. Never a count.
    static func undo(_ state: Before, apps: [String]) async -> [String: Any] {
        var closed = 0, quit: [String] = [], left = 0
        for app in apps {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else { continue }
            if !state.running.contains(app) {
                running.terminate()
                quit.append(app)
                continue
            }
            let old = state.windows[app] ?? []
            let new = (VoiceToolProbe.windowServerWindows(bundleIdentifier: app) ?? []).filter { window in !old.contains { $0.number == window.number } }
            let oldBounds = old.map(\.bounds)
            for window in new where window.bounds.width > 100 && window.bounds.height > 60 && !oldBounds.contains(window.bounds) {
                let pid = running.processIdentifier
                let done = await Task.detached { () -> Bool in
                    guard let match = CoverageAudit.windows(of: pid).first(where: { rawFrame($0) == window.bounds }) else { return false }
                    return CoverageAudit.close(match, pid: pid, why: "generality suite: a window that appeared during the task") ["closed"] as? Bool == true
                }.value
                if done { closed += 1 } else { left += 1 }
            }
        }
        return ["windowsClosed": closed, "appsQuit": quit, "newWindowsLeft": left]
    }

    // MARK: Run

    static func run(harness: HarnessServer, confirmations: HarnessConfirmations) async {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = MeasurementLogFile.directoryURL.appendingPathComponent("generality/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var meta: [String: Any] = ["timestamp": stamp, "model": AgentLoopGemini.firstModel(), "provider": AgentModelProvider.configured.rawValue]
        var results: [[String: Any]] = []
        let url = directory.appendingPathComponent("results.json")
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: ["run": meta, "tasks": results], options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
        defer { save(); print("🧭 generality suite: \(meta["outcome"] ?? "?") -> \(directory.path)") }
        if let refusal = ScenarioRunner.refusalToStart() {
            meta["outcome"] = "refused"
            meta["reason"] = refusal
            return
        }
        let wanted = CommandLine.arguments.first { $0.hasPrefix("--generality-ids=") }
            .map { Set($0.dropFirst("--generality-ids=".count).split(separator: ",").map(String.init)) }
        let runStart = ProcessInfo.processInfo.systemUptime
        for task in tasks where wanted?.contains(task.id) ?? true {
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
            let state = before(task.apps)
            var result: [String: Any] = ["id": task.id, "pattern": task.pattern, "words": task.words, "heldOut": task.heldOut, "findOut": task.findOut]
            let run = await AgentLoopProbe.goalRun(words: task.words, harness: harness, confirmations: confirmations)
            result.merge(run) { current, _ in current }
            let spoken = run["spoken"] as? String ?? ""
            result["modelCalls"] = modelCalls(run: run["run"] as? String ?? "")
            result["check"] = await task.check(spoken)
            result["status"] = (result["check"] as? [String: Any])?["passed"] as? Bool == true ? "passed" : "failed"
            result["cleanup"] = await undo(state, apps: task.apps)
            results.append(result)
            save()
            print("🧭 \(task.id): \(result["status"] ?? "?") \(run["outcome"] ?? "?") \(run["wallMs"] ?? "?") ms")
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
                var result = await task.check(spoken)
                result["delegated"] = outcome.voiceDecisions.contains { $0.call.name == RealtimeVoiceVerbs.doTaskName }
                result["voiceTools"] = outcome.voiceDecisions.map(\.call.name)
                result["taskSteps"] = outcome.agentReport?.steps ?? 0
                return result
            })
        }
    }
}
