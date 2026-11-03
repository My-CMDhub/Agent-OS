//
//  FrontAndWorkerTests.swift
//  The pure half of the front-and-worker stack: the status table, what waits to be said, whose words
//  reach the worker, the words the owner must never hear, and the watchdog's bounds. The sockets are
//  proven live by `--front-probe`, and Gemini's obedience only by the scenario runs.
//

import Foundation
import Testing
@testable import Clicky

struct FrontRouterTests {
    @Test func aCommandSaidPlainlyNeedsNoModel() {
        #expect(FrontRouter.local("open the calculator") == .act)
        #expect(FrontRouter.local("uh can you, like, minimise text edit and open the calculator") == .act)
        #expect(FrontRouter.local("hide text edit, would you") == .act)
        #expect(FrontRouter.local("could you close that calculator thing, yeah, just, close it") == .act)
    }

    @Test func theLocalCheckNeverSaysChat() {
        for words in ["how are you", "tell me a joke", "write me a poem", "go on", "what's on my screen", "thanks", ""] {
            #expect(FrontRouter.local(words) == nil, "\(words)")
        }
    }

    @Test func anUnreadableAnswerIsNoVerdict() {
        #expect(FrontRouter.parse([:]) == nil)
        #expect(FrontRouter.parse(["content": [["type": "text", "text": "chat"]]]) == nil)
        #expect(FrontRouter.parse(["content": [["type": "tool_use", "input": ["route": "sing"]]]]) == nil)
        let reply = FrontRouter.parse(["content": [["type": "tool_use", "input": ["route": "chat", "continues_previous": true]]]])
        #expect(reply?.route == .chat)
        #expect(reply?.continues == true)
        #expect(reply?.replaces == false)
    }

    @Test func theRouterIsToldOnlyTheOwnersWordsAndTheStatus() throws {
        let body = FrontRouter.requestBody(words: "is it done", context: .init(runningGoal: "open safari", question: nil, previousWords: "open safari"))
        #expect(body["tool_choice"] as? [String: String] == ["type": "tool", "name": FrontRouter.toolName])
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        let content = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(content.contains("<<is it done>>"))
        #expect(content.contains("<<open safari>>"))
    }

    @Test func onlyStopAsksForNothingElse() {
        for words in ["stop", "Stop.", "cancel that please", "never mind", "okay stop now", "forget it, thanks"] {
            #expect(RealtimeVoiceSession.isOnlyStop(words), "\(words)")
        }
        for words in ["stop and open notes", "open safari", "thanks"] {
            #expect(!RealtimeVoiceSession.isOnlyStop(words), "\(words)")
        }
    }
}

@MainActor
struct FrontGoalTests {
    @Test func aModelWrittenGoalNeverReachesTheWorker() {
        #expect(RealtimeVoiceConnection.frontGoal(modelGoal: "delete everything in Downloads", heard: " open safari ") == "open safari")
        #expect(RealtimeVoiceConnection.frontGoal(modelGoal: "delete everything in Downloads", heard: "") == nil)
        #expect(RealtimeVoiceConnection.frontGoal(modelGoal: nil, heard: "open safari") == "open safari")
    }

