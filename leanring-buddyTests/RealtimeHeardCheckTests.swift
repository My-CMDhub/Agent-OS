//
//  RealtimeHeardCheckTests.swift
//  leanring-buddyTests
//
//  The heard-vs-named check's pure half: which installed apps a transcript
//  names, the decision against the tool's app, the refusal the model is told,
//  the bounded wait for a late transcript, and the notch's words. Whether the
//  providers' transcription arrives, and when, is the probe's question.
//

import Foundation
import Testing
@testable import Clicky

struct RealtimeHeardCheckTests {

    private func app(_ path: String, _ name: String? = nil, file: Bool = true) -> RealtimeVoiceVerbs.AppName {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return RealtimeVoiceVerbs.AppName(name: name ?? url.deletingPathExtension().lastPathComponent, url: url, isFileName: file)
    }

    /// This Mac's shape (2026-09-25), with the common-word names that make matching hard.
    private var installed: [RealtimeVoiceVerbs.AppName] {
        [app("/Applications/Cursor.app"), app("/Applications/Visual Studio Code.app"), app("/Applications/Google Chrome.app"),
         app("/Applications/Xcode.app"), app("/Users/o/Applications/Claude Code URL Handler.app"), app("/Applications/Claude.app"),
         app("/System/Applications/TextEdit.app"), app("/System/Applications/System Settings.app"),
         app("/System/Applications/Font Book.app"), app("/System/Applications/Time Machine.app"),
         app("/System/Applications/Clock.app"), app("/System/Applications/App Store.app"),
         app("/System/Applications/Preview.app"), app("/System/Applications/Home.app"), app("/System/Applications/Photos.app"),
         app("/System/Applications/Notes.app"),
         app("/Applications/Visual Studio Code.app", "Code", file: false),
         app("/System/Library/CoreServices/Finder.app", "Finder", file: true)]
    }

    private func heard(_ transcript: String) -> [String] {
        RealtimeHeardCheck.appsMentioned(in: transcript, among: installed).apps.map(RealtimeVoiceVerbs.displayName)
    }

    // MARK: Transcript -> apps

    @Test func fullNamesAreHeardWordForWordOrRunTogether() {
        #expect(heard("Open a new window in Cursor.") == ["Cursor"])
        #expect(heard("Open system settings for me.") == ["System Settings"])
        #expect(heard("new text edit document") == ["TextEdit"])
        #expect(heard("Put Finder's toolbar path thing on.") == ["Finder"])
        #expect(heard("open visual studio code") == ["Visual Studio Code"])
        // A word fitting two apps is dropped when an app was named in full: "code" here.
        #expect(heard("Open a new window in the Cursor code editor.") == ["Cursor"])
        #expect(RealtimeHeardCheck.appsMentioned(in: "open cursor", among: installed).tier == .fullName)
        // "claude" is Claude's name and a word of Claude Code URL Handler's: the full name decides.
        #expect(heard("open claude") == ["Claude"])
    }

    @Test func aDistinctiveWordNamesItsAppAndASharedWordIsAmbiguous() {
        #expect(heard("Open a new window in Chrome.") == ["Google Chrome"])
        let code = RealtimeHeardCheck.appsMentioned(in: "Open a new window in code.", among: installed)
        #expect(code.ambiguousWord)
        #expect(code.tier == .word)
        #expect(code.apps.map(RealtimeVoiceVerbs.displayName) == ["Visual Studio Code", "Claude Code URL Handler"])
        // Never by letters: "code" is not Xcode.
        #expect(!code.apps.map(RealtimeVoiceVerbs.displayName).contains("Xcode"))
    }

    @Test func soundAlikesMapOnlyInTheAppSlot() {
        for said in ["open a new window in kasa", "Open a new window in Kaza.", "new window in kassa", "open casa"] {
            let result = RealtimeHeardCheck.appsMentioned(in: said, among: installed)
            #expect(result.apps.map(RealtimeVoiceVerbs.displayName) == ["Cursor"], "\(said)")
            #expect(result.tier == .soundAlike)
        }
        // What the transcription models actually heard for "cursor" (probe 9BC0CACB).
        for said in ["Open a new window in Cosa.", "Open a new window in Kursor.", "Open a new window in Cursa.", "Open a new window in Kusa."] {
            #expect(heard(said) == ["Cursor"], "\(said)")
        }
        // Beside an ambiguous word the sound-alike is one more candidate: ask, with Cursor offered.
        let editor = RealtimeHeardCheck.appsMentioned(in: "Open a new window in the Kasa code editor.", among: installed)
        #expect(editor.ambiguousWord)
        #expect(editor.apps.map(RealtimeVoiceVerbs.displayName) == ["Cursor", "Visual Studio Code", "Claude Code URL Handler"])
        #expect(RealtimeHeardCheck.soundKey("cursor") == "kasa")
        #expect(RealtimeHeardCheck.soundKey("Kaza") == RealtimeHeardCheck.soundKey("kassa"))
    }

    @Test func conservativeNegativesHearNoApp() {
        #expect(heard("What app am I looking at right now?") == [])
        #expect(heard("Switch to list view.") == [])
        #expect(heard("make the font bigger") == [], "font is Font Book's word and the Format menu's")
        #expect(heard("what time is it") == [])
        #expect(heard("just in case, show the sidebar") == [], "case keys like cursor, and is a stop word")
        #expect(heard("click the export button") == [], "click keys like clock, but is not in the app slot")
        #expect(heard("kasa is not an app here") == [], "a sound-alike outside the app slot")
        #expect(heard("open the app store") == ["App Store"], "a generic word still counts inside a full name")
        #expect(heard("") == [])
    }

