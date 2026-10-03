//
//  AgentLoopTests.swift
//  leanring-buddyTests
//
//  The agent loop's pure logic with a fake model and a fake harness answer:
//  where it stops (done, 15 steps, 180 s, 3 like refusals, a press), that an
//  unbacked `done` is challenged once, that only the latest picture is sent,
//  that the trace never holds typed text or the goal, that a ticket's wait
//  carries the step to the card, and that every declared parameter reaches the
//  Anthropic tool JSON. Whether Claude drives real pages is the live probe's
//  (`--agent-loop-probe`), not this file's. Also the voice findings of the
//  2026-10-03 runner pass: internal words spoken, and claims that are none.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
private final class Script {
    var replies: [[String: Any]]
    var bodies: [[String: Any]] = []
    var executed: [RealtimeToolCall] = []
    var traces: [[String: Any]] = []
    var steps: [ConfirmationStep?] = []
    var now: TimeInterval = 1000
    var secondsPerModelCall: TimeInterval = 1
    init(_ replies: [[String: Any]]) { self.replies = replies }
}

private func toolUse(_ name: String, _ input: [String: Any] = [:], id: String = UUID().uuidString) -> [String: Any] {
    ["stop_reason": "tool_use", "content": [["type": "thinking", "thinking": ""], ["type": "tool_use", "id": id, "name": name, "input": input]]]
}

private func dispatch(ok: Bool, error: String? = nil) -> RealtimeToolDispatch {
    RealtimeToolDispatch(result: ["ok": ok, "error": error ?? NSNull(), "message": ok ? "done" : "refused"], harnessMilliseconds: 5,
                         waitedForConfirmation: false, harnessResponse: ["ok": ok])
}

@MainActor
private func loop(_ script: Script, image: Bool = false,
                  execute: ((RealtimeToolCall) async -> RealtimeToolDispatch)? = nil) -> AgentLoop {
    AgentLoop(dependencies: AgentLoop.Dependencies(
        model: { body in
            script.bodies.append(body)
            script.now += script.secondsPerModelCall
            let reply = script.replies.count > 1 ? script.replies.removeFirst() : script.replies[0]
            return AgentModelReply(json: reply, model: "fake", milliseconds: 7)
        },
        observe: { AgentObservation(jpeg: image ? Data([0xFF, 0xD8, 0xFF]) : nil, frame: nil, look: image ? "attached" : "noAppInFront",
                                    lines: ["system context, not the owner's words: the app in front is \"Chrome\"."]) },
        execute: { call, _, _ in
            script.executed.append(call)
            if let execute { return await execute(call) }
            return dispatch(ok: true)
        },
        readPage: { ["ok": true, "text": "page"] },
        onStep: { script.steps.append($0) },
        trace: { script.traces.append($0) },
        uptime: { script.now }
    ))
}

struct AgentLoopTests {

