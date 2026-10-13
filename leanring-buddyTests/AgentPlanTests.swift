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
            AgentPlan.livePrecheck(steps, menuOffer: map.offer(readOnly: readOnly), findOffer: find, readOnly: readOnly, screenElements: nil)
        }
        #expect(check([["tool": "press_menu", "path": ["View", "as List"]], ["tool": "press_menu", "shortcut": "⌥⌘L"]]) == nil)
        #expect(check([["tool": "press_menu", "path": ["View", "as Gallery"]]])?.contains("not in the App verbs") == true)
        let found = RealtimeStandingOffer(candidates: [RealtimeMenuCandidate(path: ["View", "as Gallery"], shortcut: nil)],
                                          app: "com.apple.finder", uptime: 0)
        #expect(check([["tool": "press_menu", "path": ["View", "as Gallery"]]], find: found) == nil, "a find of this task offers it too")
        #expect(check([["tool": "press_menu", "shortcut": "⌘9"]]) != nil)
        #expect(check([["tool": "press_menu", "path": ["File", "New Folder"]]], readOnly: true) != nil, "not shown, so not offered")
        #expect(check([["tool": "press_menu", "path": ["File", "Get Info"]]]) == nil,
                "a cached enabled flag goes stale: the kernel refuses a disabled item live, the precheck does not guess")
        // After a step that brings another app forward, its menu paths cannot be judged from this app's map.
        #expect(check([["tool": "focus_app", "name": "Notes"], ["tool": "press_menu", "path": ["File", "New Note"]]]) == nil)
        #expect(check([["tool": "focus_app", "name": "Notes"], ["tool": "press_menu", "path": ["File", "New Note"]]], readOnly: true) != nil,
                "the read-only judge needs no map, so it still applies")
    }

    @Test func aStepAimedByNameBeforeActingMustNotBeAmbiguousOrSecure() {
        let elements: [[String: Any]] = [
            ["role": "AXButton", "name": "Recent", "nameSource": "title"],
            ["role": "AXStaticText", "name": "Recent", "nameSource": "value"],
            ["role": "AXSecureTextField", "name": "Password", "nameSource": "placeholder"],
            ["role": "AXButton", "name": "Back", "nameSource": "description"]
        ]
        func check(_ steps: [[String: Any]]) -> String? {
            AgentPlan.livePrecheck(steps, menuOffer: nil, findOffer: nil, readOnly: false, screenElements: elements)
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

    /// G16 2026-10-11: "Opened Privacy & Security" citing an ok open_settings_pane was
    /// doneUnbacked twice — the navigation receipts did not know the pane opener (or go_to_folder).
    @MainActor @Test func aPaneOrFolderOpenerBacksAnOpenedClaim() {
        for tool in ["open_settings_pane", "go_to_folder"] {
            let receipts = [AgentLoop.Receipt(step: 1, toolName: tool, ok: true, error: nil)]
            #expect(AgentLoop.doneChallenge(summary: "Opened the Privacy & Security settings.", evidence: [1], receipts: receipts, currentStep: 2) == nil,
                    "\(tool) backs an opened claim")
        }
        let failed = [AgentLoop.Receipt(step: 1, toolName: "open_settings_pane", ok: false, error: "notVerified")]
        #expect(AgentLoop.doneChallenge(summary: "Opened the Privacy & Security settings.", evidence: [1], receipts: failed, currentStep: 2) != nil)
    }

    /// G05 2026-10-13 (20-09-09Z): "I have created a reminder called "JARVIS test reminder"" after
    /// open_app + press_menu + find_on_screen — nothing was ever typed, and the menu press backed "created".
    @MainActor @Test func aCreatedNameNeedsTheTypingThatGaveIt() {
        let pressed = [AgentLoop.Receipt(step: 1, toolName: "open_app", ok: true, error: nil),
                       AgentLoop.Receipt(step: 2, toolName: "press_menu", ok: true, error: nil)]
        let claim = "I have created a reminder called \u{201C}JARVIS test reminder\u{201D} in Reminders."
        #expect(AgentLoop.doneChallenge(summary: claim, evidence: [1, 2], receipts: pressed, currentStep: 3) != nil)
        let typed = pressed + [AgentLoop.Receipt(step: 3, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test reminder")]
        #expect(AgentLoop.doneChallenge(summary: claim, evidence: [2, 3], receipts: typed, currentStep: 4,
                                        seenNow: "Incomplete, JARVIS test reminder") == nil)
        let failedType = pressed + [AgentLoop.Receipt(step: 3, toolName: "type_text", ok: false, error: "kernelRefused", typed: nil)]
        #expect(AgentLoop.doneChallenge(summary: claim, evidence: [2], receipts: failedType, currentStep: 4) != nil)
        // Not a creation: a pre-existing item may be named without typing it.
        let opened = [AgentLoop.Receipt(step: 1, toolName: "go_to_folder", ok: true, error: nil)]
        #expect(AgentLoop.doneChallenge(summary: "Opened the folder called \"scripts\".", evidence: [1], receipts: opened, currentStep: 2) == nil)
        // Pasted in a longer text counts: the name is inside what was typed.
        let pasted = pressed + [AgentLoop.Receipt(step: 3, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test 2\nmacOS 15.5")]
        #expect(AgentLoop.doneChallenge(summary: "Created a new note titled 'JARVIS test 2'.", evidence: [3], receipts: pasted, currentStep: 4,
                                        seenNow: "Notes\nJARVIS test 2") == nil)
    }

    // The receipts of launch E03 and generality G04/G05/G21, launch E08 (2026-10-13), as the loop recorded them.
    static let e03Claim = "I have added the meeting called JARVIS test meeting for tomorrow at 3 pm to your calendar."
    static let e03: [AgentLoop.Receipt] = [
        .init(step: 1, toolName: "open_app", ok: true, error: nil),
        .init(step: 2, toolName: "press_menu", ok: true, error: nil),
        .init(step: 3, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test meeting tomorrow at 3 pm"),
        .init(step: 4, toolName: "press_element", ok: false, error: "confirmationDenied"),
        .init(step: 5, toolName: "find_on_screen", ok: true, error: nil, shown: "Tuesday 6 October\nWednesday 7 October"),
        .init(step: 6, toolName: "find_on_screen", ok: true, error: nil, shown: "King's Birthday (QLD). 5 October 2026, All Day"),
        .init(step: 7, toolName: "press_element", ok: true, error: nil, pressedRole: "AXStaticText"),
    ]

    /// E03 2026-10-13 (04-19-59Z): typed into Calendar's quick entry, which commits only on Return, then
    /// "added the meeting called JARVIS test meeting" — 0 events before and after. Typing is not making.
    @MainActor @Test func aCreatedNameMustBeSeenAfterItsTyping() {
        // Calendar at done: the month grid, no such event; the quick-entry field's text is never listed.
        let calendarNow = "Day\nWeek\nMonth\nKing's Birthday (QLD). 5 October 2026, All Day\nToday"
        let challenge = AgentLoop.doneChallenge(summary: Self.e03Claim, evidence: [2, 3, 7], receipts: Self.e03, currentStep: 8, seenNow: calendarNow)
        #expect(challenge?.contains("JARVIS test meeting") == true)
        #expect(AgentLoop.doneChallenge(summary: Self.e03Claim, evidence: [2, 3, 7], receipts: Self.e03, currentStep: 8) != nil, "no read at done")
        // Had the event been made, the grid lists it (LaunchSuite's measured description) and the claim stands.
        #expect(AgentLoop.doneChallenge(summary: Self.e03Claim, evidence: [2, 3, 7], receipts: Self.e03, currentStep: 8,
                                        seenNow: "JARVIS test meeting . Starts on 14 October 2026 at 3:00 pm and ends at 4:00 pm.") == nil)
        // A SUBMITTED entry (type_text's AXConfirm published, answered 0) is commit evidence; typed-only is not.
        var submitted = Self.e03
        submitted[2] = .init(step: 3, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test meeting tomorrow at 3 pm", submitted: true)
        #expect(AgentLoop.doneChallenge(summary: Self.e03Claim, evidence: [2, 3, 7], receipts: submitted, currentStep: 8, seenNow: calendarNow) == nil)
        #expect(AgentLoop.typeWasSubmitted(["ok": true, "confirm": ["published": true, "axErrorRawValue": 0, "milliseconds": 12]]))
        #expect(!AgentLoop.typeWasSubmitted(["ok": true]), "absent: not submitted")
        #expect(!AgentLoop.typeWasSubmitted(["ok": true, "confirm": ["published": false]]))
        #expect(!AgentLoop.typeWasSubmitted(["ok": true, "confirm": ["published": true, "axErrorRawValue": -25204]]))
        // 09-14-58Z: a read after the typing showed Calendar's SUGGESTION line, not an event. Typed into a field
        // that saves only when submitted, unsubmitted, is no creation whatever a read shows beside it.
        var suggested = Self.e03
        suggested[2] = .init(step: 3, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test meeting tomorrow at 3 pm", awaitsCommit: true)
        suggested[4] = .init(step: 5, toolName: "find_on_screen", ok: true, error: nil, shown: "JARVIS test meeting Tomorrow 3 pm to 4 pm")
        #expect(AgentLoop.doneChallenge(summary: Self.e03Claim, evidence: [2, 3, 7], receipts: suggested, currentStep: 8)?.contains("submit true") == true)
        #expect(AgentLoop.doneChallenge(summary: "I typed it into the new event box but did not save it.", evidence: [3],
                                        receipts: suggested, currentStep: 8) == nil, "an honest summary is no claim")
        // 09-34Z: the same receipts with a summary that names nothing the parser reads — still challenged.
        #expect(AgentLoop.doneChallenge(summary: "I opened Calendar and added the JARVIS test meeting for tomorrow at 3 pm.",
                                        evidence: [2, 3], receipts: suggested, currentStep: 8) != nil)
        // A later submitted typing settles it.
        let resubmitted = suggested + [.init(step: 8, toolName: "type_text", ok: true, error: nil,
                                             typed: "JARVIS test meeting tomorrow at 3 pm", submitted: true)]
        #expect(AgentLoop.doneChallenge(summary: "I opened Calendar and added the JARVIS test meeting for tomorrow at 3 pm.",
                                        evidence: [1, 8], receipts: resubmitted, currentStep: 9) == nil)
        // G15 09-58Z: a Save sheet's name field also publishes AXConfirm; its Save BUTTON commits it.
        let saved: [AgentLoop.Receipt] = [
            .init(step: 1, toolName: "open_app", ok: true, error: nil),
            .init(step: 2, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test 3", awaitsCommit: true),
            .init(step: 3, toolName: "press_element", ok: true, error: nil, pressedRole: "AXButton")]
        #expect(AgentLoop.doneChallenge(summary: "Created a document and saved it to the Desktop named JARVIS test 3.",
                                        evidence: [1, 2, 3], receipts: saved, currentStep: 4, seenNow: "JARVIS test 3.rtf") == nil)
        // A read BEFORE the typing proves nothing about it.
        let readFirst = [AgentLoop.Receipt(step: 1, toolName: "find_on_screen", ok: true, error: nil, shown: "JARVIS test meeting")] + Self.e03
        #expect(AgentLoop.doneChallenge(summary: Self.e03Claim, evidence: [3], receipts: readFirst, currentStep: 8) != nil)
        // An honest summary of the same receipts is no creation claim.
        #expect(AgentLoop.doneChallenge(summary: "I typed JARVIS test meeting tomorrow at 3 pm into Calendar's new event box, but no event shows yet.",
                                        evidence: [3], receipts: Self.e03, currentStep: 8, seenNow: calendarNow) == nil)
    }

    /// G04 / G21 (Notes: press File > New Note, paste, done in the same reply) and G05 (Reminders:
    /// New Reminder, type, read_page, done) passed 2026-10-13 and really created; E08 names by rename_item.
    @MainActor @Test func realCreationsPassWhenTheNameIsSeen() {
        let g04 = [AgentLoop.Receipt(step: 1, toolName: "open_app", ok: true, error: nil),
                   .init(step: 2, toolName: "press_menu", ok: true, error: nil),
                   .init(step: 2, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test 1\nhello")]
        let g04Claim = "Created a new note titled JARVIS test 1 with the line hello in Notes."
        // No read after the paste but the one at done: the notes list names the note (the G04 checker's own witness).
        #expect(AgentLoop.doneChallenge(summary: g04Claim, evidence: [2], receipts: g04, currentStep: 2, seenNow: "Notes\nJARVIS test 1\nhello") == nil)
        #expect(AgentLoop.doneChallenge(summary: g04Claim, evidence: [2], receipts: g04, currentStep: 2, seenNow: "Notes\nNew Note") != nil)

        let g21 = [AgentLoop.Receipt(step: 1, toolName: "open_settings_pane", ok: true, error: nil),
                   .init(step: 2, toolName: "open_app", ok: true, error: nil),
                   .init(step: 3, toolName: "press_menu", ok: true, error: nil),
                   .init(step: 3, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test 2\nmacOS Sequoia Version 15.5")]
        let g21Claim = "I found that this Mac is running macOS Sequoia Version 15.5 and created a new note titled JARVIS test 2 with this version written in it."
        #expect(AgentLoop.doneChallenge(summary: g21Claim, evidence: [1, 3], receipts: g21, currentStep: 3, seenNow: "JARVIS test 2\n10:08 macOS Sequoia") == nil)

        let g05 = [AgentLoop.Receipt(step: 1, toolName: "open_app", ok: true, error: nil),
                   .init(step: 2, toolName: "press_menu", ok: true, error: nil),
                   .init(step: 3, toolName: "type_text", ok: true, error: nil, typed: "JARVIS test reminder"),
                   .init(step: 4, toolName: "read_page", ok: true, error: nil, shown: "Reminders\nIncomplete, JARVIS test reminder")]
        let g05Claim = "Created a reminder called JARVIS test reminder in Reminders."
        #expect(AgentLoop.doneChallenge(summary: g05Claim, evidence: [1, 2, 4], receipts: g05, currentStep: 5) == nil, "seen by its own read_page")
        #expect(AgentLoop.doneChallenge(summary: g05Claim, evidence: [1, 2, 4], receipts: g05, currentStep: 5, seenNow: "Reminders") == nil)

        let e08 = [AgentLoop.Receipt(step: 1, toolName: "go_to_folder", ok: true, error: nil),
                   .init(step: 2, toolName: "press_menu", ok: true, error: nil),
                   .init(step: 2, toolName: "rename_item", ok: true, error: nil, typed: "Receipts"),
                   .init(step: 3, toolName: "move_items", ok: true, error: nil)]
        for claim in ["Created the Receipts folder in JARVIS-sandbox and moved invoice-a.pdf and invoice-b.pdf into it.",
                      "Created a folder called Receipts and moved the two invoices into it."] {
            #expect(AgentLoop.doneChallenge(summary: claim, evidence: [2, 3], receipts: e08, currentStep: 3) == nil, "\(claim)")
        }
    }

    @MainActor @Test func createdNamesReadsQuotedBareAndAddedToShapes() {
        #expect(AgentLoop.createdNames(Self.e03Claim) == ["JARVIS test meeting"])
        #expect(AgentLoop.createdNames("Created a new note titled JARVIS test 1 with the line hello in Notes.") == ["JARVIS test 1"])
        #expect(AgentLoop.createdNames("Created a reminder called \u{201C}JARVIS test reminder\u{201D}.") == ["JARVIS test reminder"])
        #expect(AgentLoop.createdNames("I added milk and eggs to your Shopping list.") == ["milk", "eggs"])
        #expect(AgentLoop.createdNames("I've added Dentist to my calendar") == ["Dentist"])
        #expect(AgentLoop.createdNames("I added the meeting to your calendar.").isEmpty, "no name given")
        #expect(AgentLoop.createdNames("Opened the folder called scripts.").isEmpty, "not a creation")
        #expect(AgentLoop.createdNames("I added Chrome to your Dock.").isEmpty, "not a list")
    }

    /// G11 2026-10-11 (04-55-54Z): "The scheme selected in Xcode is leanring-buddy", backed by a
    /// find_on_screen read, was doneUnbacked as if it claimed a press. A state is not an effect.
    @MainActor @Test func aSelectedStateIsNotAPressClaim() {
        let read = [AgentLoop.Receipt(step: 1, toolName: "find_on_screen", ok: true, error: nil)]
        for summary in ["The scheme selected in Xcode is leanring-buddy.", "The selected scheme is leanring-buddy.",
                        "leanring-buddy is selected.", "The scheme currently selected is leanring-buddy."] {
            #expect(AgentLoop.doneChallenge(summary: summary, evidence: [1], receipts: read, currentStep: 2) == nil, "\(summary)")
        }
        for summary in ["I selected the Downloads folder.", "Selected the Downloads folder.", "We selected Delete.",
                        "I now selected the Downloads folder.", "I currently selected Delete.", "We now selected the file.",
                        "I selected Delete and it is gone."] {
            #expect(AgentLoop.doneChallenge(summary: summary, evidence: [1], receipts: read, currentStep: 2) != nil, "\(summary)")
        }
    }

    /// A done must be backed by the steps it CITES, not by any ok result of the run.
    @MainActor @Test func aDoneCitingOldUnrelatedStepsIsChallenged() {
        let receipts = [AgentLoop.Receipt(step: 1, toolName: "press_element", ok: true, error: nil),
                        AgentLoop.Receipt(step: 2, toolName: "open_app", ok: true, error: nil)]
        #expect(AgentLoop.doneChallenge(summary: "I pressed Send.", evidence: [2], receipts: receipts, currentStep: 3) != nil,
                "step 2 opened an app; it is no receipt for a press")
        #expect(AgentLoop.doneChallenge(summary: "I pressed Send.", evidence: [1], receipts: receipts, currentStep: 3) == nil)
    }

    /// A refused plan is a refusal like any other: three alike end the task.
    @MainActor @Test func aRepeatedlyRefusedPlanEndsAsRefusals() async {
        let script = PlanScript([planReply([["tool": "press_menu", "app": "Finder", "path": ["View", "as List"]]])])
        let outcome = await planLoop(script, precheck: { _ in "step 1: not offered" }).run(goal: "list view")
        #expect(outcome == .refusals(error: "planRefused"))
        #expect(script.bodies.count == AgentLoop.maximumSameRefusals)
    }

    @MainActor @Test func thePromptMakesAPlanTheDefaultFirstReply() {
        #expect(AgentLoop.tools.contains { $0["name"] as? String == "plan" })
        #expect(AgentLoop.systemPrompt.contains("Reply with plan"))
        #expect(!AgentLoop.systemPrompt.contains("Call one tool per reply"))
    }
}
