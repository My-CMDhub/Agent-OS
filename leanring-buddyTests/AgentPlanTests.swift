//
//  AgentPlanTests.swift
//  leanring-buddyTests
//
//  The `plan` tool (design 2026-10-07 §B): its shape and live prechecks
//  refuse a whole plan before anything acts; a plan runs its steps with one
//  model call and answers with one tool_result; it stops at a failure,
//  `notObserved`, or a read; and a plain batch now stops at `notObserved`
//  too (it carried on past it before). Whether Gemini actually plans is the
//  live generality run's.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
private final class PlanScript {
    var replies: [[String: Any]]
    var bodies: [[String: Any]] = []
    var executed: [RealtimeToolCall] = []
    var reads = 0
    var now: TimeInterval = 1000
    init(_ replies: [[String: Any]]) { self.replies = replies }
}

private func reply(_ calls: [(String, [String: Any])]) -> [String: Any] {
    ["stop_reason": "tool_use", "content": calls.map { ["type": "tool_use", "id": "id-\($0.0)-\(UUID().uuidString.prefix(4))", "name": $0.0, "input": $0.1] as [String: Any] }]
}

private func planReply(_ steps: [[String: Any]], id: String = "plan-1") -> [String: Any] {
    ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": id, "name": "plan", "input": ["steps": steps]] as [String: Any]]]
}

@MainActor
private func planLoop(_ script: PlanScript, precheck: (([[String: Any]]) async -> String?)? = nil,
                      execute: ((RealtimeToolCall) -> RealtimeToolDispatch)? = nil) -> AgentLoop {
    var dependencies = AgentLoop.Dependencies(
        model: { body, _ in
            script.bodies.append(body)
            script.now += 1
            let next = script.replies.count > 1 ? script.replies.removeFirst() : script.replies[0]
            return AgentModelReply(json: next, model: "fake", milliseconds: 7)
        },
        observe: { AgentObservation(jpeg: nil, frame: nil, look: "noAppInFront", lines: [], bundleIdentifier: "com.apple.finder") },
        execute: { call, _, _, _ in
            script.executed.append(call)
            return execute?(call) ?? RealtimeToolDispatch(result: ["ok": true, "error": NSNull(), "verification": "observed"], harnessMilliseconds: 5,
                                                         waitedForConfirmation: false, harnessResponse: ["ok": true])
        },
        readPage: { script.reads += 1; return ["ok": true, "text": "page"] },
        trace: { _ in },
        uptime: { script.now },
        frontBundle: { "com.apple.finder" })
    if let precheck { dependencies.planPrecheck = precheck }
    return AgentLoop(dependencies: dependencies)
}

/// The tool_result blocks the second model call carried.
@MainActor
private func results(_ script: PlanScript) -> [[String: Any]] {
    let messages = script.bodies[1]["messages"] as? [[String: Any]] ?? []
    return (messages.last?["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_result" }
}

private func json(_ block: [String: Any]) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(((block["content"] as? String) ?? "").utf8)) as? [String: Any]) ?? [:]
}

private let finderMenus: [String: Any] = ["ok": true, "items": [
    ["path": ["File", "New Folder"], "enabled": true, "shortcut": "⇧⌘N", "hasSubmenu": false],
    ["path": ["File", "Get Info"], "enabled": false, "shortcut": "⌘I", "hasSubmenu": false],
    ["path": ["View", "as List"], "enabled": true, "shortcut": "⌘2", "hasSubmenu": false],
    ["path": ["Go", "Downloads"], "enabled": true, "shortcut": "⌥⌘L", "hasSubmenu": false]
]]

struct AgentPlanTests {

