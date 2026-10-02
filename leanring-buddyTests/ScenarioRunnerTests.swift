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
}