    @Test func commonWordNamesCountOnlyWhereOnlyAnAppNameFits() {
        #expect(heard("show the preview pane in finder") == ["Finder"])
        #expect(heard("go home") == [])
        #expect(heard("take notes about the photos") == [])
        #expect(heard("switch to the numbers tab") == [])
        for (said, app) in [("open preview", "Preview"), ("Preview.", "Preview"), ("bring up photos", "Photos"),
                            ("switch to notes", "Notes"), ("go to home", "Home"), ("launch photos please", "Photos"), ("Home, please", "Home")] {
            let result = RealtimeHeardCheck.appsMentioned(in: said, among: installed)
            #expect(result.apps.map(RealtimeVoiceVerbs.displayName) == [app], "\(said)")
            #expect(result.tier == .slot, "\(said)")
        }
        // Never as a sound-alike or a word: "note" in the slot is not Notes.
        #expect(heard("open the note") == [])
    }

    // MARK: Decision

    @Test func theDecisionTable() {
        func outcome(_ transcript: String?, named: String) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: named, among: installed).outcome
        }
        #expect(outcome("open a new window in cursor", named: "Cursor") == .match)
        // D66FC598: the owner said Cursor, the model named VS Code.
        #expect(outcome("open a new window in cursor", named: "Visual Studio Code") == .heardNamedMismatch)
        #expect(outcome("switch finder to list view", named: "Finder") == .match)
        #expect(outcome("switch to list view", named: "Finder") == .noAppHeard)
        #expect(outcome("open a new window in code", named: "Visual Studio Code") == .ambiguousApp)
        #expect(outcome("open cursor and chrome", named: "Cursor") == .ambiguousApp)
        // Gemini's "Kasa": the tool names an app that is not installed; the words sound like Cursor.
        #expect(outcome("open a new window in kasa", named: "Kasa") == .heardNamedMismatch)
        // A name the identity check will ask about downstream is not contradicted here.
        #expect(outcome("open visual studio code", named: "code") == .match)
        #expect(outcome(nil, named: "Cursor") == .transcriptMissing)
        #expect(outcome("  ", named: "Cursor") == .transcriptMissing)
        let mismatch = RealtimeHeardCheck.decide(transcript: "new window in cursor", named: "Visual Studio Code", among: installed)
        #expect(mismatch.heardApps == ["Cursor"])
        // After a refusal this turn, re-calling with an app the words only GUESSED is not the owner's answer.
        func retry(_ transcript: String, named: String) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: named, among: installed, afterHeardRefusal: true).outcome
        }
        #expect(retry("open a new window in kasa", named: "Cursor") == .unconfirmedRetry)
        #expect(outcome("open a new window in kasa", named: "Cursor") == .match)
        #expect(retry("open a new window in chrome", named: "Google Chrome") == .unconfirmedRetry)
        #expect(retry("open a new window in cursor", named: "Cursor") == .match)
        #expect(retry("open preview", named: "Preview") == .match)
        #expect(mismatch.refusalError == "heardNamedMismatch")
    }

    // The owner's live test 2026-09-30 12:41-12:46Z: eight turns refused because a
    // word that names an app ("terminal", "LinkedIn") named a thing INSIDE the app
    // in front. Each utterance below is the logged transcript, verbatim.
    @Test func aWordForSomethingInsideTheAppInFrontIsNotAnotherApp() {
        let apps = installed + [app("/System/Applications/Utilities/Terminal.app"), app("/System/Applications/Utilities/Console.app"),
                                app("/Users/o/Applications/LinkedIn.app")]
        let cursor = URL(fileURLWithPath: "/Applications/Cursor.app", isDirectory: true)
        let vsCode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)
        func outcome(_ transcript: String, named: String = "Cursor", tool: String, target: [String] = [],
                     frontmost: URL? = cursor) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: named, among: apps, toolName: tool,
                                      targetWords: RealtimeVoiceVerbs.foldedTokens(target.joined(separator: " ")), frontmostApp: frontmost).outcome
        }
        let terminalOffer = ["Terminal (⌃`)", "Kill Terminal", "Split Terminal (⌘\\)"]
        // 90CF8D: an x,y press; the recent find_on_screen offered Cursor's own terminal controls.
        #expect(outcome("Okay, it's all right. Let's close the agent panel and close terminal both.", tool: "press_element",
                        target: terminalOffer) == .noAppHeard)
        // 97C352 / 41A97A / 5E1733: the owner said where the terminal is.
        #expect(outcome("Ah, yes. The terminal in Cursor and the Agent Panel both close it.", tool: "press_element") == .match)
        #expect(outcome("Yes, I said the terminal inside Cursor, which you can see on the right-hand side.", tool: "focus_app") == .match)
        #expect(outcome("Yes, I said the terminal inside Cursor, which you can see on the right-hand side.", tool: "press_menu",
                        target: ["View", "Terminal"]) == .match)
        #expect(outcome("Hey, can you kill the terminal in this cursor?", tool: "press_menu", target: ["View", "Terminal"]) == .match)
        // 211C1F: the target itself is "Kill Terminal".
        #expect(outcome("Sorry but I said terminal in I am saying terminal the terminal in front of me. You can see it is open right "
                        + "there inside cursor application then why you are misunderstanding it?", tool: "press_element",
                        target: ["Kill Terminal"]) == .match)
        // CE967C: "not Terminal" names nothing to act in.
        #expect(outcome("Yes, so that's what I asked for. Open Agent Panel, not Terminal.", tool: "press_menu",
                        target: ["View", "Appearance", "Panel"]) == .noAppHeard)
        // 523DB0: two apps named, the call opens one of them, and LinkedIn is "on Chrome".
        #expect(outcome("That's alright, leave it. Open Chrome and open LinkedIn on Chrome.", named: "Google Chrome", tool: "open_app",
                        frontmost: cursor) == .match)
        #expect(outcome("open cursor and chrome", tool: "open_app") == .match)
        #expect(outcome("open cursor and chrome", tool: "focus_app", frontmost: nil) == .match)

        // The other direction. 3DC292: "inside console" puts Console in the app slot — still asked.
        #expect(outcome("Yeah, also close the terminal inside console. Here you can see.", tool: "press_element",
                        target: ["Kill Terminal"]) == .heardNamedMismatch)
        // No evidence the word is inside Cursor: still asked.
        #expect(outcome("Okay, it's all right. Let's close the agent panel and close terminal both.", tool: "press_element") == .heardNamedMismatch)
        // Cursor is not in front and was not named: Terminal still counts.
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
        #expect(outcome("close terminal", tool: "press_element", target: terminalOffer, frontmost: chrome) == .heardNamedMismatch)
        // "open terminal" puts Terminal in the app slot: the owner may mean the app.
        #expect(outcome("open terminal", tool: "press_menu", target: ["View", "Terminal"]) == .heardNamedMismatch)
        // D66FC598 kept: VS Code in front, an offer that mentions cursors, the owner said "in cursor".
        #expect(outcome("open a new window in cursor", named: "Visual Studio Code", tool: "press_menu",
                        target: ["File", "New Window", "Add Cursor Above"], frontmost: vsCode) == .heardNamedMismatch)
        // Two apps for a menu press is still a question; a word that fits two apps is still a question.
        #expect(outcome("open cursor and chrome", tool: "press_menu") == .ambiguousApp)
        #expect(outcome("open code and chrome", named: "Visual Studio Code", tool: "open_app", frontmost: nil) == .ambiguousApp)
    }

    @Test func anUncaughtNameInTheAppSlotAsksBeforeAMenuToolAndIsLogged() {
        func decide(_ transcript: String, tool: String, menuWords: [String] = []) -> RealtimeHeardCheck.Decision {
            RealtimeHeardCheck.decide(transcript: transcript, named: "Cursor", among: installed, toolName: tool, menuWords: menuWords)
        }
        let unclear = decide("Open a new window in Zorbit.", tool: "press_menu")
        #expect(unclear.outcome == .appNameUnclear)
        #expect(unclear.heardSlot == ["zorbit"])
        #expect(RealtimeHeardCheck.refusal(for: unclear, toolName: "press_menu", named: "Cursor")?["error"] as? String == "heardUnavailable")
        #expect(decide("Open a new window in Zorbit.", tool: "find_menu_items").outcome == .appNameUnclear)
        // Only the menu tools: open and focus keep their own guards.
        #expect(decide("Open a new window in Zorbit.", tool: "focus_app").outcome == .noAppHeard)
        // English, a modern word, a menu word of the call itself, or a sound-alike: not a missed name.
        #expect(decide("switch to list view", tool: "press_menu") == RealtimeHeardCheck.Decision(outcome: .noAppHeard, heardApps: [], tier: nil))
        #expect(decide("show the sidebar", tool: "press_menu").outcome == .noAppHeard)
        #expect(decide("show all the windows", tool: "press_menu").outcome == .noAppHeard, "Webster's lists window, not windows")
        #expect(decide("hide the minimap", tool: "press_menu", menuWords: ["view", "hide", "minimap"]).outcome == .noAppHeard)
        let kasa = decide("open a new window in kasa", tool: "press_menu")
        #expect(kasa.outcome == .match)
        #expect(kasa.heardSlot == ["kasa"])
        #expect(RealtimeHeardCheck.isEnglishWord("window") && !RealtimeHeardCheck.isEnglishWord("zorbit"))
        #expect(RealtimeHeardCheck.englishWords.count > 200_000, "the system word list was read")
    }

    @Test func refusalsNameTheAppsAndOnlyAPressFailsClosedWithoutATranscript() {
        let mismatch = RealtimeHeardCheck.decide(transcript: "new window in cursor", named: "Visual Studio Code", among: installed)
        let told = RealtimeHeardCheck.refusal(for: mismatch, toolName: "press_menu", named: "Visual Studio Code") ?? [:]
        #expect(told["ok"] as? Bool == false)
        #expect(told["error"] as? String == "heardNamedMismatch")
        #expect(told["heard"] as? String == "Cursor")
        #expect(told["named"] as? String == "Visual Studio Code")
        #expect((told["message"] as? String)?.hasSuffix("whether they meant Cursor.") == true)

        // A guess is worded as one.
        let guessed = RealtimeHeardCheck.decide(transcript: "new window in kasa", named: "Visual Studio Code", among: installed)
        let guessedMessage = RealtimeHeardCheck.refusal(for: guessed, toolName: "press_menu", named: "Visual Studio Code")?["message"] as? String
        #expect(guessedMessage?.hasPrefix("the owner may have said Cursor, but") == true)
        #expect((told["message"] as? String)?.hasPrefix("the owner said Cursor, but") == true)
        let retried = RealtimeHeardCheck.decide(transcript: "new window in kasa", named: "Cursor", among: installed, afterHeardRefusal: true)
        let retriedTold = RealtimeHeardCheck.refusal(for: retried, toolName: "focus_app", named: "Cursor") ?? [:]
        #expect(retriedTold["error"] as? String == "heardUnconfirmed")
        #expect((retriedTold["message"] as? String)?.contains("may have said Cursor") == true)

        let ambiguous = RealtimeHeardCheck.decide(transcript: "open a new window in code", named: "Code", among: installed)
        let asked = RealtimeHeardCheck.refusal(for: ambiguous, toolName: "focus_app", named: "Code") ?? [:]
        #expect(asked["error"] as? String == "ambiguousApp")
        #expect(asked["candidates"] as? [String] == ["Visual Studio Code", "Claude Code URL Handler"])

        let missing = RealtimeHeardCheck.decide(transcript: nil, named: "Cursor", among: installed)
        #expect(RealtimeHeardCheck.refusal(for: missing, toolName: "press_menu", named: "Cursor")?["error"] as? String == "heardUnavailable")
        for tool in ["open_app", "focus_app", "find_menu_items"] {
            #expect(RealtimeHeardCheck.refusal(for: missing, toolName: tool, named: "Cursor", namedAppIsRunning: true) == nil, "\(tool)")
        }
        // A launch is not undone by one more request: with no transcript it asks.
        let launch = RealtimeHeardCheck.refusal(for: missing, toolName: "open_app", named: "Cursor", namedAppIsRunning: false) ?? [:]
        #expect(launch["error"] as? String == "heardUnavailable")
        #expect((launch["message"] as? String)?.contains("Nothing was opened") == true)
        #expect(RealtimeHeardCheck.refusal(for: missing, toolName: "focus_app", named: "Cursor", namedAppIsRunning: false) == nil)
        let match = RealtimeHeardCheck.decide(transcript: "open cursor", named: "Cursor", among: installed)
        #expect(RealtimeHeardCheck.refusal(for: match, toolName: "press_menu", named: "Cursor") == nil)

        let trace = RealtimeHeardCheck.traceObject(mismatch, named: "Visual Studio Code", transcriptArrivalMs: 812, waitedMs: 40, refused: true)
        #expect(Set(trace.keys) == ["outcome", "heardApps", "tier", "named", "transcriptArrivalMs", "waitedMs", "heardSlot", "refused"])
        #expect(trace["refused"] as? Bool == true)
        #expect(trace["outcome"] as? String == "heardNamedMismatch")
    }

    @Test func thePromptTellsTheModelToAskNotCheck() {
        #expect(RealtimeOpenAppTool.systemPrompt.contains("if a tool returns heardNamedMismatch or ambiguousApp, ask the owner which app they meant, briefly; never focus or open an app to check first."))
    }

    // MARK: The bounded wait

    @MainActor @Test func aLateTranscriptIsWaitedForAndAMissingOneIsNot() async {
        let turn = RealtimeTurnMarks()
        let now = ProcessInfo.processInfo.systemUptime
        turn.lastAudioSentUptime = now
        // Never arrives: nil at the deadline, not before.
        let missing = await turn.waitForHeard(until: now + 0.15)
        #expect(missing == nil)
        #expect(ProcessInfo.processInfo.systemUptime >= now + 0.15)

        // OpenAI: the completed event lands after the call began waiting.
        let late = RealtimeTurnMarks()
        late.lastAudioSentUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            late.heardText = "open a new window in cursor"
            late.heardCompleteUptime = ProcessInfo.processInfo.systemUptime
        }
        let arrived = await late.waitForHeard(until: ProcessInfo.processInfo.systemUptime + 2)
        #expect(arrived == "open a new window in cursor")

        // Gemini: pieces with no end marker count once quiet for geminiHeardQuietSeconds after the release.
        let gemini = RealtimeTurnMarks()
        let released = ProcessInfo.processInfo.systemUptime
        gemini.lastAudioSentUptime = released
        gemini.heardText = "open a new window"
        gemini.heardPieceUptimes = [released]
        #expect(gemini.heardCompletedUptime(now: released + 0.1) == nil)
        #expect(gemini.heardCompletedUptime(now: released + RealtimeTurnMarks.geminiHeardQuietSeconds) == released)
        // Exactly at the boundary at every uptime, not just where 0.3 rounds up (IEEE).
        for base in [1.1, 12_345.678, 98_765.4321, 1_000_000.7] {
            let marks = RealtimeTurnMarks()
            marks.lastAudioSentUptime = base
            marks.heardPieceUptimes = [base]
            #expect(marks.heardCompletedUptime(now: base + RealtimeTurnMarks.geminiHeardQuietSeconds) == base, "\(base)")
        }
    }

    // Live 2026-10-02 (90A952DF / D64CDA3D): both heardUnavailable refusals had the
    // transcript in hand (1,564 / 2,867 ms, waited 0 ms); the app slot held a word
    // for a thing on the page ("internet" the owner pointed at, "superhub").
    @Test func aWordOfTheCallsOwnTargetInTheAppSlotIsNoMissedAppName() {
        func decide(_ transcript: String, target: [String] = []) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: "Google Chrome", among: installed, toolName: "press_element",
                                      targetWords: RealtimeVoiceVerbs.foldedTokens(target.joined(separator: " "))).outcome
        }
        #expect(decide("Click on the internet one, this one.", target: ["Internet"]) == .noAppHeard)
        // Without that evidence the guard stands: a name-like word nobody recognised still asks.
        #expect(decide("Click on the internet one, this one.") == .appNameUnclear)
        #expect(decide("Close the both of the tabs of Superhub.") == .appNameUnclear)
        #expect(decide("Open a new window in Zorbit.", target: ["Internet"]) == .appNameUnclear)
    }

    // Scenario runs 2026-10-02/03, A5/C2/C5 refused in every run: "Type Hello World in
    // the search box." logged heardSlot ["box"] — Webster's Second has no "box". And the
    // text being typed is content: "type Kubernetes" puts its last word in the slot.
    @Test func theTypedTextAndTheFieldsDescriptionAreNoMissedAppName() {
        func decide(_ transcript: String, text: String) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: "Google Chrome", among: installed, toolName: "type_text",
                                      contentWords: RealtimeHeardCheck.contentTokens(text)).outcome
        }
        #expect(decide("Type Hello World in the search box.", text: "hello world") == .noAppHeard)
        #expect(decide("Type the quick brown fox jumps over the lazy dog in the search box.",
                       text: "the quick brown fox jumps over the lazy dog") == .noAppHeard)
        #expect(decide("type Kubernetes", text: "Kubernetes") == .noAppHeard)
        #expect(decide("type hello in the checkbox dialog", text: "hello") == .noAppHeard)
        // A name nobody recognised, outside the text, still asks.
        #expect(decide("Type hello world in Zorbit.", text: "hello world") == .appNameUnclear)
        #expect(decide("Type Kubernetes in Zorbit.", text: "Kubernetes") == .appNameUnclear)
    }

    // Live 2026-10-05 run 5185A552: "check his posts related to HeyClicky" with an app
    // named HeyClicky installed refused every press in Chrome as heardNamedMismatch.
    // A word that is the TOPIC of the request is not the app to act in.
    @Test func theTopicOfARequestIsNotTheAppToActIn() {
        let apps = installed + [app("/Applications/HeyClicky.app"), app("/Users/o/Applications/LinkedIn.app"),
                                app("/System/Applications/Utilities/Terminal.app")]
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
        func decide(_ transcript: String, named: String = "Google Chrome", tool: String = "press_element") -> RealtimeHeardCheck.Decision {
            RealtimeHeardCheck.decide(transcript: transcript, named: named, among: apps, toolName: tool, frontmostApp: chrome,
                                      namedIsBrowser: named == "Google Chrome")
        }
        let goal = "Go to LinkedIn in my browser, search for Farza or find him in my network, check his posts related to "
            + "HeyClicky, watch the videos if possible, and give me a small report, without taking any other actions."
        for tool in ["press_element", "type_text", "press_menu"] {
            #expect(decide(goal, tool: tool).refusalError == nil, "\(tool)")
        }
        #expect(decide("Search Google for Cursor tips.").outcome == .noAppHeard)
        #expect(decide("Find posts about HeyClicky.").outcome == .noAppHeard)
        // LinkedIn is installed here too, so "on LinkedIn" may still ask about LinkedIn; never about HeyClicky.
        #expect(!decide("On LinkedIn, show me HeyClicky's posts.").heardApps.contains("HeyClicky"))
        #expect(decide("Look for videos on HeyClicky in Chrome.").outcome == .match)

        // Where to act still names the app, and a mishearing there still refuses.
        let open = decide("open HeyClicky")
        #expect(open.outcome == .heardNamedMismatch)
        #expect(open.heardApps == ["HeyClicky"])
        #expect(decide("open HeyClicky", named: "HeyClicky", tool: "open_app").outcome == .match)
        let typed = decide("type hello in HeyClicky", tool: "type_text")
        #expect(typed.outcome == .heardNamedMismatch)
        #expect(typed.heardApps == ["HeyClicky"])
        // "for" is a topic only beside a search: "the settings for Cursor" is still Cursor.
        #expect(decide("open the settings for Cursor", named: "Visual Studio Code", tool: "press_menu").outcome == .heardNamedMismatch)
        // A possessive is a topic only when the sentence says where else to act.
        #expect(decide("Put Finder's toolbar path thing on.", named: "TextEdit", tool: "press_menu").outcome == .heardNamedMismatch)
        // A real wrong-app mishearing still refuses: no topic word, no place for the call's app.
        #expect(decide("close Terminal and open Cursor", named: "Cursor", tool: "press_menu").refusalError != nil)
        #expect(decide("close Terminal and open Cursor").refusalError != nil)
        #expect(decide("search for Cursor tips in Terminal").outcome == .heardNamedMismatch)
        // A bare search object may be the app itself ("search for LinkedIn"): it still asks.
        #expect(decide("find Terminal").refusalError != nil)
        #expect(decide("search for HeyClicky").refusalError != nil)
    }

    // Live voices are slower than the fixtures: Gemini's transcript came at up to
    // 3,107 ms after the release (voice-decisions.log, 123 live turns).
    @Test func theTranscriptWaitCoversTheSlowestLiveTranscript() {
        #expect(RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds >= 3.107 + 0.5)
    }

    @Test func theTranscriptionIsChargedAtItsPublishedPerMinuteRate() {
        // One minute of PCM16 mono 24 kHz is 2,880,000 bytes: US$0.003.
        #expect(abs(RealtimeVoiceConnection.openAITranscriptionUSD(pcmBytes: 2 * 24_000 * 60) - 0.003) < 1e-12)
        #expect(RealtimeVoiceConnection.openAITranscriptionUSD(pcmBytes: 0) == 0)
    }

    // MARK: Turns that overlap

    @MainActor @Test func aLateOpenAITranscriptReachesItsOwnTurnNotTheNextOne() async throws {
        let connection = RealtimeVoiceConnection(stack: .openAIRealtime, harnessAnswer: { _ in "{}" })
        let now = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["type": "input_audio_buffer.committed", "item_id": "item_A"], arrivalUptime: now)
        let first = connection.turn
        try await connection.beginTurn()
        connection.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item_A",
                           "transcript": "open a new window in cursor"], arrivalUptime: now + 1)
        #expect(first.heardText == "open a new window in cursor")
        #expect(first.heardCompleteUptime == now + 1)
        #expect(connection.turn.heardText.isEmpty)
        #expect(connection.turn.heardCompleteUptime == nil)
    }

    @MainActor @Test func geminiPiecesOfThePreviousTurnAreDroppedNotAppended() async throws {
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { _ in "{}" })
        func piece(_ text: String, at uptime: TimeInterval) {
            connection.handle(["serverContent": ["inputTranscription": ["text": text]]], arrivalUptime: uptime)
        }
        try await connection.beginTurn()
        try await connection.endTurn()
        piece("open a new window in", at: ProcessInfo.processInfo.systemUptime)
        // The next turn begins while that transcript is still open (not yet quiet).
        try await connection.beginTurn()
        let began = ProcessInfo.processInfo.systemUptime
        piece(" cursor", at: began + 0.2)
        #expect(connection.turn.heardText.isEmpty)
        piece("switch to list view", at: began + RealtimeVoiceConnection.geminiStaleHeardPieceSeconds + 0.5)
        #expect(connection.turn.heardText == "switch to list view")
        // A turn begun after the last one's transcript was complete drops nothing.
        try await connection.endTurn()
        connection.turn.heardCompleteUptime = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        piece("open finder", at: ProcessInfo.processInfo.systemUptime)
        #expect(connection.turn.heardText == "open finder")
    }

    @MainActor @Test func aCallWhoseTurnWasSupersededWhileItWaitedNeverReachesTheHarness() async throws {
        final class Requests: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
        }
        let requests = Requests()
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { line in requests.add(line); return "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["serverContent": ["inputTranscription": ["text": "open a new window in finder"]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["toolCall": ["functionCalls": [["id": "c1", "name": "press_menu",
                                                           "args": ["app": "Finder", "path": ["File", "New Finder Window"]]]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        let first = connection.turn
        // The owner presses the key again while the call waits for the transcript to go quiet.
        try await connection.beginTurn()
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while first.decisions.first?.dispatch == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(first.decisions.first?.dispatch?.result["error"] as? String == "superseded")
        #expect(requests.count == 0)
    }

    @MainActor @Test func callsReachTheHarnessInTheOrderTheModelEmittedThem() async throws {
        // The focus waits for the transcript and answers slowly; the unknown tool
        // would finish at once. Emitted focus-then-bogus, they must finish so.
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { _ in Thread.sleep(forTimeInterval: 0.2); return "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["serverContent": ["inputTranscription": ["text": "switch to finder"]]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["toolCall": ["functionCalls": [["id": "c1", "name": "focus_app", "args": ["name": "Finder"]],
                                                          ["id": "c2", "name": "bogus_tool", "args": [String: Any]()]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        let turn = connection.turn
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while turn.dispatches.count < 2, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(turn.dispatches.count == 2)
        #expect(turn.dispatches.first?.result["error"] as? String != "unknownTool")
        #expect(turn.dispatches.last?.result["error"] as? String == "unknownTool")
    }

    // MARK: Auto-focus

    @Test func autoFocusOnlyWhenStrongWordsAndToolAgreeOnARunningApp() {
        func gate(_ transcript: String?, named: String, afterRefusal: Bool = false, error: String? = "appMismatch",
                  bundle: String? = "com.example.app", running: Bool = true) -> RealtimeHeardCheck.AutoFocusGate? {
            let decision = RealtimeHeardCheck.decide(transcript: transcript, named: named, among: installed, afterHeardRefusal: afterRefusal)
            return RealtimeHeardCheck.autoFocusGate(heard: decision, dispatchError: error, resolvedBundleIdentifier: bundle, namedAppIsRunning: running)
        }
        let agree = RealtimeHeardCheck.AutoFocusGate(triggered: true, reason: "witnessesAgree")
        // Full name and common-word slot: both witnesses, strong evidence.
        #expect(gate("switch finder to list view", named: "Finder") == agree)
        #expect(gate("open preview", named: "Preview") == agree)
        // Only appMismatch raises the question at all.
        #expect(gate("switch finder to list view", named: "Finder", error: nil) == nil)
        #expect(gate("switch finder to list view", named: "Finder", error: "notVerified") == nil)
        #expect(gate("switch finder to list view", named: "Finder", error: "frontmostChanged") == nil)
        // Not running: open_app's job (its own heard check), never a launch from here.
        #expect(gate("switch finder to list view", named: "Finder", running: false) == .init(triggered: false, reason: "notRunning"))
        #expect(gate("switch finder to list view", named: "Finder", bundle: nil) == .init(triggered: false, reason: "unresolved"))
        // A distinctive word of one app's name counts (owner 2026-09-28): "chrome" is Google Chrome's.
        #expect(gate("open a new window in chrome", named: "Google Chrome") == agree)
        // A sound-alike is a different word guessed: never.
        #expect(gate("open a new window in kasa", named: "Cursor") == .init(triggered: false, reason: "tier:soundAlike"))
        // Generic and everyday words never reach the word tier: "google" is on the generic list,
        // "notes" and "home" name their apps only in the app slot.
        #expect(gate("search google for this", named: "Google Chrome") == .init(triggered: false, reason: "heard:noAppHeard"))
        #expect(gate("show my notes", named: "Notes") == .init(triggered: false, reason: "heard:noAppHeard"))
        #expect(gate("go home", named: "Home") == .init(triggered: false, reason: "heard:noAppHeard"))
        // Anything but a match.
        #expect(gate("open a new window in code", named: "Visual Studio Code") == .init(triggered: false, reason: "heard:ambiguousApp"))
        #expect(gate("open a new window in chrome", named: "Google Chrome", afterRefusal: true)
                == .init(triggered: false, reason: "heard:unconfirmedRetry"))
        #expect(gate("open a new window in cursor", named: "Visual Studio Code") == .init(triggered: false, reason: "heard:heardNamedMismatch"))
        #expect(gate("switch to list view", named: "Finder") == .init(triggered: false, reason: "heard:noAppHeard"))
        #expect(gate(nil, named: "Finder") == .init(triggered: false, reason: "heard:transcriptMissing"))
        #expect(RealtimeHeardCheck.autoFocusGate(heard: nil, dispatchError: "appMismatch", resolvedBundleIdentifier: "x", namedAppIsRunning: true)
                == .init(triggered: false, reason: "heard:notChecked"))
    }

    @MainActor @Test func anAutoFocusFocusesOnceThenRerunsOnceAndNeverLoops() async throws {
        final class Requests: @unchecked Sendable {
            private let lock = NSLock()
            private var verbs: [String] = []
            func add(_ verb: String) { lock.lock(); verbs.append(verb); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return verbs }
        }
        let requests = Requests()
        // Something else stays in front whatever is focused: the re-run mismatches again, and must stop there.
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { line in
            let verb = (RealtimeOpenAppTool.harnessResponseObject(line)["verb"] as? String) ?? "?"
            requests.add(verb)
            return verb == "focus" ? #"{"ok":true,"verification":{"status":"confirmed"}}"#
                : #"{"ok":false,"error":"frontmostChanged","actualApp":{"name":"Cursor","bundleIdentifier":"com.todesktop.230313mzl4w4u92"}}"#
        })
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["serverContent": ["inputTranscription": ["text": "switch finder to list view"]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["toolCall": ["functionCalls": [["id": "c1", "name": "find_menu_items", "args": ["app": "Finder", "words": "list view"]]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        let turn = connection.turn
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while turn.decisions.first?.dispatch == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(requests.all == ["menus", "focus", "menus"])
        let autoFocus = turn.decisions.first?.dispatch?.autoFocus
        #expect(autoFocus?["triggered"] as? Bool == true)
        #expect(autoFocus?["focusStatus"] as? String == "confirmed")
        #expect(autoFocus?["retried"] as? Bool == true)
        #expect(turn.decisions.first?.dispatch?.result["error"] as? String == "appMismatch")
    }

    // MARK: Notch

    @Test func theNotchSaysWhichAppItHeard() {
        #expect(JarvisNotchReason.plain(forErrorCode: "heardNamedMismatch", subject: "Cursor") == "heard Cursor, asking first")
        let long = JarvisNotchReason.plain(forErrorCode: "heardNamedMismatch", subject: "Claude Code URL Handler")
        #expect(long == "heard another app, asking first")
        #expect(long.count <= JarvisNotchReason.maximumLength)
        #expect(JarvisNotchReason.plain(forErrorCode: "heardUnavailable").count <= JarvisNotchReason.maximumLength)
        #expect(JarvisNotchReason.plain(forErrorCode: "heardUnconfirmed").count <= JarvisNotchReason.maximumLength)
        #expect(JarvisNotchReason.plain(forErrorCode: "appMismatch", subject: "Cursor") == "a different app is in front")
        #expect(JarvisNotchState.thinking.next(on: .toolCall(title: "x"))?.next(on: .harnessAnswered(ok: false, subject: "Cursor", error: "heardNamedMismatch"))
                == .didntTake(reason: "heard Cursor, asking first"))
    }

    // MARK: Transcriber vocabulary hint

    @Test func transcriptionHintNamesDistinctiveAppsOnceRunningFirst() {
        let vocabulary = RealtimeHeardCheck.transcriptionVocabulary(
            from: installed + [app("/Users/o/Applications/Cursor.app")],
            runningPaths: ["/System/Library/CoreServices/Finder.app"])
        #expect(vocabulary.first == "Finder")
        #expect(vocabulary.contains("Cursor") && vocabulary.contains("Visual Studio Code") && vocabulary.contains("TextEdit"))
        // Everyday-word and all-generic names, and the menu-bar alias "Code", stay out.
        for skipped in ["Preview", "Home", "Photos", "Notes", "Clock", "Font Book", "Time Machine", "App Store", "Code"] {
            #expect(!vocabulary.contains(skipped))
        }
        #expect(vocabulary.filter { $0 == "Cursor" }.count == 1)
        #expect(RealtimeHeardCheck.transcriptionPrompt(vocabulary: ["Cursor", "Finder"]) == "App names on this Mac: Cursor, Finder")
    }

    @Test func transcriptionHintStaysUnderItsCap() {
        let many = (0..<200).map { app("/Applications/Distinctapp\($0).app") }
        let prompt = RealtimeHeardCheck.transcriptionPrompt(
            vocabulary: RealtimeHeardCheck.transcriptionVocabulary(from: many, runningPaths: []))
        #expect(prompt.count <= RealtimeHeardCheck.transcriptionHintMaxCharacters)
        #expect(prompt.count > RealtimeHeardCheck.transcriptionHintMaxCharacters - 20)
    }

    // Scenario B2 2026-10-03: "tell me the cheapest plan" put "cheapest" in the app
    // slot, Webster's Second lists only "cheap", and seven task steps were refused
    // heardUnavailable. Inflections reduce to a listed stem; a missed app name has none.
    @Test func anInflectedEnglishWordIsNoMissedAppName() {
        for word in ["cheapest", "cheaper", "largest", "bigger", "running", "opened", "saved", "tried", "copies", "happier", "plans"] {
            #expect(RealtimeHeardCheck.isEnglishWord(word), "\(word)")
        }
        for word in ["zorbit", "zorbits", "zorbiter", "zorbitest", "superhub"] {
            #expect(!RealtimeHeardCheck.isEnglishWord(word), "\(word)")
        }
        func decide(_ transcript: String) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: "Google Chrome", among: installed, toolName: "press_element").outcome
        }
        #expect(decide("Open the plans page on this shop and tell me the cheapest plan.") == .noAppHeard)
        #expect(decide("Open the plans page in Zorbit.") == .appNameUnclear)
        #expect(decide("Show me the biggest one in Zorbiter.") == .appNameUnclear)
    }

    // Scenario B11 2026-10-03: "open the settings page on this site" with a shop in
    // front opened System Settings ("settings" names no app, so the model chose).
    // Words about the page or site in front name no app to open; "open settings" still does.
    @Test func wordsAboutThePageInFrontOpenNoApp() {
        func refuses(_ transcript: String?, tool: String = "open_app", outcome: RealtimeHeardCheck.Outcome = .noAppHeard) -> Bool {
            RealtimeHeardCheck.refusesOpeningAnApp(toolName: tool, outcome: outcome, transcript: transcript)
        }
        #expect(refuses("Open the settings page on this site"))
        #expect(refuses("open the settings on this website"))
        #expect(refuses("go to the account page", tool: "focus_app"))
        #expect(refuses("open the settings tab"))
        #expect(!refuses("Open settings"))                                    // A10: System Settings
        #expect(!refuses("open my calendar"))
        #expect(!refuses("open TextEdit on this page", outcome: .match))     // the owner named the app
        #expect(!refuses("Open the settings page on this site", tool: "press_element"))
        #expect(!refuses(nil))
    }

    // C3 live (02-30-16Z): the task's own app was refused too — after Finder came
    // forward, focus_app Chrome ("read the heading on this page…") came back pageNotApp.
    // The page's own app is never "an app instead of the page".
    @Test func thePagesOwnAppIsNeverRefusedAsNotThePage() {
        #expect(!RealtimeHeardCheck.refusesOpeningAnApp(toolName: "focus_app", outcome: .noAppHeard,
                                                        transcript: "read the heading on this page, then type it", callIsPageApp: true))
        #expect(RealtimeHeardCheck.refusesOpeningAnApp(toolName: "open_app", outcome: .noAppHeard,
                                                       transcript: "Open the settings page on this site", callIsPageApp: false))
    }

    // 2026-10-03 brief: any word before "page" / "section" refused the north-star app
    // ("open the bluetooth page in settings" opened nothing unless Settings was in front).
    // Words that place the page IN an app name that app; B11 (no app named) still refuses.
    @Test func aPageTheOwnerPlacesInAnAppMayOpenThatApp() {
        func refuses(_ transcript: String, named: String) -> Bool {
            RealtimeHeardCheck.refusesOpeningAnApp(toolName: "open_app", outcome: .noAppHeard, transcript: transcript, named: named)
        }
        #expect(!refuses("open the bluetooth page in settings", named: "System Settings"))
        #expect(!refuses("open the wifi section of settings", named: "System Settings"))
        #expect(!refuses("open the wi-fi section of System Settings", named: "System Settings"))
        #expect(!refuses("open the extensions page in Chrome", named: "Google Chrome"))
        // B11: a page part with no app named, or the page in front named.
        #expect(refuses("Open the Settings page", named: "System Settings"))
        #expect(refuses("Open the settings page on this site", named: "System Settings"))
        #expect(refuses("open the settings page in this shop", named: "System Settings"))
        // The words place the page in another app than the call opens.
        #expect(refuses("open the bluetooth page in settings", named: "TextEdit"))
    }

    // An app the task itself opened is the page's app too, like the front and start apps.
    @Test func anAppTheTaskOpenedIsThePagesApp() {
        typealias Check = RealtimeHeardCheck
        #expect(Check.isPageApp(callBundle: "com.apple.TextEdit", startBundle: "com.google.Chrome", frontmostBundle: "com.apple.finder",
                                openedByTask: ["com.apple.TextEdit"]))
        #expect(Check.isPageApp(callBundle: "com.google.Chrome", startBundle: "com.google.Chrome", frontmostBundle: nil, openedByTask: []))
        #expect(Check.isPageApp(callBundle: "com.apple.finder", startBundle: nil, frontmostBundle: "com.apple.finder", openedByTask: []))
        #expect(!Check.isPageApp(callBundle: "com.apple.systempreferences", startBundle: "com.google.Chrome", frontmostBundle: "com.google.Chrome",
                                 openedByTask: ["com.apple.TextEdit"]))
        #expect(!Check.isPageApp(callBundle: nil, startBundle: nil, frontmostBundle: nil, openedByTask: []))
    }
}
