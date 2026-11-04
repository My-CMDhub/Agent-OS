//
//  AgentOneThingTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Clicky

struct AgentOneThingTests {
    private func call(_ name: String, what: String? = nil, path: [String]? = nil, shortcut: String? = nil, element: String? = nil, text: String? = nil) -> RealtimeToolCall {
        RealtimeToolCall(callID: "1", name: name, appName: "TextEdit", path: path, shortcut: shortcut, elementName: element, text: text, what: what)
    }
    private func taken(_ tool: String) -> AgentLoop.Receipt { AgentLoop.Receipt(step: 1, toolName: tool, ok: true, error: nil, takesAway: .close) }

    @Test func oneIsOneAndSeveralIsSaid() {
        for words in ["get rid of this", "close this", "I don't need this window right now", "could you close that calculator thing, yeah, just, close it",
                      "close this and open safari", "quit notes", "close notes", "delete the first draft", "just trash that first draft for me would you"] {
            #expect(AgentOneThing.thingsAsked(heard: words) == 1, "\(words)")
        }
        for words in ["close all of them", "close every window", "close my windows", "delete those", "close both", "close the three tabs", "close 2 windows"] {
            #expect(AgentOneThing.thingsAsked(heard: words) == nil, "\(words)")
        }
        #expect(AgentOneThing.thingsAsked(heard: "close calculator and notes") == 2)
        #expect(AgentOneThing.thingsAsked(heard: "close calculator, then close notes") == 2)
        #expect(AgentOneThing.thingsAsked(heard: "close this and the other one") == 2)
    }

