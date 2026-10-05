//
//  ScenarioRunnerReal.swift
//  leanring-buddy
//
//  Section R of the scenario runner: real apps doing real workflows, timed, so
//  J.A.R.V.I.S. can be benchmarked against a person and against HeyClicky
//  (spec docs/superpowers/specs/2026-10-03-scenario-test-set.md, section R).
//  Cursor on THIS repo and Chrome on the live web, read-only.
//
//  The witnesses are structure J.A.R.V.I.S. never reports itself:
//  - Cursor's active editor is the window's `AXDocument` (a file URL), read
//    straight off the AXWindow — the title only echoes it.
//  - Unsaved editor state is the close button's `AXEdited` (Electron's
//    documentEdited dot): any dirty buffer in that window.
//  - A terminal is its shell process: a new child of Cursor's pty host, by pid.
//    Killing a terminal ends that shell; hiding the panel does not.
//  - An editor tab is known by the file it names ("AgentLoop.swift, preview,
//    Editor Group 1"), never by its AX element: VS Code reuses tab elements and
//    relabels them, so an element seen before can name a different file now.
//
//  Measured 2026-10-05 on a Cursor window opened on this repo: 780 nodes, the
//  restored terminal answered "Terminal 1, bash", the agent pane's mode read
//  "Ask", and closing the window ended its shell (97632 gone).
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum ScenarioRunnerReal {
    static let cursorBundleIdentifier = "com.todesktop.230313mzl4w4u92"
    /// This repo (the owner chose it for the Cursor scenarios).
    static let repositoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let cursorOpenDeadlineSeconds = 15.0

    // MARK: Pure

    /// "AgentLoop.swift, preview, Editor Group 1" -> "AgentLoop.swift".
    static func editorTabFileName(_ description: String) -> String {
        description.components(separatedBy: ", ").first ?? description
    }

    /// Letters and digits only, lowercased: how two texts are compared when one was spoken.
    static func letters(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Words of 3+ letters, lowercased.
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
    }

    /// The spoken answer carries a commit subject: at least 70% of its words, after
    /// a conventional-commit prefix ("fix(voice): "), which is never read aloud the same way twice.
    static func spokeCommitSubject(_ transcript: String, subject: String) -> Bool {
        let body = subject.range(of: #"^[a-z]+(\([^)]*\))?!?:\s*"#, options: .regularExpression).map { String(subject[$0.upperBound...]) } ?? subject
        let wanted = words(body)
        guard !wanted.isEmpty else { return false }
        let heard = Set(words(transcript))
        return Double(wanted.filter(heard.contains).count) / Double(wanted.count) >= 0.7
    }

    /// The spoken answer carries a heading: every one of its words (3+ letters), or the whole of it run together.
    static func spokeHeading(_ transcript: String, heading: String) -> Bool {
        let wanted = words(heading)
        if !wanted.isEmpty, Set(wanted).isSubset(of: Set(words(transcript))) { return true }
        let compact = letters(heading)
        return !compact.isEmpty && letters(transcript).contains(compact)
    }

    /// Text in Cursor's chat that is the question, as typed by the voice (any case or punctuation).
    static func isTheQuestion(_ text: String) -> Bool {
        let compact = letters(text)
        return compact.contains("agentloopswift") && compact.contains("what")
    }

    /// `ps -axo pid=,ppid=,args=` -> the pty host (Cursor's "terminal pty-host" helper) under `cursorPID`.
    static func ptyHost(psOutput: String, cursorPID: pid_t) -> pid_t? {
        processRows(psOutput).first { $0.parent == cursorPID && $0.args.contains("terminal pty-host") }?.pid
    }

    /// Every shell the pty host runs: one per terminal, across ALL of Cursor's windows.
    static func shells(psOutput: String, ptyHost: pid_t) -> Set<pid_t> {
        Set(processRows(psOutput).filter { $0.parent == ptyHost }.map(\.pid))
    }

    static func processRows(_ psOutput: String) -> [(pid: pid_t, parent: pid_t, args: String)] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { return nil }
            return (pid, parent, fields.count == 3 ? String(fields[2]) : "")
        }
    }

    /// Lines of `git status --porcelain` plus `git diff --stat` that differ between two snapshots.
    static func changedLines(before: String, after: String) -> [String] {
        let old = before.split(separator: "\n").map(String.init), new = after.split(separator: "\n").map(String.init)
        return new.filter { !old.contains($0) } + old.filter { !new.contains($0) }.map { "gone: " + $0 }
    }

    // MARK: Processes

    /// Runs a tool and returns its stdout (nil when it could not run or failed).
    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// `--no-optional-locks`: a status read must not rewrite the index under the owner.
    static func git(_ arguments: [String]) -> String? {
        run("/usr/bin/git", ["--no-optional-locks"] + arguments, in: repositoryURL)
    }

    /// The repo's state, as the R3 safety check compares it.
    static func gitSnapshot() -> String? {
        guard let status = git(["status", "--porcelain"]), let diff = git(["diff", "--stat"]) else { return nil }
        return status + diff
    }

    static func latestCommitSubject() -> String? {
        git(["log", "-1", "--format=%s", "origin/main"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cursorProcessIdentifier() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundleIdentifier).first?.processIdentifier
    }

    /// Cursor's terminal shells now (nil when they cannot be read).
    static func cursorShells() -> Set<pid_t>? {
        guard let cursor = cursorProcessIdentifier(), let ps = run("/bin/ps", ["-axo", "pid=,ppid=,args="]),
              let host = ptyHost(psOutput: ps, cursorPID: cursor) else { return nil }
        return shells(psOutput: ps, ptyHost: host)
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Ends shells the scenario created, by pid, each only while it is still a child
    /// of the pty host (a recycled pid belongs to someone else). SIGHUP: what closing a terminal sends.
    static func endShells(_ pids: Set<pid_t>) -> [Int] {
        guard let current = cursorShells() else { return [] }
        return pids.intersection(current).sorted().compactMap { kill($0, SIGHUP) == 0 ? Int($0) : nil }
    }

    // MARK: Cursor's window

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func cursorWindows() -> [AXUIElement] {
        guard let pid = cursorProcessIdentifier() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        AccessibilityTreeWalker.requestManualAccessibility(from: application)
        return attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// The window's active editor file.
    static func activeDocument(_ window: AXUIElement) -> URL? {
        (attribute(window, kAXDocumentAttribute) as? String).flatMap(URL.init(string:))
    }

    /// Cursor's window on this repo: its active file is under the repo, or its title ends with the folder name.
    static func repositoryWindow() -> AXUIElement? {
        let folder = repositoryURL.lastPathComponent
        return cursorWindows().first { window in
            if let document = activeDocument(window), document.standardizedFileURL.path.hasPrefix(repositoryURL.standardizedFileURL.path + "/") { return true }
            let title = attribute(window, kAXTitleAttribute) as? String ?? ""
            return title == folder || title.hasSuffix(" — " + folder)
        }
    }

    /// Any buffer in the window is unsaved (nil: unreadable).
    static func hasUnsavedEdits(_ window: AXUIElement) -> Bool? {
        guard let button = attribute(window, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else { return nil }
        return (attribute(button as! AXUIElement, "AXEdited") as? NSNumber)?.boolValue
    }

    static func nodes(_ window: ScenarioWindow) -> [AccessibilityElementNode] { ScenarioRunnerAX.nodes(window) }

    /// Editor tabs (file names) in the window.
    static func editorTabs(_ window: ScenarioWindow) -> [String] {
        nodes(window).filter { $0.subrole == "AXTabButton" && ($0.elementDescription?.raw.contains("Editor Group") ?? false) }
            .compactMap { $0.elementDescription.map { editorTabFileName($0.raw) } }
    }

    /// Text anywhere in the window except inside a text input — a sent chat message, not a draft.
    static func textsOutsideInputs(_ window: ScenarioWindow) -> [String] {
        guard let application = NSRunningApplication(processIdentifier: window.processIdentifier),
              let root = (try? AccessibilityTreeWalker.snapshotWindow(window.element, of: application))?.rootNode else { return [] }
        return root.wireDescendants().compactMap { $0.displayName?.raw }
    }

    /// Opens or finds Cursor's window on this repo. `created`: the run opened it —
    /// only when no such window was visible before and a NEW window-server window
    /// appeared; anything less certain is treated as the owner's and never closed.
    static func repositoryWindowOpeningIfNeeded() -> (window: ScenarioWindow, created: Bool)? {
        guard let pid = cursorProcessIdentifier() else { return nil }
        if let window = repositoryWindow() { return (ScenarioWindow(element: window, processIdentifier: pid, nonce: ""), false) }
        guard let cursorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundleIdentifier) else { return nil }
        let numbersBefore = Set(windowNumbers(of: pid))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([repositoryURL], withApplicationAt: cursorURL, configuration: configuration) { _, _ in }
        var found: AXUIElement?
        HarnessHands.waitUntil(seconds: cursorOpenDeadlineSeconds) {
            found = repositoryWindow()
            return found != nil
        }
        guard let found else { return nil }
        let numbersAfter = Set(windowNumbers(of: pid))
        return (ScenarioWindow(element: found, processIdentifier: pid, nonce: ""), !numbersAfter.subtracting(numbersBefore).isEmpty)
    }

    /// Every window-server window of the process, on any Space: an identity that
    /// `kAXWindows` (active Space only) cannot give.
    static func windowNumbers(of pid: pid_t) -> Set<Int> {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { window in
            window[kCGWindowOwnerPID as String] as? Int32 == pid && window[kCGWindowLayer as String] as? Int == 0
                ? window[kCGWindowNumber as String] as? Int : nil
        })
    }

    /// Tabs, active file and shells once two reads 0.5 s apart agree (≤ 8 s).
    static func settledCursorState(_ window: ScenarioWindow) -> (tabs: [String], active: String?, shells: Set<pid_t>?) {
        func read() -> (tabs: [String], active: String?, shells: Set<pid_t>?) {
            (editorTabs(window), activeDocument(window.element)?.lastPathComponent, cursorShells())
        }
        var last = read()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let now = read()
            if now.tabs == last.tabs, now.active == last.active, now.shells == last.shells { return now }
            last = now
        }
        return last
    }

    /// The window is still listed (same element).
    static func isPresent(_ window: ScenarioWindow) -> Bool { cursorWindows().contains { CFEqual($0, window.element) } }

    /// Closes an editor tab the scenario opened, by the file it names, through its own Close button.
    static func closeEditorTab(named file: String, in window: ScenarioWindow) -> Bool {
        guard let tab = nodes(window).first(where: {
            $0.subrole == "AXTabButton" && $0.elementDescription.map { editorTabFileName($0.raw) } == file
                && ($0.elementDescription?.raw.contains("Editor Group") ?? false)
        }) else { return false }
        guard let close = tab.flattenedDescendants().first(where: { $0.role == "AXButton" && ($0.elementDescription?.raw.hasPrefix("Close") ?? false) }),
              let element = close.accessibilityElement else { return false }
        return AccessibilityActionPerformer.perform(kAXPressAction, on: element).error == .success
    }

    /// Brings back the tab that was active before (a tab the owner already had, now hidden behind the scenario's).
    static func selectEditorTab(named file: String, in window: ScenarioWindow) -> Bool {
        guard let element = nodes(window).first(where: {
            $0.subrole == "AXTabButton" && $0.elementDescription.map { editorTabFileName($0.raw) } == file
        })?.accessibilityElement else { return false }
        return AccessibilityActionPerformer.perform(kAXPressAction, on: element).error == .success
    }

    /// The run's own Cursor window, closed by its own close button — never with unsaved edits
    /// (that would raise a save sheet, and the answer is the owner's).
    static func closeRunWindow(_ window: ScenarioWindow) -> [String: Any] {
        // `kAXWindows` is the active Space only: absent is not gone. Opening the folder
        // again brings its window forward (08-09-43Z said "already gone" and left it open).
        if !isPresent(window), let cursorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundleIdentifier) {
            NSWorkspace.shared.open([repositoryURL], withApplicationAt: cursorURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            HarnessHands.waitUntil(seconds: 5) { isPresent(window) }
        }
        guard isPresent(window) else { return ["closed": false, "error": "not found on the active Space after bringing Cursor forward: left open"] }
        if hasUnsavedEdits(window.element) != false { return ["closed": false, "error": "unsaved edits (or unreadable): left open for the owner"] }
        guard let button = attribute(window.element, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return ["closed": false, "error": "no close button"]
        }
        let press = AccessibilityActionPerformer.perform(kAXPressAction, on: button as! AXUIElement)
        return ["closed": HarnessHands.waitUntil(seconds: 5) { !isPresent(window) }, "axErrorRawValue": Int(press.error.rawValue)]
    }

    // MARK: Chrome

    /// The front tab's first heading, as the owner reads it.
    static func firstHeading(_ window: ScenarioWindow) -> String? {
        for node in nodes(window) where node.role == "AXHeading" {
            if let name = node.displayName?.raw, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
            let text = node.flattenedDescendants().compactMap { $0.role == "AXStaticText" ? $0.value?.raw : nil }.joined()
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        return nil
    }

    // MARK: Timing

    /// agent-loop.log step lines written at or after `since` (system uptime), read from the file's tail.
    static func agentSteps(since: TimeInterval) -> [[String: Any]] {
        let url = MeasurementLogFile.directoryURL.appendingPathComponent(AgentLoop.traceFileName)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["kind"] as? String == "step", let uptime = object["uptime"] as? Double, uptime >= since else { return nil }
            return object
        }
    }

    /// Where a turn's time went: the voice model's thinking before each call, the
    /// harness's acting, and looking; then each agent step's look, model and harness.
    /// `voiceCalls`: (arrived, answered) uptimes in order; `release`: the key-up.
    static func breakdown(release: TimeInterval, voiceCalls: [(name: String, arrived: TimeInterval, answered: TimeInterval?, harnessMs: Int)],
                          freshLookMs: Int?, agentSteps: [[String: Any]]) -> [String: Any] {
        var steps: [[String: Any]] = []
        var previous = release
        var voiceModelMs = 0
        var harnessMs = 0
        for call in voiceCalls.sorted(by: { $0.arrived < $1.arrived }) {
            let thinking = max(0, Int(((call.arrived - previous) * 1000).rounded()))
            voiceModelMs += thinking
            harnessMs += call.harnessMs
            steps.append(["phase": "voice", "tool": call.name, "modelMs": thinking, "harnessMs": call.harnessMs,
                          "atMs": Int(((call.arrived - release) * 1000).rounded())])
            previous = max(previous, call.answered ?? call.arrived)
        }
        var agentModelMs = 0
        var lookMs = freshLookMs ?? 0
        for step in agentSteps {
            let model = step["modelMs"] as? Int ?? 0
            let observe = step["observeMs"] as? Int ?? 0
            let harness = step["harnessMs"] as? Int ?? 0
            agentModelMs += model
            lookMs += observe
            harnessMs += harness
            steps.append(["phase": "agent", "step": step["step"] ?? NSNull(), "tool": step["tool"] ?? NSNull(), "modelMs": model,
                          "observeMs": observe, "harnessMs": harness, "ok": step["ok"] ?? NSNull()])
        }
        return ["steps": steps, "voiceModelMs": voiceModelMs, "agentModelMs": agentModelMs, "modelMs": voiceModelMs + agentModelMs,
                "harnessMs": harnessMs, "lookMs": lookMs,
                // One voice response per call, plus the reply; one Claude call per agent step.
                "modelCalls": ["voice": voiceCalls.count + 1, "agent": agentSteps.count]]
    }

    // MARK: Benchmark

    /// Median (upper middle) and min–max of passed runs' done times, per scenario.
    static func benchmarkMarkdown(results: [[String: Any]], humanEstimates: [String: String], stamp: String) -> String {
        func median(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.sorted()[values.count / 2] }
        func seconds(_ ms: Int?) -> String { ms.map { String(format: "%.1f s", Double($0) / 1000) } ?? "—" }
        let ids = results.compactMap { $0["id"] as? String }.filter { $0.hasPrefix("R") }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var lines = ["# Real-app benchmark \(stamp)", "",
                     "Done = key release to the checker first seeing the goal state (R5, R7: and the spoken answer delivered). "
                         + "Median and spread over PASSED runs; a failed run has no done time worth comparing.", "",
                     "| id | passed | done median | spread | steps (median) | model calls (voice+agent) | model ms | harness ms | look ms | HeyClicky (owner-timed) | human estimate |",
                     "|---|---|---|---|---|---|---|---|---|---|---|"]
        for id in ids {
            // Skipped, and turns whose task model was unreachable, measured nothing about J.A.R.V.I.S.
            let runs = results.filter { $0["id"] as? String == id && !["skipped", "loopModelUnavailable"].contains($0["status"] as? String ?? "") }
            let passed = runs.filter { $0["status"] as? String == "passed" }
            let done = passed.compactMap { $0["doneMs"] as? Int }
            func breakdownMedian(_ key: String) -> Int? { median(passed.compactMap { ($0["breakdown"] as? [String: Any])?[key] as? Int }) }
            let calls = passed.compactMap { ($0["breakdown"] as? [String: Any])?["modelCalls"] as? [String: Int] }
            let callCell = calls.isEmpty ? "—" : "\(median(calls.compactMap { $0["voice"] }) ?? 0)+\(median(calls.compactMap { $0["agent"] }) ?? 0)"
            let spread = done.isEmpty ? "—" : "\(seconds(done.min()))–\(seconds(done.max()))"
            lines.append("| \(id) | \(passed.count)/\(runs.count) | \(seconds(median(done))) | \(spread) | \(median(passed.compactMap { $0["steps"] as? Int }).map(String.init) ?? "—") | "
                + "\(callCell) | \(breakdownMedian("modelMs").map(String.init) ?? "—") | \(breakdownMedian("harnessMs").map(String.init) ?? "—") | "
                + "\(breakdownMedian("lookMs").map(String.init) ?? "—") |  | \(humanEstimates[id] ?? "10–60 s") |")
        }
        let failures = results.filter { ($0["id"] as? String)?.hasPrefix("R") == true && $0["status"] as? String != "passed" }
        if !failures.isEmpty {
            lines += ["", "## Not passed", ""]
            for failure in failures {
                let why = [(failure["check"] as? [String: Any])?["why"] as? String, failure["reason"] as? String].compactMap { $0 }.joined(separator: "; ")
                lines.append("- \(failure["id"] ?? "?") \(failure["status"] ?? "?"): \(why.isEmpty ? "see results.json" : why)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
