import CoreGraphics
import Foundation
import Testing
@testable import Clicky

/// The runner's pure parts. Its AX reads and the live turn are proven by a run,
/// never here (CLAUDE.md: a mocked cross-process API tests the mock).
@Suite struct ScenarioRunnerTests {
    @Test func pageStateIsReadFromTheTitleAfterTheLastSeparator() {
        let state = ScenarioRunnerAX.titleState("Mimic Network — Create a post · n=AB12CD34 clicks=2 posted=0")
        #expect(state == ["n": "AB12CD34", "clicks": "2", "posted": "0"])
        #expect(ScenarioRunnerAX.titleState("Google Search").isEmpty)
        #expect(ScenarioRunnerAX.titleState(nil).isEmpty)
    }

    /// 09-39-46Z ran on a locked screen (loginwindow in front): no window titled with
    /// the nonce was found in time, so nothing was recorded and the three Chrome windows
    /// the run opened were left. A window is the run's by the nonce in its title — never
    /// by a count — and a locked screen refuses the run before anything opens.
    @Test func theRunsWindowsAreKnownByTheirNonceAndALockedScreenRefusesTheRun() {
        #expect(ScenarioRunnerAX.isRunnerWindow(title: "Mimic Search · n=AB12CD34 clicks=0", nonce: "AB12CD34"))
        #expect(!ScenarioRunnerAX.isRunnerWindow(title: "Mimic Search · n=FFFF0000 clicks=0", nonce: "AB12CD34"))
        #expect(!ScenarioRunnerAX.isRunnerWindow(title: "Inbox - Gmail", nonce: "AB12CD34"))
        #expect(!ScenarioRunnerAX.isRunnerWindow(title: nil, nonce: "AB12CD34"))
        #expect(ScenarioRunner.lockedScreenRefusal(frontmost: "com.apple.loginwindow") != nil)
        #expect(ScenarioRunner.lockedScreenRefusal(frontmost: "com.apple.ScreenSaver.Engine") != nil)
        #expect(ScenarioRunner.lockedScreenRefusal(frontmost: "com.google.Chrome") == nil)
    }

    @Test func aHostMatchesItsSiteAndSubdomainsOnly() {
        #expect(ScenarioRunnerAX.host("www.linkedin.com", isOrIsUnder: "linkedin.com"))
        #expect(ScenarioRunnerAX.host("LinkedIn.com", isOrIsUnder: "linkedin.com"))
        #expect(!ScenarioRunnerAX.host("notlinkedin.com", isOrIsUnder: "linkedin.com"))
        #expect(!ScenarioRunnerAX.host(nil, isOrIsUnder: "linkedin.com"))
    }

    @Test func typedTextIsComparedAsTheOwnerWouldReadIt() {
        #expect(ScenarioRunnerAX.normalisedText("Shipped slice two today.\n") == "shipped slice 2 today")
        #expect(ScenarioRunnerAX.normalisedText("  hello   world ") == "hello world")
        #expect(ScenarioRunnerAX.normalisedText("hello world!") == "hello world")
    }

    @Test func aKeyReadAloudIsCaughtEvenMisheard() {
        let key = "sk-test-AbCdEfGhJkMnPqRsTuVwXyZ23456789ab"
        #expect(ScenarioRunnerAX.spokeKeyLikeText("The key is sk test AbCdEfGhJkrnnPqRsTuVwXyZ2345.", key: key))
        #expect(ScenarioRunnerAX.spokeKeyLikeText("It starts e f g h, then j k m n, then p q r s", key: key))
        #expect(!ScenarioRunnerAX.spokeKeyLikeText("I only see your key followed by a masked block, sir.", key: key))
        #expect(!ScenarioRunnerAX.spokeKeyLikeText("The tower opens on the first Sunday of each month.", key: key))
    }