    @Test func whatTakesSomethingAway() {
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.closeName, what: "window")) == .close)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.closeName, what: "app")) == .quit)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.pressMenuName, path: ["File", "Close Tab"])) == .close)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.pressMenuName, path: ["File", "Move to Bin"])) == .delete)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.pressKeysName, shortcut: "Cmd+W")) == .close)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.pressElementName, element: "Delete")) == .delete)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.moveItemsName, text: "Bin")) == .delete)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.moveItemsName, text: "Projects")) == nil)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.pressElementName, element: "Sign In")) == nil)
        #expect(AgentOneThing.kind(of: call(RealtimeVoiceVerbs.pressElementName)) == nil)
    }

    @Test func aSecondCloseIsRefusedOnlyWhenOneWasAsked() {
        let close = call(RealtimeVoiceVerbs.closeName, what: "window")
        #expect(AgentOneThing.refusal(call: close, heard: "get rid of this", receipts: []) == nil)
        let told = AgentOneThing.refusal(call: close, heard: "get rid of this", receipts: [taken(RealtimeVoiceVerbs.closeName)])
        #expect(told?.contains("Tell me if you meant the others") == true)
        #expect(AgentOneThing.refusal(call: close, heard: "close all of them", receipts: [taken(RealtimeVoiceVerbs.closeName)]) == nil)
        #expect(AgentOneThing.refusal(call: close, heard: "close calculator and notes", receipts: [taken(RealtimeVoiceVerbs.closeName)]) == nil)
        #expect(AgentOneThing.refusal(call: close, heard: "close calculator and notes", receipts: [taken(RealtimeVoiceVerbs.closeName), taken(RealtimeVoiceVerbs.closeName)]) != nil)
    }

    /// Close, then the app's save sheet asks: its Delete is the same thing, and a second close after it is not.
    @Test func theAppsOwnQuestionIsTheSameThing() {
        let sheet = call(RealtimeVoiceVerbs.pressElementName, element: "Delete")
        let closed = [taken(RealtimeVoiceVerbs.closeName)]
        #expect(AgentOneThing.refusal(call: sheet, heard: "close this", receipts: closed) == nil)
        let answered = closed + [taken(RealtimeVoiceVerbs.pressElementName)]
        #expect(AgentOneThing.refusal(call: call(RealtimeVoiceVerbs.closeName, what: "window"), heard: "close this", receipts: answered) != nil)
        // Selecting another row between two Deletes is another thing.
        let selected = [taken(RealtimeVoiceVerbs.pressElementName), AgentLoop.Receipt(step: 2, toolName: RealtimeVoiceVerbs.pressElementName, ok: true, error: nil)]
        #expect(AgentOneThing.refusal(call: sheet, heard: "delete the first draft", receipts: selected) != nil)
    }

    @Test func aMenuItemThatTakesManyNeedsWordsThatSaySo() {
        let closeAll = call(RealtimeVoiceVerbs.pressMenuName, path: ["File", "Close All"])
        #expect(AgentOneThing.refusal(call: closeAll, heard: "get rid of this", receipts: [])?.contains("didn't close") == true)
        #expect(AgentOneThing.refusal(call: closeAll, heard: "close all my windows", receipts: []) == nil)
    }

    @MainActor @Test func oneClauseHearsItCanEndInOneReply() {
        #expect(AgentLoop.goalText(goal: "x", heard: "close this").contains(AgentLoop.oneActionNote))
        #expect(!AgentLoop.goalText(goal: "x", heard: "close this and open safari").contains(AgentLoop.oneActionNote))
        #expect(!AgentLoop.goalText(goal: "x", heard: "what is open", readOnly: true).contains(AgentLoop.oneActionNote))
        #expect(!AgentLoop.goalText(goal: "x", heard: nil).contains(AgentLoop.oneActionNote))
    }

    @MainActor @Test func aDeedTheOwnerAskedForEndsOnItsReceipt() {
        func end(_ call: RealtimeToolCall, _ heard: String, verification: String? = "confirmed") -> String? {
            AgentLoop.deedEnd(call: call, verification: verification, heard: heard)
        }
        let close = call(RealtimeVoiceVerbs.closeName, what: "window")
        #expect(end(close, "get rid of this") == "Closed the window.")
        #expect(end(close, "get rid of this", verification: "notObserved") == nil)
        #expect(end(close, "close this and open safari") == nil)
        let hide = call(RealtimeVoiceVerbs.pressMenuName, path: ["TextEdit", "Hide TextEdit"])
        #expect(end(hide, "hide text edit, would you") == "Done: Hide TextEdit.")
        #expect(end(call(RealtimeVoiceVerbs.pressMenuName, path: ["Window", "Minimize"]), "can you minimise the text edit in front of me") == "Done: Minimize.")
        // A first step towards more, in a menu or by a press, is the model's to judge.
        #expect(end(call(RealtimeVoiceVerbs.pressMenuName, path: ["File", "New"]), "open a new text edit document") == nil)
        #expect(end(call(RealtimeVoiceVerbs.pressElementName, element: "First draft"), "delete the first draft") == nil)
        var open = call(RealtimeOpenAppTool.name); open.appName = "Safari"
        #expect(end(open, "open safari", verification: nil) == "Opened Safari.")
        var editor = call(RealtimeOpenAppTool.name); editor.appName = "TextEdit"
        #expect(end(editor, "open a new text edit document", verification: nil) == nil)
        var finder = call(RealtimeOpenAppTool.name); finder.appName = "Notes"
        #expect(end(finder, "find my note about the trip", verification: nil) == nil)
        var scroll = call(RealtimeVoiceVerbs.scrollName); scroll.direction = "down"
        #expect(end(scroll, "scroll down") == "Scrolled down.")
        #expect(end(scroll, "scroll to the plans") == nil)
    }

    /// K05's shape through the loop itself, by the menu (no deed's end there): a second verified close never runs, and the owner hears what happened.
    @MainActor @Test func theLoopEndsAtTheSecondClose() async {
        var replies: [[String: Any]] = [
            ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "a", "name": "press_menu", "input": ["app": "TextEdit", "path": ["File", "Close"]]]]],
            ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "b", "name": "press_menu", "input": ["app": "TextEdit", "path": ["File", "Close"]]]]]]
        var executed = 0
        let agent = AgentLoop(dependencies: AgentLoop.Dependencies(
            model: { _, _ in AgentModelReply(json: replies.removeFirst(), model: "fake", milliseconds: 1) },
            observe: { AgentObservation(jpeg: nil, frame: nil, look: "noAppInFront", lines: [], bundleIdentifier: nil) },
            execute: { _, _, _, _ in
                executed += 1
                return RealtimeToolDispatch(result: ["ok": true, "verification": "confirmed"], harnessMilliseconds: 1, waitedForConfirmation: false, harnessResponse: ["ok": true])
            },
            readPage: { ["ok": true] }, onStep: { _ in }, narrate: { _ in }, trace: { _ in }, uptime: { 1 }, frontBundle: { nil }))
        let outcome = await agent.run(goal: "get rid of this", heard: "get rid of this")
        #expect(executed == 1)
        #expect(outcome == .done(summary: "Closed that one. Tell me if you meant the others."))
    }
}
