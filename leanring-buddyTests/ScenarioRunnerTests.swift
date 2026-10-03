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
}
