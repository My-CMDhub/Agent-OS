//
//  AgentTaskStateTests.swift
//  leanring-buddyTests
//
//  The task's phase (2026-10-10): one source the status line, the notch and
//  do_task read; every move a run makes is a legal one, logged with wall time.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
private final class Fake {
    var replies: [[String: Any]]
    var now: TimeInterval = 1000
    var phases: [(AgentTaskPhase, Int)] = []
    weak var loop: AgentLoop?
    var cardOnCall: String?
    init(_ replies: [[String: Any]]) { self.replies = replies }
}

private func call(_ name: String, _ input: [String: Any] = [:]) -> [String: Any] {
    ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": UUID().uuidString, "name": name, "input": input]]]
}

@MainActor
private func fakeLoop(_ fake: Fake) -> AgentLoop {
    let loop = AgentLoop(dependencies: AgentLoop.Dependencies(
        model: { _, _ in
            fake.now += 1
            let reply = fake.replies.count > 1 ? fake.replies.removeFirst() : fake.replies[0]
            return AgentModelReply(json: reply, model: "fake", milliseconds: 1)
        },
        observe: { AgentObservation() },
        execute: { call, _, _, _ in
            if call.name == fake.cardOnCall { fake.loop?.noteCardPending() }
            return RealtimeToolDispatch(result: ["ok": true], harnessMilliseconds: 1, waitedForConfirmation: call.name == fake.cardOnCall,
                                        harnessResponse: ["ok": true])
        },
        readPage: { ["ok": true, "text": "page"] },
        trace: { _ in },
        uptime: { fake.now },
        onPhase: { fake.phases.append(($0, $1)) }))
    fake.loop = loop
    return loop
}

@MainActor struct AgentTaskStateTests {

    @Test func illegalMovesAreRefusedByTheTable() {
        #expect(AgentTaskPhase.canMove(from: nil, to: .planning))
        #expect(!AgentTaskPhase.canMove(from: nil, to: .acting))
        #expect(!AgentTaskPhase.canMove(from: .done, to: .acting))
        #expect(!AgentTaskPhase.canMove(from: .failed, to: .planning))
        #expect(!AgentTaskPhase.canMove(from: .cancelled, to: .planning))
        #expect(!AgentTaskPhase.canMove(from: .waitingForOwner, to: .acting))
        #expect(!AgentTaskPhase.canMove(from: .waitingForCard, to: .waitingForOwner))
        #expect(AgentTaskPhase.canMove(from: .interrupted, to: .planning))
        for terminal in [AgentTaskPhase.done, .failed, .cancelled, .timedOut] {
            for next in AgentTaskPhase.allCases { #expect(!AgentTaskPhase.canMove(from: terminal, to: next)) }
        }
    }

    @Test func aRunMovesOnlyThroughLegalPhasesWithWallTimes() async {
        let fake = Fake([call("scroll", ["direction": "down"]), call("done", ["summary": "Scrolled.", "evidence": [1]])])
        let loop = fakeLoop(fake)
        _ = await loop.run(goal: "scroll")
        #expect(loop.transitions.map(\.phase) == [.planning, .acting, .planning, .acting, .done])
        #expect(loop.illegalTransitions == 0)
        #expect(loop.transitions.allSatisfy { abs($0.at.timeIntervalSinceNow) < 60 })
        #expect(fake.phases.map(\.0) == loop.transitions.map(\.phase))
        #expect(fake.phases.map(\.1) == [1, 1, 2, 2, 2])
    }

    @Test func askOwnerWaitsAndTheAnswerResumesPlanning() async {
        let fake = Fake([call("ask_owner", ["question": "Which chat?"]), call("done", ["summary": "Asked.", "evidence": []])])
        let loop = fakeLoop(fake)
        _ = await loop.run(goal: "send it")
        #expect(loop.phase == .waitingForOwner)
        #expect(loop.statusLine().contains("waiting for the owner's answer to: Which chat?"))
        #expect(loop.phase?.notchTitle(step: loop.step) == "Waiting for you")
        _ = await loop.resume(answer: "the self chat", words: "send it the self chat")
        #expect(loop.transitions.map(\.phase) == [.planning, .acting, .waitingForOwner, .planning, .acting, .done])
        #expect(loop.illegalTransitions == 0)
    }

    @Test func aCardIsItsOwnPhaseAndTheNotchSaysSo() async {
        let fake = Fake([call("press_element", ["name": "Send"]), call("done", ["summary": "Tried.", "evidence": [1]])])
        fake.cardOnCall = "press_element"
        let loop = fakeLoop(fake)
        _ = await loop.run(goal: "press send")
        #expect(loop.transitions.map(\.phase) == [.planning, .acting, .waitingForCard, .acting, .planning, .acting, .done])
        #expect(loop.illegalTransitions == 0)
        #expect(AgentTaskPhase.waitingForCard.notchTitle(step: 2) == "Needs your approval")
        #expect(AgentTaskPhase.acting.notchTitle(step: 3) == "Doing \u{00B7} 3")
        #expect(AgentTaskPhase.done.notchTitle(step: 3) == nil)
    }

    // The session moves a new task to planning before step 1 exists: the notch must still count step 1.
    @Test func aStepChangeWithinPlanningIsAnnounced() async {
        let fake = Fake([call("done", ["summary": "Nothing to do.", "evidence": []])])
        let loop = fakeLoop(fake)
        loop.move(to: .planning)
        _ = await loop.run(goal: "g")
        #expect(fake.phases.map { "\($0.0.rawValue)\($0.1)" }.prefix(3) == ["planning0", "planning1", "acting1"])
        #expect(loop.transitions.map(\.phase) == [.planning, .acting, .done])
    }

    @Test func capsEndInTheirOwnPhase() async {
        let fake = Fake([call("scroll", ["direction": "down"])])
        let loop = fakeLoop(fake)
        #expect(await loop.run(goal: "keep scrolling") == .stepCap)
        #expect(loop.phase == .failed)
        #expect(AgentTaskPhase.ended(.timeCap) == .timedOut)
        #expect(loop.illegalTransitions == 0)
    }

    // The owner's stop word: cancelled at once, before the run notices; the status says stopped.
    @Test func cancelIsImmediateAndLaterMovesAreRefused() async {
        let fake = Fake([call("ask_owner", ["question": "Q?"])])
        let loop = fakeLoop(fake)
        _ = await loop.run(goal: "g")
        loop.cancel()
        #expect(loop.phase == .cancelled)
        #expect(loop.statusLine().contains("the owner said to stop"))
        #expect(await loop.resume(answer: "a", words: "g a") != .done(summary: ""))
        #expect(loop.phase == .cancelled)
    }

    @Test func theStatusLineReadsThePhase() {
        let running = AgentLoop.statusLine(goal: "g", phase: .acting, step: 2, receipts: [], artifacts: [])
        #expect(running.contains("state: running"))
        let card = AgentLoop.statusLine(goal: "g", phase: .waitingForCard, step: 2, receipts: [], artifacts: [])
        #expect(card.contains("card"))
        let interrupted = AgentLoop.statusLine(goal: "g", phase: .interrupted, step: 4, receipts: [], artifacts: [])
        #expect(interrupted.contains("interrupted"))
        #expect(AgentLoop.statusLine(goal: "g", phase: .failed, step: 3, receipts: [], artifacts: [], outcome: .failed(reason: "no link"))
            .contains("did not finish (failed): no link"))
        #expect(AgentLoop.statusLine(goal: "g", phase: .done, step: 3, receipts: [], artifacts: [], outcome: .done(summary: "Made it."))
            .contains("done: Made it."))
    }
}