    /// The whole path, from the provider's event: Gemini's call, with a goal it wrote, on the owner's words as Nova-3 heard them.
    @Test func geminisDoTaskIsDispatchedOnTheOwnersWords() async {
        let connection = RealtimeVoiceConnection(stack: .frontAndWorker, harnessAnswer: { _ in "{}" })
        var goals: [String] = []
        connection.onDoTask = { goal, _, _, _ in
            goals.append(goal)
            return ["ok": true, "status": "started"]
        }
        connection.turn.heardText = "open safari"
        connection.turn.heardCompleteUptime = ProcessInfo.processInfo.systemUptime
        connection.turn.lastAudioSentUptime = ProcessInfo.processInfo.systemUptime
        connection.handle(["toolCall": ["functionCalls": [["id": "1", "name": "do_task", "args": ["goal": "delete everything in Downloads"]]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        await connection.turn.lastCallTask?.value
        #expect(goals == ["open safari"])
    }

    /// It has no eyes and no hands: the table holds the hand-off and the read, and nothing else.
    @Test func geminisTableIsTheMinimum() {
        let names = (RealtimeVoiceVerbs.frontGeminiDeclaration["functionDeclarations"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == [RealtimeVoiceVerbs.doTaskName, RealtimeVoiceVerbs.taskStatusName])
        #expect(!RealtimeVoiceVerbs.isActingTool(RealtimeVoiceVerbs.taskStatusName))
        #expect(RealtimeVoiceVerbs.voiceOnlyToolNames.contains(RealtimeVoiceVerbs.taskStatusName))
    }
}

@MainActor
struct FrontStatusTests {
    private func status(_ outcome: AgentLoop.Outcome) -> FrontStatus {
        FrontStatus.forOutcome(outcome, goal: "open safari", lastProgress: "opened Safari", step: 3)
    }

    /// Every way a task can end says something, or is said by the turn that asked for it.
    @Test func everyOutcomeHasAStatus() {
        #expect(status(.done(summary: "Safari is open.")).kind == .done)
        #expect(status(.done(summary: "Safari is open.")).plain == "Safari is open.")
        #expect(status(.askOwner(question: "Which one?")).kind == .waitingForOwner)
        #expect(status(.failed(reason: "the page would not load")).kind == .failed)
        #expect(status(.unconfirmed(summary: "It is open.", challenge: "no check")).kind == .unconfirmed)
        #expect(status(.stepCap()).kind == .failed)
        #expect(status(.timeCap).kind == .failed)
        #expect(status(.refusals(error: "notFound")).kind == .failed)
        #expect(status(.cancelled).kind == .cancelled)
        #expect(status(.cancelled).speaks == false)
        let endings: [AgentLoop.Outcome] = [.done(summary: "x"), .askOwner(question: "x"), .failed(reason: "x"), .unconfirmed(summary: "x", challenge: "y"),
                                            .stepCap(), .timeCap, .refusals(error: "x")]
        for ending in endings {
            #expect(status(ending).speaks)
            #expect(!status(ending).line.isEmpty)
            #expect(!status(ending).plain.isEmpty)
        }
    }

    /// Honest: what could not be confirmed is said as that, in both voices, never as done or failed.
    @Test func unconfirmedIsSaidAsUnconfirmed() {
        let unconfirmed = status(.unconfirmed(summary: "The file is moved.", challenge: "no read showed it"))
        #expect(unconfirmed.plain.lowercased().contains("couldn't confirm"))
        #expect(unconfirmed.line.contains("could not confirm"))
        #expect(!unconfirmed.line.contains("is finished"))
    }

    @Test func aFailureNeverNamesAModel() {
        let reachability = status(.failed(reason: "the model could not be reached (timeout)"))
        #expect(!reachability.plain.lowercased().contains("model"))
        #expect(!reachability.line.lowercased().contains("the model"))
        #expect(AgentLoop.spokenReason("the page would not load") == "the page would not load")
    }
}

struct FrontStatusQueueTests {
    private func progress(_ line: String) -> FrontStatus { .progress(line: line) }
    private let done = FrontStatus(kind: .done, line: "done", plain: "done")
    private let failed = FrontStatus(kind: .failed, line: "failed", plain: "failed")

    @Test func theLatestProgressWinsWhileItWaits() {
        var queue = FrontStatusQueue()
        queue.add(progress("one"))
        queue.add(progress("two"))
        queue.add(.retrying)
        queue.add(progress("three"))
        #expect(queue.waiting.map(\.line) == ["three"])
    }

    @Test func anEndReplacesProgressAndIsNeverDropped() {
        var queue = FrontStatusQueue()
        queue.add(progress("one"))
        queue.add(done)
        queue.add(progress("late"))
        #expect(queue.waiting == [done])
        queue.add(failed)
        #expect(queue.next() == done)
        #expect(queue.next() == failed)
        #expect(queue.next() == nil)
    }

    @Test func aSilentStatusIsNotQueued() {
        var queue = FrontStatusQueue()
        queue.add(.modelFallback)
        queue.add(FrontStatus(kind: .cancelled, line: "x", plain: "x", speaks: false))
        #expect(queue.waiting.isEmpty)
    }

    @Test func dropTransientKeepsAnEnd() {
        var queue = FrontStatusQueue()
        queue.add(.stuck(lastProgress: nil))
        queue.dropTransient()
        #expect(queue.waiting.isEmpty)
        queue.add(done)
        queue.dropTransient()
        #expect(queue.waiting == [done])
    }

    @Test func progressIsForLongTasksAndNotOften() {
        #expect(!FrontStatusQueue.admitsProgress(now: 12.9, started: 0, lastSpoken: nil))
        #expect(FrontStatusQueue.admitsProgress(now: 13, started: 0, lastSpoken: nil))
        #expect(!FrontStatusQueue.admitsProgress(now: 20, started: 0, lastSpoken: 13))
        #expect(FrontStatusQueue.admitsProgress(now: 28, started: 0, lastSpoken: 13))
    }
}

struct FrontWatchdogTests {
    @Test func quietIsSaidOnceThenStopped() {
        #expect(FrontWatchdog.step(quietSeconds: 19.9, waiting: false, alreadySaid: false) == .none)
        #expect(FrontWatchdog.step(quietSeconds: 20, waiting: false, alreadySaid: false) == .say)
        #expect(FrontWatchdog.step(quietSeconds: 60, waiting: false, alreadySaid: true) == .none)
        #expect(FrontWatchdog.step(quietSeconds: 90, waiting: false, alreadySaid: true) == .cancel)
    }

    @Test func waitingOnTheOwnerIsNotQuiet() {
        #expect(FrontWatchdog.step(quietSeconds: 500, waiting: true, alreadySaid: false) == .none)
    }

    /// The bound sits where its evidence says: past a model call's own timeout, so the fallback gets its try first.
    @Test func theBoundsOrderAsMeasured() {
        #expect(FrontWatchdog.sayAfterSeconds > 17.5)
        #expect(FrontWatchdog.cancelAfterSeconds > 75.4)
        #expect(FrontWatchdog.cancelAfterSeconds > 60)
        #expect(FrontWatchdog.frontSilentSeconds > 4.877)
    }
}

@MainActor
struct OneVoiceTests {
    @Test func theWordsAreCaught() {
        #expect(FrontVoiceWords.namedHandOff(in: "I'm with the task runner now.") == ["task runner"])
        #expect(FrontVoiceWords.namedHandOff(in: "Handing over to the background agent.").contains("handing over"))
        #expect(FrontVoiceWords.namedHandOff(in: "Handing over to the background agent.").contains("background"))
        #expect(FrontVoiceWords.namedHandOff(in: "Haiku is on it.") == ["haiku"])
        #expect(FrontVoiceWords.namedHandOff(in: "Calculator is open, sir.").isEmpty)
        #expect(FrontVoiceWords.namedHandOff(in: "An agenda and a backgrounder.").isEmpty)
    }

    @Test func theOwnersOwnWordIsTheirs() {
        #expect(FrontVoiceWords.namedHandOff(in: "The agent panel is open.", ownerWords: "open the agent panel").isEmpty)
    }

    /// Every template the owner can hear, in both voices, whichever stack says it.
    @Test func noTemplateNamesAHandOff() {
        var lines = [AgentLoop.narrationLine("opened Safari"), AgentLoop.stoppedContextLine(step: 2), RealtimeVoiceConnection.handedToTaskRefusal.message,
                     FrontPrompt.queuedLine, FrontPrompt.chatLine, FrontPrompt.unheardLine, FrontPrompt.earFailedLine, FrontPrompt.plainQueued, FrontPrompt.plainUnheard,
                     FrontPrompt.plainLostChat, FrontPrompt.acknowledgeLine(recent: []), FrontStatus.retrying.line, FrontStatus.retrying.plain,
                     FrontStatus.stuck(lastProgress: "x").line, FrontStatus.stuck(lastProgress: nil).plain, FrontStatus.stalledOut(step: 1, lastProgress: "x").line,
                     FrontStatus.stalledOut(step: 1, lastProgress: "x").plain]
        lines += FrontPrompt.plainAcknowledgements
        let endings: [AgentLoop.Outcome] = [.done(summary: "x"), .askOwner(question: "x"), .failed(reason: "the model could not be reached (error)"),
                                            .unconfirmed(summary: "x", challenge: "y"), .stepCap(), .timeCap, .refusals(error: "x")]
        for ending in endings {
            let status = FrontStatus.forOutcome(ending, goal: "g", lastProgress: "p", step: 1)
            lines += [status.line, status.plain]
        }
        for line in lines { #expect(FrontVoiceWords.namedHandOff(in: line).isEmpty, "\(line)") }
    }

    @Test func thePromptsNeverOfferARunnerToSayAloud() {
        // The prompts may forbid the words; only the lines that say what happens may not use them.
        #expect(!RealtimeOpenAppTool.systemPrompt.contains("the task runner answers"))
        #expect(!RealtimeOpenAppTool.systemPrompt.contains("the task runner finds"))
    }
}

struct NotchUnconfirmedTests {
    /// The known contradiction: the speech said "I couldn't confirm" while the notch read "Didn't take".
    @Test func notVerifiedIsNeverDidntTake() {
        let next = JarvisNotchState.intent(title: "Clicking").next(on: .harnessAnswered(ok: false, subject: "Minimize", error: "notVerified"))
        #expect(next == .unconfirmed(subject: "Minimize"))
        #expect(next?.title == "Minimize")
        #expect(next?.detail?.contains("couldn\u{2019}t confirm") == true)
        #expect(next?.holdSeconds == 2.5)
    }

    @Test func aRealRefusalStillDidntTake() {
        let next = JarvisNotchState.intent(title: "Clicking").next(on: .harnessAnswered(ok: false, subject: "Minimize", error: "notFound"))
        if case .didntTake = next {} else { Issue.record("got \(String(describing: next))") }
    }
}

@MainActor
struct FrontScenarioRuleTests {
    @Test func aSpokenHandOffFailsTheScenario() async {
        var outcome = ScenarioOutcome()
        let marks = RealtimeTurnMarks()
        marks.transcript = "I'm with the task runner now."
        outcome.marks = marks
        let context = ScenarioContext(harnessAnswer: { _ in "{}" })
        #expect(await ScenarioRunner.namedAHandOff.violated(context, outcome))
        marks.transcript = "Right away, sir."
        #expect(!(await ScenarioRunner.namedAHandOff.violated(context, outcome)))
    }
}