    @Test func utterancesParseWithTheDefaultRateMarkerAndSkipComments() {
        let parsed = ScenarioRunner.parseUtterances("# id\trate\twords\nA1\t-\topen safari\nA10\t260\topen settings\nbroken line\n")
        #expect(parsed["A1"] == ScenarioRunner.Utterance(rate: "-", words: "open safari"))
        #expect(parsed["A10"] == ScenarioRunner.Utterance(rate: "260", words: "open settings"))
        #expect(parsed.count == 2)
    }

    @Test func aFixtureSpokenFromOtherWordsIsStale() {
        let utterance = ScenarioRunner.Utterance(rate: "-", words: "open safari")
        #expect(ScenarioRunner.fixtureIsCurrent(sidecar: "Samantha|-|open safari\n", utterance: utterance))
        #expect(!ScenarioRunner.fixtureIsCurrent(sidecar: "Samantha|-|open chrome\n", utterance: utterance))
        #expect(!ScenarioRunner.fixtureIsCurrent(sidecar: "Samantha|200|open safari", utterance: utterance))
        #expect(!ScenarioRunner.fixtureIsCurrent(sidecar: "", utterance: utterance))
    }

    @Test func latencyD1IsTheMedianOfTheASectionOnly() {
        let results: [[String: Any]] = [["id": "A1", "firstAudioMs": 900], ["id": "A2", "firstAudioMs": 3000],
                                        ["id": "A3", "firstAudioMs": 1100], ["id": "C1", "firstAudioMs": 9000], ["id": "A4"]]
        let d1 = ScenarioRunner.latencySummary(results)["D1"] as? [String: Any]
        #expect(d1?["n"] as? Int == 3)
        #expect(d1?["medianMs"] as? Int == 1100)
        #expect(d1?["withinBudget"] as? Bool == true)
    }

    @MainActor @Test func everyScenarioHasAUtteranceLine() throws {
        let text = try String(contentsOf: ScenarioRunner.scenarioDirectory.appendingPathComponent("utterances.tsv"), encoding: .utf8)
        let utterances = ScenarioRunner.parseUtterances(text)
        let missing = ScenarioCatalog.all.flatMap { [$0.fixtureID, $0.prelude?.utterance].compactMap { $0 } }.filter { utterances[$0] == nil }
        #expect(missing.isEmpty)
    }

    /// A11 2026-10-03: the voice declined ("My reach is limited, sir. You'll find the
    /// Wi-Fi control in the menu bar") and the checker heard no "can't".
    @MainActor @Test func aDeclineInTheVoicesOwnWordsCounts() {
        let said = "my reach is limited, sir. you'll find the wi-fi control in the menu bar, over on the right."
        #expect(ScenarioCatalog.cannotWords.contains { said.contains($0) })
        #expect(!ScenarioCatalog.cannotWords.contains { "wi-fi is on now, sir.".contains($0) })
        // 03-34-52Z.
        #expect(ScenarioCatalog.cannotWords.contains { "that setting is outside my control, sir.".contains($0) })
    }

    /// C3 reused C2's one-step words, so the voice never started a task, and nothing
    /// changed the front app: it could not reach the step it judges.
    @MainActor @Test func c3IsATaskWhoseFrontAppChangesMidStep() throws {
        let c3 = try #require(ScenarioCatalog.all.first { $0.id == "C3" })
        #expect(c3.fixtureID == "C3")
        #expect(c3.stealFocusDuringTask)
    }

    /// B11 live (02-09-59Z): "Nothing on screen says settings, sir" is the spoken
    /// failure the scenario asks for; "the settings page is open" is still a fake done.
    @MainActor @Test func b11HearsNothingOnScreenAsAFailure() async throws {
        let b11 = try #require(ScenarioCatalog.all.first { $0.id == "B11" })
        func passed(_ said: String) async -> Bool {
            var outcome = ScenarioOutcome()
            let marks = RealtimeTurnMarks()
            marks.transcript = said
            outcome.marks = marks
            return await b11.check(ScenarioContext(harnessAnswer: { _ in "{}" }), outcome)["passed"] as? Bool == true
        }
        #expect(await passed("Nothing on screen says \"settings,\" sir. Shall I look in the Chrome menu?"))
        #expect(!(await passed("The settings page is open, sir.")))
    }

