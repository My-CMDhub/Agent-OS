//
//  AgentLoopProbe.swift
//  leanring-buddy
//
//  `--agent-loop-probe [--agent-scenarios=B1,B5,B6]`: the agent loop driven
//  directly, no voice, on the scenario runner's own B scenarios (start page,
//  goal words from scripts/scenarios/utterances.tsv (also the "heard" words the
//  guards judge by, as the owner would say them), checker and Never rules —
//  `ScenarioCatalog.multiStep`). Each runs in a Chrome window the probe opens
//  (nonce in its title) and closes by its own close button; the owner's Chrome
//  windows are checked by window-server number after each. Cards: a pending
//  ticket's card is photographed (Clicky's own card window only, by window id),
//  its step footer recorded, then denied — never allowed. Same start gate as the
//  runner (120 s owner idle, no --harness-dry-run). Report, 0600, scrubbed:
//  ~/Library/Logs/Clicky/agent-loop-probe/<timestamp>/results.json; the steps
//  are in agent-loop.log under each run id.
//

import AppKit
import Foundation

@MainActor
enum AgentLoopProbe {
    static let defaultScenarios = ["B1", "B5", "B6"]
    static let denyAfterSeconds = 3.0

    static func run(harness: HarnessServer, confirmations: HarnessConfirmations) async {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = MeasurementLogFile.directoryURL.appendingPathComponent("agent-loop-probe/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var meta: [String: Any] = ["timestamp": stamp, "provider": AgentModelProvider.configured.rawValue,
                                   "preferredModel": AgentModelProvider.configured == .gemini ? AgentLoopGemini.firstModel() : AgentLoopModel.preferred]
        var results: [[String: Any]] = []
        defer {
            if let line = MeasurementLogFile.jsonLine(["run": meta, "scenarios": results]) {
                MeasurementLogFile.appendOwnerOnly(Data((line + "\n").utf8), to: directory.appendingPathComponent("results.json"))
            }
            MeasurementLogFile.waitForPendingWrites()
            print("🤖 agent-loop probe: \(meta["outcome"] ?? "?") -> \(directory.path)")
        }
        if let refusal = ScenarioRunner.refusalToStart() {
            meta["outcome"] = "refused"
            meta["reason"] = refusal
            return
        }
        if let words = CommandLine.arguments.last(where: { $0.hasPrefix(goalArgument) }).map({ String($0.dropFirst(goalArgument.count)) }),
           !words.isEmpty {
            results = [await goalRun(words: words, harness: harness, confirmations: confirmations)]
            meta["outcome"] = "ran"
            return
        }
        if CommandLine.arguments.contains("--agent-speed") {
            results = await speedRuns(harness: harness, confirmations: confirmations)
            meta["outcome"] = results.contains { $0["status"] as? String == "aborted" } ? "aborted" : "ran"
            return
        }
        let ids = CommandLine.arguments.first { $0.hasPrefix("--agent-scenarios=") }
            .map { $0.dropFirst("--agent-scenarios=".count).split(separator: ",").map(String.init) } ?? defaultScenarios
        let utterances = ScenarioRunner.loadUtterances()
        let harnessAnswer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        let model = AgentLoopModel()
        let runStart = ProcessInfo.processInfo.systemUptime
        let chromeRunningAtStart = !NSRunningApplication.runningApplications(withBundleIdentifier: ScenarioRunner.chromeBundleIdentifier).isEmpty

        for id in ids {
            guard let scenario = ScenarioCatalog.multiStep.first(where: { $0.id == id }), let goal = utterances[scenario.fixtureID]?.words,
                  case .pages(let names, let query) = scenario.start else {
                results.append(["id": id, "status": "skipped", "reason": "not a page-started B scenario with words"])
                continue
            }
            // The owner came back: input newer than anything this run posted.
            let idle = ScenarioRunner.secondsSinceLastInput()
            let ours = min(HarnessHands.ownInput.secondsSinceLastPost ?? .infinity, ProcessInfo.processInfo.systemUptime - runStart)
            if idle + 1 < ours {
                meta["outcome"] = "ownerReturned"
                break
            }
            var result: [String: Any] = ["id": id]
            let chromeBefore = Set(VoiceToolProbe.windowServerWindowNumbers(bundleIdentifier: ScenarioRunner.chromeBundleIdentifier) ?? [])
            let context = ScenarioContext(harnessAnswer: harnessAnswer)
            let nonce = String(UUID().uuidString.prefix(8))
            let urls = names.compactMap { ScenarioRunner.pageURL($0, nonce: nonce, query: query) }
            guard let window = await Task.detached(operation: { ScenarioRunnerAX.openChromeWindow(urls: urls, nonce: nonce) }).value else {
                result["status"] = "startFailed"
                // A window that opens late is still ours: closed by its nonce, never left as an "owner" window.
                result["lateWindow"] = await Task.detached { ScenarioRunnerAX.sweepLateRunnerWindows(nonce: nonce) }.value
                results.append(result)
                continue
            }
            context.window = window
            _ = await ScenarioRunner.waitFor(seconds: 5) { await Task.detached { ScenarioRunnerAX.isInFront(window) ? true : nil }.value }
            await scenario.baseline?(context)

            let started = Date()
            let startUptime = ProcessInfo.processInfo.systemUptime
            var narrations: [String] = []
            // `--agent-start-bundle=<id>`: as if the owner had asked from that app, so a page the task
            // opens is its own only by its tab (re-review of 2e45939).
            let startBundle = CommandLine.arguments.first { $0.hasPrefix("--agent-start-bundle=") }.map { String($0.dropFirst("--agent-start-bundle=".count)) }
            let loop = AgentLoop.live(heard: goal, startBundle: startBundle, harnessAnswer: harnessAnswer, model: model) { line in narrations.append(line) }
            let finished = FinishedFlag()
            let runTask = Task { @MainActor in
                let outcome = await loop.run(goal: goal, heard: goal)
                finished.value = true
                return outcome
            }
            // Watch the cards while it runs: photograph, record the footer, deny.
            var cards: [[String: Any]] = []
            var seen = Set<String>()
            while !finished.value {
                for ticket in confirmations.tickets where ticket.createdAt >= started && !seen.contains(ticket.id)
                    && HarnessConfirmations.status(of: ticket, now: Date()) == .pending
                    && Date().timeIntervalSince(ticket.createdAt) >= denyAfterSeconds {
                    seen.insert(ticket.id)
                    let step = ConfirmationCardWindowManager.current?.step
                    let shot = photographCard(to: directory.appendingPathComponent("\(id)-card-\(cards.count + 1).png"))
                    confirmations.answer(ticket.id, allow: false, scope: .once)
                    cards.append(["verb": ticket.verb, "destructive": ticket.isDestructive, "appName": ticket.appName ?? NSNull(),
                                  "stepFooter": step.map { "Doing \u{00B7} step \($0.current)/\($0.total)" } ?? NSNull(),
                                  "cardWindow": shot ?? NSNull(), "answered": "denied"])
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let outcome = await runTask.value
            let wallMs = Int(((ProcessInfo.processInfo.systemUptime - startUptime) * 1000).rounded())
            let spoken: String
            switch outcome {
            case .done(let summary): spoken = summary
            case .askOwner(let question): spoken = question
            default: spoken = AgentLoop.finalLine(outcome, goal: goal, lastProgress: loop.lastProgress, step: loop.step) ?? ""
            }
            try? await Task.sleep(for: .seconds(ScenarioRunner.settleSeconds))
            // The runner's own checker and Never rules, on what the loop did and would say.
            var scenarioOutcome = ScenarioOutcome()
            let marks = RealtimeTurnMarks()
            marks.transcript = spoken
            marks.decisions = loop.decisions
            scenarioOutcome.marks = marks
            scenarioOutcome.tickets = confirmations.tickets.filter { $0.createdAt >= started }
            let check = await scenario.check(context, scenarioOutcome)
            var nevers: [[String: Any]] = []
            for rule in scenario.never { nevers.append(["name": rule.name, "violated": await rule.violated(context, scenarioOutcome)]) }
            let violated = nevers.contains { $0["violated"] as? Bool == true }
            result["status"] = violated ? "failed" : check["passed"] as? Bool == true ? "passed" : "failed"
            result["check"] = check
            result["never"] = nevers
            result["outcome"] = outcome.name
            result["steps"] = loop.step
            result["wallMs"] = wallMs
            result["model"] = loop.modelUsed ?? NSNull()
            result["run"] = loop.runID
            result["tools"] = loop.receipts.map { ["step": $0.step, "tool": $0.toolName, "ok": $0.ok, "error": $0.error ?? NSNull()] as [String: Any] }
            result["cards"] = cards
            result["narrations"] = narrations.count
            result["summaryLength"] = spoken.count
            // Undo, by identity: our window only.
            result["cleanup"] = await Task.detached { ScenarioRunnerAX.close(window) }.value
            try? await Task.sleep(for: .seconds(1))
            let chromeAfter = Set(VoiceToolProbe.windowServerWindowNumbers(bundleIdentifier: ScenarioRunner.chromeBundleIdentifier) ?? [])
            let missing = chromeBefore.subtracting(chromeAfter)
            result["ownerChromeWindowsIntact"] = missing.isEmpty
            results.append(result)
            print("🤖 agent-loop probe \(id): \(result["status"] ?? "?") \(outcome.name) steps=\(loop.step) \(wallMs) ms")
            if !missing.isEmpty {
                meta["outcome"] = "aborted"
                meta["reason"] = "\(missing.count) owner Chrome window(s) gone after \(id)"
                break
            }
        }
        if meta["outcome"] == nil { meta["outcome"] = "ran" }
        if !chromeRunningAtStart {
            NSRunningApplication.runningApplications(withBundleIdentifier: ScenarioRunner.chromeBundleIdentifier).forEach { $0.terminate() }
        }
    }

    @MainActor private final class FinishedFlag { var value = false }

    /// `--agent-loop-probe --agent-speed` (2026-10-05): read-only goals, each run
    /// twice — web tools on (connector), and off (the screen only) — in a Chrome
    /// window the probe opens on a local page and closes by identity. Any card
    /// is denied. Per run: outcome, the spoken answer, steps, wall ms, model ms
    /// (summed from agent-loop.log for the run id), the tools that ran.
    static func speedRuns(harness: HarnessServer, confirmations: HarnessConfirmations) async -> [[String: Any]] {
        let goals = [("commit", "Tell me the latest commit message on github.com/My-CMDhub/Agent-OS"),
                     ("superloop", "What's the cheapest Superloop NBN plan?")]
        let harnessAnswer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        let model = AgentLoopModel()
        let runStart = ProcessInfo.processInfo.systemUptime
        var results: [[String: Any]] = []
        for (id, goal) in goals {
            for connector in [true, false] {
                let idle = ScenarioRunner.secondsSinceLastInput()
                let ours = min(HarnessHands.ownInput.secondsSinceLastPost ?? .infinity, ProcessInfo.processInfo.systemUptime - runStart)
                if idle + 1 < ours { results.append(["id": id, "status": "aborted", "reason": "ownerReturned"]); return results }
                var result: [String: Any] = ["id": id, "mode": connector ? "connector" : "screen"]
                let chromeBefore = Set(VoiceToolProbe.windowServerWindowNumbers(bundleIdentifier: ScenarioRunner.chromeBundleIdentifier) ?? [])
                let nonce = String(UUID().uuidString.prefix(8))
                guard let url = ScenarioRunner.pageURL("article.html", nonce: nonce) else {
                    results.append(result.merging(["status": "startFailed"]) { _, new in new })
                    continue
                }
                guard let window = await Task.detached(operation: { ScenarioRunnerAX.openChromeWindow(urls: [url], nonce: nonce) }).value else {
                    // 09-09-44Z's commit/screen: this window opened late and stayed open all evening (window 1982).
                    let late = await Task.detached { ScenarioRunnerAX.sweepLateRunnerWindows(nonce: nonce) }.value
                    results.append(result.merging(["status": "startFailed", "lateWindow": late]) { _, new in new })
                    continue
                }
                _ = await ScenarioRunner.waitFor(seconds: 5) { await Task.detached { ScenarioRunnerAX.isInFront(window) ? true : nil }.value }
                let started = Date()
                let startUptime = ProcessInfo.processInfo.systemUptime
                let loop = AgentLoop.live(heard: goal, harnessAnswer: harnessAnswer, model: model) { _ in }
                loop.webToolsEnabled = connector
                let finished = FinishedFlag()
                let runTask = Task { @MainActor in
                    let outcome = await loop.run(goal: goal, heard: goal)
                    finished.value = true
                    return outcome
                }
                var denied = 0
                while !finished.value {
                    for ticket in confirmations.tickets where ticket.createdAt >= started
                        && HarnessConfirmations.status(of: ticket, now: Date()) == .pending {
                        confirmations.answer(ticket.id, allow: false, scope: .once)
                        denied += 1
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                let outcome = await runTask.value
                result["wallMs"] = Int(((ProcessInfo.processInfo.systemUptime - startUptime) * 1000).rounded())
                if case .done(let summary) = outcome { result["answer"] = SecretScanner.redact(summary) }
                result["outcome"] = outcome.name
                result["steps"] = loop.step
                result["run"] = loop.runID
                result["model"] = loop.modelUsed ?? NSNull()
                result["cardsDenied"] = denied
                result["tools"] = loop.receipts.map { ["step": $0.step, "tool": $0.toolName, "ok": $0.ok, "error": $0.error ?? NSNull()] as [String: Any] }
                MeasurementLogFile.waitForPendingWrites()
                result["modelMs"] = modelMilliseconds(run: loop.runID)
                result["cleanup"] = await Task.detached { ScenarioRunnerAX.close(window) }.value
                try? await Task.sleep(for: .seconds(1))
                let chromeAfter = Set(VoiceToolProbe.windowServerWindowNumbers(bundleIdentifier: ScenarioRunner.chromeBundleIdentifier) ?? [])
                let missing = chromeBefore.subtracting(chromeAfter)
                result["ownerChromeWindowsIntact"] = missing.isEmpty
                result["status"] = missing.isEmpty ? "ran" : "aborted"
                results.append(result)
                print("🤖 agent speed \(id) \(result["mode"] ?? "?"): \(outcome.name) steps=\(loop.step) \(result["wallMs"] ?? "?") ms")
                if !missing.isEmpty { return results }
            }
        }
        return results
    }

    static let goalArgument = "--agent-goal="

    /// `--agent-loop-probe --agent-goal=<the owner's words> [--agent-start-bundle=<id>]`
    /// (2026-10-05): one task as the owner would say it, in the apps as they are
    /// — the owner's own logged-in Chrome — with no page of the probe's. The
    /// task's pages open in tabs it opens; afterwards exactly those tabs are
    /// closed by identity (the tab's own close button), never another. Cards are
    /// denied and counted: a read-only task should raise none. Per run: outcome,
    /// the spoken answer, every call (tool, target, outcome, ms), the
    /// readOnlyTask refusals, model calls and model ms, wall ms, tabs closed.
    static func goalRun(words: String, harness: HarnessServer, confirmations: HarnessConfirmations) async -> [String: Any] {
        let harnessAnswer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        let startBundle = CommandLine.arguments.first { $0.hasPrefix("--agent-start-bundle=") }.map { String($0.dropFirst("--agent-start-bundle=".count)) }
        let started = Date()
        let startUptime = ProcessInfo.processInfo.systemUptime
        var narrations = 0
        let loop = AgentLoop.live(heard: words, startBundle: startBundle, harnessAnswer: harnessAnswer, model: AgentLoopModel()) { _ in narrations += 1 }
        let finished = FinishedFlag()
        let runTask = Task { @MainActor in
            let outcome = await loop.run(goal: words, heard: words)
            finished.value = true
            return outcome
        }
        var cards: [[String: Any]] = []
        var seen = Set<String>()
        while !finished.value {
            for ticket in confirmations.tickets where ticket.createdAt >= started && !seen.contains(ticket.id)
                && HarnessConfirmations.status(of: ticket, now: Date()) == .pending {
                seen.insert(ticket.id)
                confirmations.answer(ticket.id, allow: false, scope: .once)
                cards.append(["verb": ticket.verb, "destructive": ticket.isDestructive, "answered": "denied"])
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let outcome = await runTask.value
        var result: [String: Any] = ["mode": "goal", "readOnly": loop.readOnly, "outcome": outcome.name, "steps": loop.step,
                                     "wallMs": Int(((ProcessInfo.processInfo.systemUptime - startUptime) * 1000).rounded()),
                                     "model": loop.modelUsed ?? NSNull(), "run": loop.runID, "cards": cards, "narrations": narrations]
        switch outcome {
        case .done(let summary): result["spoken"] = SecretScanner.redact(summary)
        case .askOwner(let question): result["spoken"] = SecretScanner.redact(question)
        default: result["spoken"] = AgentLoop.finalLine(outcome, goal: words, lastProgress: loop.lastProgress, step: loop.step) ?? NSNull()
        }
        // Every call the task made, with what it aimed at and how it ended.
        let calls: [[String: Any]] = loop.decisions.map(callReport)
        result["calls"] = calls
        result["readOnlyRefusals"] = calls.filter { $0["error"] as? String == "readOnlyTask" }
        result["tools"] = loop.receipts.map { ["step": $0.step, "tool": $0.toolName, "ok": $0.ok, "error": $0.error ?? NSNull()] as [String: Any] }
        MeasurementLogFile.waitForPendingWrites()
        result["modelMs"] = modelMilliseconds(run: loop.runID)
        try? await Task.sleep(for: .seconds(ScenarioRunner.settleSeconds))
        // Undo by identity: only the tabs this task opened.
        let tabs = (loop.liveCarry?.taskTabs ?? [:]).flatMap { bundle, keys in keys.map { (bundle, $0) } }
        var closed: [[String: Any]] = []
        for (bundle, key) in tabs {
            closed.append(await Task.detached { closeTab(key) }.value.merging(["app": bundle]) { current, _ in current })
        }
        result["tabsClosed"] = closed
        print("🤖 agent goal: \(outcome.name) steps=\(loop.step) \(result["wallMs"] ?? "?") ms, \(calls.count) calls, "
              + "\((result["readOnlyRefusals"] as? [Any])?.count ?? 0) readOnlyTask, \(cards.count) cards")
        return result
    }

    /// One call of a goal run: tool, what it aimed at (the judged name of a
    /// refusal, the pressed element, the page's host…), typed text, outcome.
    static func callReport(_ decision: RealtimeToolDecision) -> [String: Any] {
        let call = decision.call
        let dispatch = decision.dispatch
        var target: String? = dispatch?.harnessResponse?["target"] as? String
        target = target ?? (dispatch?.result["target"] as? String) ?? call.elementName
        target = target ?? call.url.flatMap { URL(string: $0)?.host }
        target = target ?? call.path?.joined(separator: " > ")
        target = target ?? (call.x != nil ? "position" : call.direction)
        var line: [String: Any] = ["tool": call.name, "ok": dispatch?.result["ok"] as? Bool ?? false]
        line["target"] = target.map { String($0.prefix(80)) } ?? NSNull()
        line["text"] = call.text.map { String($0.prefix(60)) } ?? NSNull()
        line["error"] = dispatch?.result["error"] ?? NSNull()
        line["harnessMs"] = dispatch?.harnessMilliseconds ?? 0
        line["waitedForConfirmation"] = dispatch?.waitedForConfirmation ?? false
        return line
    }

    /// A browser tab the task opened, closed by its own close button, only
    /// while that same element (CFEqual) still answers. Never a keystroke.
    nonisolated static func closeTab(_ key: AccessibilityElementKey) -> [String: Any] {
        let tab = key.element
        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? String : nil
        }
        guard let role = string(tab, kAXRoleAttribute) else { return ["closed": false, "why": "the tab no longer answers"] }
        let title = string(tab, kAXTitleAttribute) ?? ""
        var children: AnyObject?
        AXUIElementCopyAttributeValue(tab, kAXChildrenAttribute as CFString, &children)
        guard let button = ((children as? [AXUIElement]) ?? []).first(where: { child in
            string(child, kAXRoleAttribute) == "AXButton"
                && [string(child, kAXDescriptionAttribute), string(child, kAXTitleAttribute)].compactMap { $0?.lowercased() }.contains { $0.contains("close") }
        }) else { return ["closed": false, "why": "no close button on the tab", "role": role] }
        let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
        // 2026-10-05: one closed tab still answered at 0.8 s and was gone afterwards; wait up to 3 s.
        for _ in 0..<15 where string(tab, kAXRoleAttribute) != nil { Thread.sleep(forTimeInterval: 0.2) }
        return ["closed": string(tab, kAXRoleAttribute) == nil, "pressError": error.rawValue, "titleHadLinkedIn": title.lowercased().contains("linkedin")]
    }

    /// The model ms of one run, summed from its agent-loop.log step lines.
    static func modelMilliseconds(run: String) -> Int {
        let url = MeasurementLogFile.directoryURL.appendingPathComponent(AgentLoop.traceFileName)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["run"] as? String == run && $0["kind"] as? String == "step" }
            .compactMap { $0["modelMs"] as? Int }.reduce(0, +)
    }

    /// Clicky's own largest on-screen window (the card, while a ticket is
    /// pending), by window id: nothing of any other app is in the picture.
    static func photographCard(to url: URL) -> [String: Any]? {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ours = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        func area(_ window: [String: Any]) -> CGFloat {
            (window[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }.map { $0.width * $0.height } ?? 0
        }
        guard let card = ours.max(by: { area($0) < area($1) }), let number = card[kCGWindowNumber as String] as? Int else { return nil }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(number)", url.path]
        try? capture.run()
        capture.waitUntilExit()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ["windowNumber": number, "ourOnScreenWindows": ours.count, "image": url.lastPathComponent,
                "written": FileManager.default.fileExists(atPath: url.path)]
    }
}
