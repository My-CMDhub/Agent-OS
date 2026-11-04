//
//  WorkerSyncTests.swift
//  The pure half of the voice and the task in step: the status table, what waits to be said, the words the
//  owner must never hear, and the watchdog's bounds. The sockets are proven live by `--sync-probe`.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct WorkerStatusTests {
    private func status(_ outcome: AgentLoop.Outcome) -> WorkerStatus {
        WorkerStatus.forOutcome(outcome, lastProgress: "opened Safari")
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
            #expect(!status(ending).plain.isEmpty)
        }
    }

    /// Honest: what could not be confirmed is said as that, in both voices, never as done or failed.
    @Test func unconfirmedIsSaidAsUnconfirmed() {
        let unconfirmed = status(.unconfirmed(summary: "The file is moved.", challenge: "no read showed it"))
        #expect(unconfirmed.plain.lowercased().contains("couldn't confirm"))
    }

    @Test func aFailureNeverNamesAModel() {
        let reachability = status(.failed(reason: "the model could not be reached (timeout)"))
        #expect(!reachability.plain.lowercased().contains("model"))
        #expect(AgentLoop.spokenReason("the page would not load") == "the page would not load")
    }
}

struct WorkerStatusQueueTests {
    private func progress(_ line: String) -> WorkerStatus { .progress(line) }
    private let done = WorkerStatus(kind: .done, plain: "done")
    private let failed = WorkerStatus(kind: .failed, plain: "failed")

    @Test func theLatestProgressWinsWhileItWaits() {
        var queue = WorkerStatusQueue()
        queue.add(progress("one"))
        queue.add(progress("two"))
        queue.add(.retrying)
        queue.add(progress("three"))
        #expect(queue.waiting == [progress("three")])
    }

    @Test func anEndReplacesProgressAndIsNeverDropped() {
        var queue = WorkerStatusQueue()
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
        var queue = WorkerStatusQueue()
        queue.add(.modelFallback)
        queue.add(WorkerStatus(kind: .cancelled, plain: "x", speaks: false))
        #expect(queue.waiting.isEmpty)
    }

    @Test func dropTransientKeepsAnEnd() {
        var queue = WorkerStatusQueue()
        queue.add(.stuck(lastProgress: nil))
        queue.dropTransient()
        #expect(queue.waiting.isEmpty)
        queue.add(done)
        queue.dropTransient()
        #expect(queue.waiting == [done])
    }

    @Test func progressIsForLongTasksAndNotOften() {
        #expect(!WorkerStatusQueue.admitsProgress(now: 12.9, started: 0, lastSpoken: nil))
        #expect(WorkerStatusQueue.admitsProgress(now: 13, started: 0, lastSpoken: nil))
        #expect(!WorkerStatusQueue.admitsProgress(now: 20, started: 0, lastSpoken: 13))
        #expect(WorkerStatusQueue.admitsProgress(now: 28, started: 0, lastSpoken: 13))
    }
}

struct WorkerWatchdogTests {
    @Test func quietIsSaidOnceThenStopped() {
        #expect(WorkerWatchdog.step(quietSeconds: 19.9, waiting: false, alreadySaid: false) == .none)
        #expect(WorkerWatchdog.step(quietSeconds: 20, waiting: false, alreadySaid: false) == .say)
        #expect(WorkerWatchdog.step(quietSeconds: 60, waiting: false, alreadySaid: true) == .none)
        #expect(WorkerWatchdog.step(quietSeconds: 90, waiting: false, alreadySaid: true) == .cancel)
    }

    @Test func waitingOnTheOwnerIsNotQuiet() {
        #expect(WorkerWatchdog.step(quietSeconds: 500, waiting: true, alreadySaid: false) == .none)
    }

    /// The bound sits where its evidence says: past a model call's own timeout, so the fallback gets its try first.
    @Test func theBoundsOrderAsMeasured() {
        #expect(WorkerWatchdog.sayAfterSeconds > 17.5)
        #expect(WorkerWatchdog.cancelAfterSeconds > 75.4)
        #expect(WorkerWatchdog.cancelAfterSeconds > 60)
    }
}

@MainActor
struct OneVoiceTests {
    @Test func theWordsAreCaught() {
        #expect(OneVoiceWords.namedHandOff(in: "I'm with the task runner now.") == ["task runner"])
        #expect(OneVoiceWords.namedHandOff(in: "Handing over to the background agent.").contains("handing over"))
        #expect(OneVoiceWords.namedHandOff(in: "Handing over to the background agent.").contains("background"))
        #expect(OneVoiceWords.namedHandOff(in: "Haiku is on it.") == ["haiku"])
        #expect(OneVoiceWords.namedHandOff(in: "Calculator is open, sir.").isEmpty)
        #expect(OneVoiceWords.namedHandOff(in: "An agenda and a backgrounder.").isEmpty)
    }

    @Test func theOwnersOwnWordIsTheirs() {
        #expect(OneVoiceWords.namedHandOff(in: "The agent panel is open.", ownerWords: "open the agent panel").isEmpty)
    }