    @MainActor @Test func stopsAtABackedDone() async {
        let script = Script([toolUse("scroll", ["direction": "down"]),
                             toolUse("done", ["summary": "Scrolled to the plans.", "evidence": [1]])])
        let outcome = await loop(script).run(goal: "scroll to the plans")
        #expect(outcome == .done(summary: "Scrolled to the plans."))
        #expect(script.executed.map(\.name) == ["scroll"])
        #expect(script.traces.map { $0["kind"] as? String } == ["step", "step", "end"])
        // The card's footer: step 1/15, step 2/15, then cleared.
        #expect(script.steps == [ConfirmationStep(current: 1, total: 15), ConfirmationStep(current: 2, total: 15), nil])
        // Thinking blocks never go back; one call per reply is asked for.
        let assistant = (script.bodies[1]["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]]
        #expect(assistant?.contains { $0["type"] as? String == "thinking" } == false)
        #expect((script.bodies[0]["tool_choice"] as? [String: Any])?["disable_parallel_tool_use"] as? Bool == true)
    }

    @MainActor @Test func stopsAtTheStepCap() async {
        let script = Script([toolUse("scroll", ["direction": "down"])])
        let outcome = await loop(script).run(goal: "keep scrolling")
        #expect(outcome == .stepCap)
        #expect(script.executed.count == AgentLoop.maximumSteps)
        #expect(script.bodies.count == 15)
    }

    @MainActor @Test func stopsAtTheTimeCap() async {
        let script = Script([toolUse("scroll", ["direction": "down"])])
        script.secondsPerModelCall = 20
        let agent = loop(script)
        let outcome = await agent.run(goal: "keep scrolling")
        #expect(outcome == .timeCap)
        #expect(script.bodies.count == 9)   // 9 x 20 s = 180 s: no tenth call
        #expect(script.traces.last?["outcome"] as? String == "timeCap")
    }

    @MainActor @Test func stopsAtThreeRefusalsOfTheSameKind() async {
        let script = Script([toolUse("press_element", ["name": "Post"])])
        let codes = ["elementNotFound", "notOffered", "elementNotFound", "elementNotFound", "elementNotFound"]
        var index = 0
        let outcome = await loop(script, execute: { _ in
            defer { index += 1 }
            return dispatch(ok: false, error: codes[index])
        }).run(goal: "post it")
        // A different refusal between them resets the count.
        #expect(outcome == .refusals(error: "elementNotFound"))
        #expect(script.executed.count == 5)
    }

    @MainActor @Test func aDoneWithoutReceiptsIsChallengedOnceThenFails() async {
        let script = Script([toolUse("done", ["summary": "I pressed Post.", "evidence": [1]], id: "first"),
                             toolUse("done", ["summary": "I pressed Post.", "evidence": [Int]()])])
        let outcome = await loop(script).run(goal: "post it")
        #expect(outcome == .failed(reason: "its summary claimed what no result of this task shows"))
        let second = script.bodies[1]["messages"] as? [[String: Any]]
        let challenge = (second?.last?["content"] as? [[String: Any]])?.first
        #expect(challenge?["tool_use_id"] as? String == "first")
        #expect((challenge?["content"] as? String)?.contains("your receipts do not show") == true)
        #expect(challenge?["is_error"] as? Bool == true)
    }

    @MainActor @Test func aChallengedDoneMayStandOnceItClaimsOnlyWhatHappened() async {
        let script = Script([toolUse("read_page"),
                             toolUse("done", ["summary": "I opened their site.", "evidence": [1]]),
                             toolUse("done", ["summary": "The page lists three plans; the cheapest is Starter.", "evidence": [1]])])
        let outcome = await loop(script).run(goal: "what plans are there")
        #expect(outcome == .done(summary: "The page lists three plans; the cheapest is Starter."))
        // A page's own words are no claim: "opened in 2019" is a fact read, not done.
        #expect(AgentLoop.doneChallenge(summary: "The shop opened in 2019.", evidence: [], receipts: []) == nil)
        #expect(AgentLoop.doneChallenge(summary: "Done.", evidence: [], receipts: []) != nil)
        #expect(AgentLoop.doneChallenge(summary: "It worked.", evidence: [2],
                                        receipts: [AgentLoop.Receipt(step: 2, toolName: "scroll", ok: false, error: "x")]) != nil)
    }

    @MainActor @Test func aPressStopsTheLoopBeforeTheNextTool() async {
        let script = Script([toolUse("press_element", ["name": "Post"])])
        let agent = AgentLoop(dependencies: AgentLoop.Dependencies(
            model: { _ in
                // The owner's press lands while the model is thinking.
                withUnsafeCurrentTask { $0?.cancel() }
                return AgentModelReply(json: script.replies[0], model: "fake", milliseconds: 1)
            },
            observe: { AgentObservation() },
            execute: { call, _, _ in script.executed.append(call); return dispatch(ok: true) },
            readPage: { [:] },
            trace: { script.traces.append($0) }))
        let outcome = await agent.run(goal: "post it")
        #expect(outcome == .cancelled)
        #expect(script.executed.isEmpty)
        #expect(agent.step == 1)
        #expect(AgentLoop.finalLine(outcome, goal: "post it", lastProgress: nil, step: 1) == nil)
        #expect(AgentLoop.stoppedContextLine(step: 1).contains("stopped at step 1"))
    }

