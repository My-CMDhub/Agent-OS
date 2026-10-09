//
//  TaskStatusScenarioTests.swift
//  leanring-buddyTests
//
//  S1/S2 (2026-10-10): a status question mid-task, through the runner's voice
//  path. Their checker passes only when the task kept running and the question
//  turn itself answered. Whether the answer matches the task's real state is
//  the live run's call: agent-loop.log's statusSent line beside the reply.
//

import Foundation
import Testing
@testable import Clicky

@MainActor struct TaskStatusScenarioTests {

    @Test func s1AndS2AskMidTaskAndHaveUtterances() throws {
        let text = try String(contentsOf: ScenarioRunner.scenarioDirectory.appendingPathComponent("utterances.tsv"), encoding: .utf8)
        let utterances = ScenarioRunner.parseUtterances(text)
        #expect(ScenarioCatalog.taskStatus.map(\.id) == ["S1", "S2"])
        for scenario in ScenarioCatalog.taskStatus {
            #expect(scenario.requiresAgentLoop)
            #expect(scenario.prelude?.utterance == "B2")
            #expect(utterances[scenario.fixtureID] != nil)
        }
    }

    // Live S1 2026-10-10: the prelude started the task, so the question turn had no do_task and the
    // runner never waited for the report; the checker read "ended unreported" over a correct answer.
    @Test func aTaskStartedByThePreludeIsFollowedToItsEnd() {
        #expect(ScenarioRunner.followsTask(turnStartedOne: false, hasPrelude: true, taskRunningOrReported: true))
        #expect(ScenarioRunner.followsTask(turnStartedOne: true, hasPrelude: false, taskRunningOrReported: false))
        #expect(!ScenarioRunner.followsTask(turnStartedOne: false, hasPrelude: false, taskRunningOrReported: true))
        #expect(!ScenarioRunner.followsTask(turnStartedOne: false, hasPrelude: true, taskRunningOrReported: false))
    }

    @Test func theCheckWantsTheTaskStillRunningAndAnAnswerOfItsOwn() async throws {
        let s1 = try #require(ScenarioCatalog.taskStatus.first { $0.id == "S1" })
        func passed(_ reply: String, _ ended: AgentLoop.Outcome, spoken: String = "The cheapest plan is Starter.") async -> Bool {
            var outcome = ScenarioOutcome()
            let marks = RealtimeTurnMarks()
            marks.transcript = reply + " " + spoken
            outcome.marks = marks
            outcome.agentReport = AgentLoopReport(outcome: ended, steps: 4, decisions: [], spoken: spoken)
            return await s1.check(ScenarioContext(harnessAnswer: { _ in "{}" }), outcome)["passed"] as? Bool == true
        }
        #expect(await passed("I'm on step two, sir, opening the plans page.", .done(summary: "s")))
        #expect(!(await passed("I'm on step two, sir.", .cancelled)))
        // The task's own later speech is not the question's answer.
        #expect(!(await passed("", .done(summary: "s"), spoken: "Step 4: the cheapest plan is Starter.")))
    }
}