    /// Every template the owner can hear, whichever stack says it.
    @Test func noTemplateNamesAHandOff() {
        var lines = [AgentLoop.narrationLine("opened Safari"), AgentLoop.stoppedContextLine(step: 2), RealtimeVoiceConnection.handedToTaskRefusal.message,
                     WorkerStatus.retrying.plain, WorkerStatus.unheard.plain, WorkerStatus.stuck(lastProgress: nil).plain,
                     WorkerStatus.stalledOut(lastProgress: "x").plain, WorkerStatus.progress(nil).plain, WorkerStatus.progress("opened Safari").plain]
        let endings: [AgentLoop.Outcome] = [.done(summary: "x"), .askOwner(question: "x"), .failed(reason: "the model could not be reached (error)"),
                                            .unconfirmed(summary: "x", challenge: "y"), .stepCap(), .timeCap, .refusals(error: "x")]
        for ending in endings { lines.append(WorkerStatus.forOutcome(ending, lastProgress: "p").plain) }
        for line in lines { #expect(OneVoiceWords.namedHandOff(in: line).isEmpty, "\(line)") }
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
struct OneVoiceScenarioRuleTests {
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

struct SettingsWordsTests {
    @Test func openSettingsNamesTheMacsAndNoSitesDoes() {
        func spoken(_ text: String) -> [String] { RealtimeVoiceVerbs.foldedTokens(text) }
        #expect(RealtimeHeardCheck.saysOnlySettings(spoken("open settings")))
        #expect(RealtimeHeardCheck.saysOnlySettings(spoken("uh could you open settings, please")))
        #expect(!RealtimeHeardCheck.saysOnlySettings(spoken("open the settings")))
        #expect(!RealtimeHeardCheck.saysOnlySettings(spoken("open the settings page on this site")))
        #expect(!RealtimeHeardCheck.saysOnlySettings(spoken("change this site's settings")))
    }
}

struct ClosedClaimTests {
    @Test func aCloseDoneByPressingIsBacked() {
        func decision(_ call: RealtimeToolCall) -> RealtimeToolDecision {
            var decision = RealtimeToolDecision(call: call, callUptime: 0)
            decision.dispatch = RealtimeToolDispatch(result: ["ok": true], harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: ["ok": true])
            return decision
        }
        func standing(_ call: RealtimeToolCall) -> Bool {
            ScenarioRunner.claimLeftStanding(transcript: "I have closed the tab.", decisions: [decision(call)], pointed: false, corrected: false)
        }
        #expect(!standing(RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.pressMenuName, appName: "Safari", path: ["File", "Close Tab"])))
        #expect(!standing(RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.pressKeysName, appName: "Safari", shortcut: "cmd+w")))
        // A press of something else backs no close: this is what the first version of this rule let through.
        #expect(standing(RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.pressElementName, appName: "Safari", elementName: "Sign In")))
        #expect(standing(RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.findOnScreenName, appName: "Safari")))
    }
}

struct ReplacesRunningTaskTests {
    @Test func aContradictionCallsTheTaskOff() {
        for words in ["no, open chrome instead", "Actually open notes", "uh no, the other one"] { #expect(RealtimeVoiceSession.replacesRunningTask(words), "\(words)") }
        for words in ["open the calculator", "and then open notes", "is it done"] { #expect(!RealtimeVoiceSession.replacesRunningTask(words), "\(words)") }
    }
}

@MainActor
struct StackRetiredTests {
    /// A stored J.A.R.V.I.S. stack (Gemini's voice over the worker) lands on the default; no case of it is left to pick.
    @Test func aStoredFrontStackBecomesTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "StackRetiredTests-\(UUID().uuidString)"))
        defaults.set("frontAndWorker", forKey: VoiceStackChoice.defaultsKey)
        #expect(VoiceStackChoice.stored(in: defaults) == VoiceStackChoice.defaultChoice)
        #expect(VoiceStackChoice.allCases == [.openAIRealtime, .geminiLive, .cascade])
    }

    /// Gemini stored and never chosen was the old default: moved once. Chosen from the menu after that, it stands, and so does a choice made before the move.
    @Test func theOldDefaultMovesOnceAndAChoiceStands() throws {
        let defaults = try #require(UserDefaults(suiteName: "StackRetiredTests-\(UUID().uuidString)"))
        defaults.set("geminiLive", forKey: VoiceStackChoice.defaultsKey)
        #expect(VoiceStackChoice.stored(in: defaults) == .cascade)
        #expect(defaults.string(forKey: VoiceStackChoice.defaultsKey) == "cascade")
        VoiceStackChoice.geminiLive.store(in: defaults)
        #expect(VoiceStackChoice.stored(in: defaults) == .geminiLive)
        #expect(VoiceStackChoice.stored(in: defaults) == .geminiLive)

        let openAI = try #require(UserDefaults(suiteName: "StackRetiredTests-\(UUID().uuidString)"))
        openAI.set("openAIRealtime", forKey: VoiceStackChoice.defaultsKey)
        #expect(VoiceStackChoice.stored(in: openAI) == .openAIRealtime)
    }
}
