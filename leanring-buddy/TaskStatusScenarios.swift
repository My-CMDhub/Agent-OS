//
//  TaskStatusScenarios.swift
//  leanring-buddy
//
//  Mid-task status questions (2026-10-10), through the runner's voice-fixture
//  path and the real session: B2's task starts, and 6 s later the owner asks
//  about it. The task must keep running (a key press and a question no longer
//  stop it) and the reply must come from the task status line, which
//  agent-loop.log records as `statusSent` with the phase and step it carried.
//  Run: `--scenario-runner --scenario-ids=S1,S2`.
//

import Foundation

extension ScenarioCatalog {
    static let taskStatus: [RunnerScenario] = [
        RunnerScenario(id: "S1", start: .pages(["shop.html"]), requiresAgentLoop: true, prelude: ("B2", 6),
                       check: { _, outcome in statusVerdict(outcome, mustSay: ["step"]) }),
        RunnerScenario(id: "S2", start: .pages(["shop.html"]), requiresAgentLoop: true, prelude: ("B2", 6),
                       check: { _, outcome in statusVerdict(outcome, mustSay: []) }),
    ]

    /// The question turn's own reply (the task's later speech removed), and the task still running after it.
    static func statusVerdict(_ outcome: ScenarioOutcome, mustSay words: [String]) -> [String: Any] {
        let spoken = outcome.agentReport?.spoken ?? ""
        let reply = outcome.transcript.replacingOccurrences(of: spoken, with: "").trimmingCharacters(in: .whitespaces)
        let ended = outcome.agentReport?.outcome.name
        let keptRunning = ended != nil && ended != "cancelled"
        let answered = !reply.isEmpty && (words.isEmpty || words.contains { reply.lowercased().contains($0) })
        return verdict(keptRunning && answered, keptRunning ? "no status answer" : "the task ended \(ended ?? "unreported")",
                       ["reply": reply, "agentOutcome": ended ?? NSNull(), "agentSteps": outcome.agentReport?.steps ?? NSNull()])
    }
}