    @Test func theShapeIsCheckedBeforeAnythingRuns() {
        #expect(AgentPlan.precheck(nil) != nil)
        #expect(AgentPlan.precheck([]) != nil)
        #expect(AgentPlan.precheck(Array(repeating: ["tool": "read_page"], count: 7))?.contains("at most 6") == true)
        #expect(AgentPlan.precheck([["tool": "rm_rf"]])?.contains("no tool named") == true)
        #expect(AgentPlan.precheck([["tool": "do_task", "goal": "x"]]) != nil)
        #expect(AgentPlan.precheck([["tool": "ask_owner", "question": "which?"]])?.contains("own reply") == true)
        #expect(AgentPlan.precheck([["tool": "done", "summary": "x"], ["tool": "read_page"]])?.contains("last step") == true)
        #expect(AgentPlan.precheck([["tool": "press_menu", "app": "Finder"]])?.contains("path or shortcut") == true)
        #expect(AgentPlan.precheck([["tool": "press_menu", "path": ["View", "as List"]], ["tool": "press_element", "x": 0.5, "y": 0.5]])?
            .contains("position") == true, "a position only in step 1")
        #expect(AgentPlan.precheck([["tool": "press_element", "x": 0.5, "y": 0.5],
                                    ["tool": "press_menu", "shortcut": "⌘2"],
                                    ["tool": "done", "summary": "Switched to list view.", "evidence": [1]]]) == nil)
    }

    @Test func menuStepsMustBeMappedOrFoundAndReadOnlyAllowed() throws {
        let map = try #require(AffordanceMap(menusResponse: finderMenus, bundleIdentifier: "com.apple.finder", version: "1", pid: 1, builtUptime: 0))
        func check(_ steps: [[String: Any]], readOnly: Bool = false, find: RealtimeStandingOffer? = nil) -> String? {
            AgentPlan.livePrecheck(steps, map: map, findOffer: find, readOnly: readOnly, screenElements: nil)
        }
        #expect(check([["tool": "press_menu", "path": ["View", "as List"]], ["tool": "press_menu", "shortcut": "⌥⌘L"]]) == nil)
        #expect(check([["tool": "press_menu", "path": ["View", "as Gallery"]]])?.contains("not in the App verbs") == true)
        let found = RealtimeStandingOffer(candidates: [RealtimeMenuCandidate(path: ["View", "as Gallery"], shortcut: nil)],
                                          app: "com.apple.finder", uptime: 0)
        #expect(check([["tool": "press_menu", "path": ["View", "as Gallery"]]], find: found) == nil, "a find of this task offers it too")
        #expect(check([["tool": "press_menu", "shortcut": "⌘9"]]) != nil)
        #expect(check([["tool": "press_menu", "path": ["File", "New Folder"]]], readOnly: true)?.contains("read-only") == true)
        #expect(check([["tool": "press_menu", "path": ["File", "Get Info"]]]) == nil,
                "a cached enabled flag goes stale: the kernel refuses a disabled item live, the precheck does not guess")
    }

    @Test func aStepAimedByNameBeforeActingMustNotBeAmbiguousOrSecure() {
        let elements: [[String: Any]] = [
            ["role": "AXButton", "name": "Recent", "nameSource": "title"],
            ["role": "AXStaticText", "name": "Recent", "nameSource": "value"],
            ["role": "AXSecureTextField", "name": "Password", "nameSource": "placeholder"],
            ["role": "AXButton", "name": "Back", "nameSource": "description"]
        ]
        func check(_ steps: [[String: Any]]) -> String? {
            AgentPlan.livePrecheck(steps, map: nil, findOffer: nil, readOnly: false, screenElements: elements)
        }
        #expect(check([["tool": "press_element", "name": "Back"]]) == nil)
        #expect(check([["tool": "press_element", "name": "Recent"]])?.contains("2 things") == true)
        #expect(check([["tool": "type_text", "name": "Password", "text": "x"]])?.contains("secure") == true)
        #expect(check([["tool": "press_element", "name": "Not here"]]) == nil, "no match: the resolver still has OCR and vision")
        #expect(check([["tool": "press_element", "name": "Back"], ["tool": "press_element", "name": "Recent"]]) == nil,
                "after an acting step the screen may differ: not judged now")
    }

    @MainActor @Test func aPlanRunsItsStepsWithOneModelCallAndOneResult() async {
        let script = PlanScript([planReply([["tool": "press_menu", "app": "Finder", "path": ["View", "as List"]],
                                            ["tool": "press_menu", "app": "Finder", "shortcut": "⌥⌘L"]]),
                                 reply([("done", ["summary": "Switched to list view and opened Downloads.", "evidence": [1]])])])
        let outcome = await planLoop(script).run(goal: "show downloads as a list")
        #expect(outcome == .done(summary: "Switched to list view and opened Downloads."))
        #expect(script.executed.map(\.name) == ["press_menu", "press_menu"])
        #expect(script.executed[1].shortcut == "⌥⌘L")
        #expect(script.bodies.count == 2)
        let answered = results(script)
        #expect(answered.count == 1 && answered[0]["tool_use_id"] as? String == "plan-1", "one tool_result answers the plan")
        let combined = json(answered[0])
        #expect(combined["ok"] as? Bool == true)
        #expect((combined["steps"] as? [[String: Any]])?.count == 2)
    }

    @MainActor @Test func aRefusedPlanRunsNothing() async {
        let script = PlanScript([planReply([["tool": "press_menu", "app": "Finder", "path": ["File", "New Folder"]],
                                            ["tool": "press_menu", "app": "Finder", "path": ["View", "as List"]]]),
                                 reply([("done", ["summary": "Could not.", "evidence": []])])])
        _ = await planLoop(script, precheck: { _ in "step 1: this task is read-only" }).run(goal: "look at my downloads")
        #expect(script.executed.isEmpty)
        let combined = json(results(script)[0])
        #expect(combined["ok"] as? Bool == false)
        #expect(combined["error"] as? String == "planRefused")
    }

    @MainActor @Test func aPlanStopsAtNotObservedAndAfterARead() async {
        let notObserved = PlanScript([planReply([["tool": "press_menu", "app": "Finder", "path": ["View", "as List"]],
                                                 ["tool": "press_menu", "app": "Finder", "path": ["Go", "Downloads"]]]),
                                      reply([("done", ["summary": "Nothing changed.", "evidence": []])])])
        _ = await planLoop(notObserved, execute: { _ in
            RealtimeToolDispatch(result: ["ok": true, "verification": "notObserved"], harnessMilliseconds: 5, waitedForConfirmation: false,
                                 harnessResponse: ["ok": true])
        }).run(goal: "list view then downloads")
        #expect(notObserved.executed.count == 1, "the second step was planned for a screen that did not change")
        let combined = json(results(notObserved)[0])
        #expect((combined["stopped"] as? String)?.contains("notObserved") == true)
        #expect((combined["steps"] as? [[String: Any]])?.last?["error"] as? String == "skipped")

        let read = PlanScript([planReply([["tool": "read_page"], ["tool": "press_menu", "app": "Finder", "path": ["View", "as List"]]]),
                               reply([("done", ["summary": "Read it.", "evidence": [1]])])])
        _ = await planLoop(read).run(goal: "read then list")
        #expect(read.reads == 1)
        #expect(read.executed.isEmpty, "a read's result must be seen before planning on it")
    }

    @MainActor @Test func aPlainBatchStopsAtNotObservedToo() async {
        let script = PlanScript([reply([("press_menu", ["app": "Finder", "path": ["View", "as List"]]),
                                        ("press_menu", ["app": "Finder", "path": ["Go", "Downloads"]])]),
                                 reply([("done", ["summary": "Nothing changed.", "evidence": []])])])
        _ = await planLoop(script, execute: { _ in
            RealtimeToolDispatch(result: ["ok": true, "verification": "notObserved"], harnessMilliseconds: 5, waitedForConfirmation: false,
                                 harnessResponse: ["ok": true])
        }).run(goal: "list view then downloads")
        #expect(script.executed.count == 1)
    }

    /// Review of e98f476: a plan's steps all share the loop's step number, and
    /// evidence cites THAT number, never a position in the plan.
    @MainActor @Test func evidenceCitesTheLoopStepNeverAPlanPosition() async {
        let script = PlanScript([planReply([["tool": "press_menu", "app": "Finder", "path": ["View", "as List"]],
                                            ["tool": "press_menu", "app": "Finder", "path": ["Go", "Downloads"]],
                                            ["tool": "done", "summary": "Pressed the two menu items.", "evidence": [2]]]),
                                 reply([("done", ["summary": "Pressed the two menu items.", "evidence": [1]])])])
        let outcome = await planLoop(script).run(goal: "list view then downloads")
        #expect(outcome == .done(summary: "Pressed the two menu items."))
        let combined = json(results(script)[0])
        let steps = combined["steps"] as? [[String: Any]] ?? []
        #expect(steps.allSatisfy { $0["step"] as? Int == 1 }, "every step of the plan carries the loop's step")
        #expect(steps.allSatisfy { $0["planStep"] == nil }, "no second numbering to cite by mistake")
        let challenge = steps.last
        #expect(challenge?["error"] as? String == "doneUnbacked")
        #expect((challenge?["message"] as? String)?.contains("step 1") == true, "the challenge says which number to cite")
        let declared = (AgentPlan.declaration["input_schema"] as? [String: Any]).flatMap { ($0["properties"] as? [String: Any])?["steps"] as? [String: Any] }
        let evidence = ((declared?["items"] as? [String: Any])?["properties"] as? [String: Any])?["evidence"] as? [String: Any]
        #expect((evidence?["description"] as? String)?.contains("never a position in the plan") == true)
    }

    /// A done must be backed by the steps it CITES, not by any ok result of the run.
    @MainActor @Test func aDoneCitingOldUnrelatedStepsIsChallenged() {
        let receipts = [AgentLoop.Receipt(step: 1, toolName: "press_element", ok: true, error: nil),
                        AgentLoop.Receipt(step: 2, toolName: "open_app", ok: true, error: nil)]
        #expect(AgentLoop.doneChallenge(summary: "I pressed Send.", evidence: [2], receipts: receipts, currentStep: 3) != nil,
                "step 2 opened an app; it is no receipt for a press")
        #expect(AgentLoop.doneChallenge(summary: "I pressed Send.", evidence: [1], receipts: receipts, currentStep: 3) == nil)
    }

    @MainActor @Test func thePromptMakesAPlanTheDefaultFirstReply() {
        #expect(AgentLoop.tools.contains { $0["name"] as? String == "plan" })
        #expect(AgentLoop.systemPrompt.contains("Reply with plan"))
        #expect(!AgentLoop.systemPrompt.contains("Call one tool per reply"))
    }
}
