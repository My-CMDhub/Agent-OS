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
        var meta: [String: Any] = ["timestamp": stamp, "preferredModel": AgentLoopModel.preferred]
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