    @MainActor @Test func onlyTheLatestScreenshotIsSent() async {
        let script = Script([toolUse("scroll", ["direction": "down"]), toolUse("scroll", ["direction": "down"]),
                             toolUse("done", ["summary": "Scrolled twice.", "evidence": [1, 2]])])
        _ = await loop(script, image: true).run(goal: "scroll")
        let blocks = (script.bodies[2]["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
        #expect(blocks.filter { $0["type"] as? String == "image" }.count == 1)
        #expect(blocks.filter { $0["text"] as? String == AgentLoop.removedImageText }.count == 2)
        // The one image is in the last user message.
        let last = (script.bodies[2]["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        #expect(last?.contains { $0["type"] as? String == "image" } == true)
    }

    @MainActor @Test func theTraceNeverHoldsTypedTextOrTheGoal() async {
        let typed = "milk eggs and my door code 4471"
        let goal = "write my shopping list into the note"
        let script = Script([toolUse("type_text", ["text": typed]), toolUse("search_web", ["query": "superloop plans nbn"]),
                             toolUse("done", ["summary": "Typed it.", "evidence": [1]])])
        _ = await loop(script).run(goal: goal)
        let lines = script.traces.compactMap(MeasurementLogFile.jsonLine)
        #expect(lines.count == 4)
        for line in lines {
            #expect(!line.contains("milk") && !line.contains("4471") && !line.contains("shopping") && !line.contains("superloop"))
        }
        #expect(lines[0].contains("\"textLength\":\(typed.count)"))
        #expect(lines[1].contains("\"queryLength\":19"))
        // search_web goes out as an open_url of the fixed host, through the same execute.
        #expect(script.executed.map(\.name) == ["type_text", "open_url"])
        #expect(URL(string: script.executed[1].url ?? "")?.host == "www.google.com")
    }

    @MainActor @Test func aConfirmationStepWaitsAndTheCardShowsTheStep() async {
        let answers = HarnessScriptedAnswers([
            #"{"ok":false,"error":"confirmationRequired","ticket":"T1"}"#,
            #"{"ok":false,"error":"confirmationPending"}"#,
            #"{"ok":true,"status":"opened"}"#
        ])
        let script = Script([toolUse("search_web", ["query": "superloop"]), toolUse("done", ["summary": "I opened the search.", "evidence": [1]])])
        var stepWhileWaiting: ConfirmationStep??
        var waited = false
        let agent = AgentLoop(dependencies: AgentLoop.Dependencies(
            model: { body in script.bodies.append(body); return AgentModelReply(json: script.replies.removeFirst(), model: "fake", milliseconds: 1) },
            observe: { AgentObservation() },
            execute: { call, _, _ in
                let result = await RealtimeOpenAppTool.dispatch(call, answer: { answers.next($0) }, pollMilliseconds: 5,
                                                                onConfirmationRequired: { stepWhileWaiting = script.steps.last })
                waited = result.waitedForConfirmation
                return result
            },
            readPage: { [:] },
            onStep: { script.steps.append($0) },
            trace: { script.traces.append($0) }))
        let outcome = await agent.run(goal: "search for superloop")
        #expect(outcome == .done(summary: "I opened the search."))
        #expect(waited)
        #expect(stepWhileWaiting == .some(ConfirmationStep(current: 1, total: 15)))
        #expect(answers.lines.count == 3)
        #expect(answers.lines[1].contains("\"ticket\":\"T1\""))
        #expect(script.steps.last == .some(nil))
    }

    @MainActor @Test func theToolJSONCarriesEveryDeclaredParameter() {
        let anthropic = AgentLoop.tools
        let byName = Dictionary(uniqueKeysWithValues: anthropic.compactMap { tool in (tool["name"] as? String).map { ($0, tool) } })
        #expect(byName["do_task"] == nil)
        for name in ["search_web", "read_page", "done", "ask_owner"] { #expect(byName[name] != nil, "\(name)") }
        for declaration in RealtimeVoiceVerbs.openAIDeclarations(pointFormat: .fractions) {
            guard let name = declaration["name"] as? String, name != "do_task" else { continue }
            let parameters = declaration["parameters"] as? [String: Any]
            let schema = byName[name]?["input_schema"] as? [String: Any]
            #expect(schema?["type"] as? String == "object", "\(name)")
            let declared = (parameters?["properties"] as? [String: Any]) ?? [:]
            let converted = (schema?["properties"] as? [String: Any]) ?? [:]
            #expect(Set(declared.keys) == Set(converted.keys), "\(name)")
            for (key, value) in declared {
                #expect((value as? [String: Any])?["type"] as? String == (converted[key] as? [String: Any])?["type"] as? String, "\(name).\(key)")
            }
            #expect(Set(parameters?["required"] as? [String] ?? []) == Set(schema?["required"] as? [String] ?? []), "\(name)")
        }
        // The realtime stacks get do_task; the loop never does.
        #expect(RealtimeVoiceVerbs.openAIDeclarations.contains { $0["name"] as? String == "do_task" })
    }

    @Test func pageTextIsWhatTheHarnessListsWithSecretsAndFieldsWithheld() {
        let response: [String: Any] = ["elements": [
            ["role": "AXWindow", "name": "Shop"],
            ["role": "AXLink", "name": "Plans", "parent": 0],
            ["role": "AXStaticText", "name": "Plans", "parent": 1],
            ["role": "AXStaticText", "name": "Starter $19 a month"],
            ["role": "AXTextField", "name": "hunter2", "nameSource": "value"],
            ["role": "AXStaticText", "name": "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH"]
        ]]
        let text = AgentLoop.pageText(fromSnapshotResponse: response).text
        #expect(text.hasPrefix("Plans\nStarter $19 a month"))
        #expect(!text.contains("hunter2") && !text.contains("Shop"))
        #expect(!text.contains("abcdefghijklmnop"))
    }

    @MainActor @Test func theFinalLinesClaimOnlyTheOutcome() {
        #expect(AgentLoop.finalLine(.done(summary: "The cheapest is Starter."), goal: "g", lastProgress: nil, step: 3)?.contains("The cheapest is Starter.") == true)
        let failed = AgentLoop.finalLine(.refusals(error: "elementNotFound"), goal: "g", lastProgress: "pressed Plans", step: 4) ?? ""
        #expect(failed.contains("step 4") && failed.contains("pressed Plans") && failed.contains("claim nothing else"))
        #expect(AgentModelError(status: 404, body: #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-sonnet-5-5"}}"#).isModelNotFound)
        #expect(!AgentModelError(status: 404, body: "Not found").isModelNotFound)
        #expect((AgentLoopModel.completed([:], model: AgentLoopModel.preferred)["thinking"] as? [String: Any])?["type"] as? String == "between_tools")
        #expect(AgentLoopModel.completed([:], model: AgentLoopModel.fallback)["thinking"] == nil)
    }

    // MARK: Runner findings 2026-10-03 (voice)

    @Test func internalWordsSpokenAloudAreFound() {
        let a9 = "That didn't take. Since you didn't say where my cursor is, I cannot use underPointer. You can point at it with find_on_screen."
        #expect(RealtimeOpenAppTool.internalWordsSpoken(a9) == ["underPointer", "find_on_screen"])
        let c1 = "system context, not the owner's words: the owner is talking to someone else."
        #expect(RealtimeOpenAppTool.internalWordsSpoken(c1).contains("system context"))
        #expect(RealtimeOpenAppTool.internalWordsSpoken("I opened LinkedIn on your iPhone; the macOS menu is up.").isEmpty)
        #expect(RealtimeOpenAppTool.internalWordsSpoken("It came back heardUnavailable.") == ["heardUnavailable"])
        let prompt = RealtimeOpenAppTool.systemPrompt
        #expect(prompt.contains("a tool's name, a parameter's name and an error code are yours, never the owner's: never say one aloud"))
        #expect(prompt.contains("lines that begin \"system context\" or \"system event\" are for you alone: never read them out"))
        #expect(prompt.contains("call do_task once with the owner's whole request as the goal"))
    }

    /// The "typed" claims of the runner pass WERE corrected aloud (FA6306EB,
    /// F9CBC3E3, 3687D411: receiptCorrectionSent true) — answers.jsonl holds only
    /// the owner turn's words, not the correction's. The two flagged turns
    /// with no correction claimed nothing: "Nothing was typed." and "send it
    /// when you're ready", which the bare-word metric counted.
    @Test func typedClaimsAreCorrectedAndHonestRepliesAreNotClaims() {
        let refused = RealtimeToolDecision(call: RealtimeToolCall(callID: "t", name: "type_text", appName: "Google Chrome"), callUptime: 1,
                                           offeredBeforeCall: nil,
                                           dispatch: RealtimeToolDispatch(result: ["ok": false, "error": "heardUnavailable", "message": "Nothing was typed."],
                                                                          harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil))
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: "Typed \u{201C}the quick brown fox\u{201D} into the search box.", decisions: [refused]) != nil)
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: "I typed \"Hello World\" into the search box, sir.", decisions: [refused]) != nil)
        #expect(!RealtimeOpenAppTool.claimedWithoutReceipt(transcript: "Which app was that, sir? Nothing was typed.", okToolNames: []))
        #expect(!RealtimeOpenAppTool.claimedWithoutReceipt(transcript: "You may send it when you're ready.", okToolNames: []))
        #expect(RealtimeOpenAppTool.claimedWithoutReceipt(transcript: "I typed it, sir.", okToolNames: []))
    }
}

/// A harness that answers from a script, one line per request, and keeps what it was asked.
private final class HarnessScriptedAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]
    private(set) var lines: [String] = []
    init(_ queue: [String]) { self.queue = queue }
    func next(_ line: String) -> String {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        return queue.count > 1 ? queue.removeFirst() : queue[0]
    }
}