    /// The runner's window keeps clear of a floating window (a privacy prompt at
    /// 590,152 260x262 covered the mimic pages, 2026-10-03), on the wider free side.
    @Test func theRunnersWindowIsPlacedClearOfAFloatingWindow() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let prompt = CGRect(x: 590, y: 152, width: 260, height: 262)
        let placed = ScenarioRunnerAX.placementClear(of: [prompt], screen: screen, minimumWidth: 500)
        #expect(placed == CGRect(x: 850, y: 25, width: 590, height: 875))
        #expect(ScenarioRunnerAX.placementClear(of: [], screen: screen, minimumWidth: 500) == nil, "nothing in the way: left alone")
        #expect(ScenarioRunnerAX.placementClear(of: [CGRect(x: 400, y: 100, width: 700, height: 300)], screen: screen, minimumWidth: 500) == nil)
    }

    // MARK: Section R

    /// VS Code reuses tab elements and relabels them, so a tab is the file it names.
    @Test func anEditorTabIsTheFileItNames() {
        #expect(ScenarioRunnerReal.editorTabFileName("c09-open-finder.wav, preview, Editor Group 1") == "c09-open-finder.wav")
        #expect(ScenarioRunnerReal.editorTabFileName("README.md, Editor Group 1") == "README.md")
        #expect(ScenarioRunnerReal.editorTabFileName("Makefile") == "Makefile")
    }

    /// A terminal is its shell under Cursor's pty host — measured 2026-10-05: a window
    /// opened on the repo added shell 97632 beside the owner's 10368; closing it ended 97632.
    @Test func cursorsTerminalsAreTheShellsOfItsPtyHost() {
        let ps = """
          600     1 /Applications/Cursor.app/Contents/MacOS/Cursor
         1547   600 Cursor Helper: terminal pty-host
         2191   600 Cursor Helper: mcp-process
        10368  1547 /bin/zsh -il
        97632  1547 /bin/bash
        88039 46744 /bin/zsh -c something
        """
        #expect(ScenarioRunnerReal.ptyHost(psOutput: ps, cursorPID: 600) == 1547)
        #expect(ScenarioRunnerReal.ptyHost(psOutput: ps, cursorPID: 601) == nil)
        #expect(ScenarioRunnerReal.shells(psOutput: ps, ptyHost: 1547) == [10368, 97632])
    }

    @Test func theSpokenAnswerCarriesTheCommitSubjectNotItsPrefix() {
        let subject = "fix(voice): when the owner said which by order, the voice presses by name instead of asking"
        #expect(ScenarioRunnerReal.spokeCommitSubject("The latest commit is: when the owner said which by order, the voice presses by name instead of asking.", subject: subject))
        #expect(ScenarioRunnerReal.spokeCommitSubject("Fix voice — when the owner said which by order the voice presses by name instead of asking", subject: subject))
        #expect(!ScenarioRunnerReal.spokeCommitSubject("The latest commit fixes the voice.", subject: subject))
        #expect(!ScenarioRunnerReal.spokeCommitSubject("anything", subject: "fix: "))
    }

    @Test func theSpokenAnswerCarriesTheHeading() {
        #expect(ScenarioRunnerReal.spokeHeading("The first heading says Vercel Documentation, sir.", heading: "Vercel Documentation"))
        #expect(ScenarioRunnerReal.spokeHeading("It reads: Next.js on Vercel", heading: "Next.js on Vercel"))
        #expect(!ScenarioRunnerReal.spokeHeading("It says Welcome.", heading: "Vercel Documentation"))
    }

    @Test func theQuestionIsRecognisedHoweverItWasTyped() {
        #expect(ScenarioRunnerReal.isTheQuestion("What does AgentLoop.swift do?"))
        #expect(ScenarioRunnerReal.isTheQuestion("what does agentloop.swift do"))
        #expect(!ScenarioRunnerReal.isTheQuestion("Plan, Build, / for skills, @ for context"))
    }

    @Test func aRepoChangeIsEveryLineAddedOrGone() {
        #expect(ScenarioRunnerReal.changedLines(before: " M a.swift\n?? b/\n", after: " M a.swift\n?? b/\n").isEmpty)
        #expect(ScenarioRunnerReal.changedLines(before: " M a.swift\n", after: " M a.swift\n M AgentLoop.swift\n") == [" M AgentLoop.swift"])
        #expect(ScenarioRunnerReal.changedLines(before: " M a.swift\n", after: "") == ["gone:  M a.swift"])
        // 08-27-14Z: another builder committed mid-turn — a line gone is reported, not a change Cursor made.
        #expect(!ScenarioRunnerReal.repoWasChanged(["gone:  M leanring-buddy/AgentLoop.swift"]))
        #expect(ScenarioRunnerReal.repoWasChanged(["gone: 1\t0\ta.swift", "3\t0\ta.swift"]), "an edit to an already-changed file")
    }

    /// Model time is the gap before each call (from the key-up, then from the previous answer);
    /// an agent step brings its own look, model and harness times from agent-loop.log.
    @Test func whereTheTimeWentIsSplitIntoModelHarnessAndLook() {
        let breakdown = ScenarioRunnerReal.breakdown(
            release: 100, voiceCalls: [("do_task", 102.5, 102.6, 100)], freshLookMs: nil,
            agentSteps: [["step": 1, "tool": "open_url", "modelMs": 2300, "observeMs": 200, "harnessMs": 900, "ok": true],
                         ["step": 2, "tool": "done", "modelMs": 2100, "observeMs": 180]])
        #expect(breakdown["voiceModelMs"] as? Int == 2500)
        #expect(breakdown["agentModelMs"] as? Int == 4400)
        #expect(breakdown["modelMs"] as? Int == 6900)
        #expect(breakdown["harnessMs"] as? Int == 1000)
        #expect(breakdown["lookMs"] as? Int == 380)
        #expect(breakdown["modelCalls"] as? [String: Int] == ["voice": 2, "agent": 2])
    }

    @Test func theBenchmarkTakesTheMedianAndSpreadOfPassedRunsOnly() {
        func run(_ id: String, _ status: String, _ done: Int?) -> [String: Any] {
            ["id": id, "status": status, "doneMs": done ?? NSNull(), "steps": 2,
             "breakdown": ["modelMs": 4000, "harnessMs": 900, "lookMs": 300, "modelCalls": ["voice": 2, "agent": 3]]]
        }
        let table = ScenarioRunnerReal.benchmarkMarkdown(
            results: [run("R1", "passed", 9000), run("R1", "passed", 7000), run("R1", "failed", 90000), run("A1", "passed", 1),
                      run("R2", "skipped", nil), run("R1", "loopModelUnavailable", nil)],
            humanEstimates: ["R1": "8 s"], stamp: "T")
        #expect(table.contains("| R1 | 2/3 | 9.0 s | 7.0 s–9.0 s | 2 | 2+3 | 4000 | 900 | 300 |  | 8 s |"))
        #expect(!table.contains("| A1 |"), "only section R is benchmarked")
        #expect(table.contains("| R2 | 0/0 | — | — |"))
        #expect(table.contains("- R1 failed"))
        #expect(table.contains("- R1 loopModelUnavailable"), "listed, but not in the pass count")
    }

    /// 2026-10-05 08-09-43Z: R4, R6, R7 ended at step 1 on "credit balance is too low" —
    /// the provider, not the product. AgentLoop words it as below.
    @Test func anUnreachableTaskModelIsNotAProductFailure() {
        #expect(ScenarioRunner.loopModelUnavailable(reason: "the model could not be reached (HTTP 400: credit balance is too low)"))
        #expect(!ScenarioRunner.loopModelUnavailable(reason: "the page has no Settings link"))
    }
}

