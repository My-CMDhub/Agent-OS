//
//  VoiceReliabilityTests.swift
//  leanring-buddyTests
//
//  The owner's complaint of 2026-11-03, cause by cause: "completes a task but claims it didn't work", "it feels like an
//  interview". Each test is a turn from the logs. What the live providers do with the wording is the scenario run's question.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct VoiceReliabilityTests {

    private func app(_ path: String, _ name: String? = nil, file: Bool = true) -> RealtimeVoiceVerbs.AppName {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return RealtimeVoiceVerbs.AppName(name: name ?? url.deletingPathExtension().lastPathComponent, url: url, isFileName: file)
    }

    private var installed: [RealtimeVoiceVerbs.AppName] {
        [app("/Applications/Xcode.app"), app("/Users/o/Applications/Claude Code URL Handler.app"), app("/Applications/Claude.app"),
         app("/Applications/Visual Studio Code.app"), app("/Applications/Visual Studio Code.app", "Code", file: false),
         app("/System/Applications/Calendar.app"), app("/System/Applications/TextEdit.app"), app("/System/Applications/Calculator.app"),
         app("/Applications/Cursor.app"), app("/Applications/Google Chrome.app")]
    }

    private func isHelper(_ url: URL) -> Bool { url.lastPathComponent == "Claude Code URL Handler.app" }

    private func decide(_ transcript: String, named: String, tool: String = "press_keys") -> RealtimeHeardCheck.Decision {
        RealtimeHeardCheck.decide(transcript: transcript, named: named, among: installed, toolName: tool, isHelper: isHelper)
    }

    // MARK: Exact names win (2026-11-03T04:57, four turns; 2026-10-31T12:14)

    @Test func theTurnsOfTheOwnersTest() {
        for tool in ["press_keys", "find_menu_items", "open_app", "press_menu", "close"] {
            #expect(decide("Minimize Xcode and open Calendar", named: "Xcode", tool: tool).outcome == .match, "\(tool)")
        }
        #expect(decide("Minimize Xcode and open Calendar", named: "Calendar", tool: "open_app").outcome == .match)
        #expect(decide("X code", named: "Xcode").outcome == .match)
        #expect(decide("X code", named: "Xcode").heardApps == ["Xcode"])
        #expect(decide("No, I said X code application.", named: "Xcode").outcome == .match)
        #expect(decide("Yes, so minimize Xcode.", named: "Xcode").outcome == .match)
    }

    @Test func aBackgroundHelperNeverCompetesWithARealApp() {
        #expect(decide("Quit Claude Code", named: "Claude", tool: "close").outcome == .match)
        #expect(RealtimeHeardCheck.appsMentioned(in: "open code", among: installed, isHelper: isHelper).apps.map(\.lastPathComponent) == ["Visual Studio Code.app"])
        // Said in full it is still that app, and alone it is still heard.
        #expect(decide("open claude code url handler", named: "Claude Code URL Handler", tool: "open_app").outcome == .match)
        // With no helper fact the word still fits two: fail-safe.
        #expect(RealtimeHeardCheck.decide(transcript: "open code", named: "Visual Studio Code", among: installed, toolName: "open_app").outcome == .ambiguousApp)
    }

    @Test func twoEqualAppsStillAsk() {
        let both = [app("/Applications/Foo Mail.app"), app("/Applications/Foo Chat.app")]
        #expect(RealtimeHeardCheck.decide(transcript: "open foo", named: "Foo Mail", among: both, toolName: "open_app").outcome != .match)
        #expect(RealtimeVoiceVerbs.resolveApp(named: "foo", among: both) == .ambiguous(both.map(\.url)))
        let twoCopies = [app("/Applications/Xcode.app"), app("/Users/o/Applications/Xcode.app")]
        #expect(RealtimeVoiceVerbs.resolveApp(named: "Xcode", among: twoCopies) == .ambiguous(twoCopies.map(\.url)))
    }

    @Test func spacingIsNoPartOfAName() {
        #expect(RealtimeVoiceVerbs.resolveApp(named: "X code", among: installed) == .resolved(URL(fileURLWithPath: "/Applications/Xcode.app", isDirectory: true)))
        #expect(RealtimeVoiceVerbs.resolveApp(named: "text edit", among: installed) == .resolved(URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)))
        #expect(RealtimeVoiceVerbs.resolveApp(named: "code", among: installed, isHelper: isHelper) == .resolved(URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)))
        let found = ApplicationLauncher.matchApplications(named: "X code", in: [URL(fileURLWithPath: "/Applications")]) { _ in ["Xcode.app", "Safari.app"] }
        #expect(found.map(\.lastPathComponent) == ["Xcode.app"])
    }

    @Test func anAppPlacedInsideAnotherIsStillAsked() {
        #expect(decide("open terminal in cursor", named: "Cursor", tool: "press_menu").outcome != .heardNamedMismatch)
        let withTerminal = installed + [app("/System/Applications/Utilities/Terminal.app")]
        #expect(RealtimeHeardCheck.decide(transcript: "open terminal in cursor", named: "Terminal", among: withTerminal, toolName: "press_keys").outcome == .ambiguousApp)
    }

    // MARK: British and American spelling

    @Test func aMenuWordFindsItsOtherSpelling() {
        for (first, second) in [("minimize", "minimise"), ("minimized", "minimised"), ("maximizing", "maximising"), ("customize", "customise"),
                                ("organization", "organisation"), ("analyze", "analyse"), ("color", "colour"), ("colors", "colours"), ("favorites", "favourites"),
                                ("center", "centre"), ("gray", "grey"), ("canceled", "cancelled"), ("labeling", "labelling")] {
            #expect(RealtimeVoiceVerbs.tokensMatch(first, second), "\(first) \(second)")
            #expect(RealtimeVoiceVerbs.tokensMatch(second, first), "\(second) \(first)")
        }
        #expect(!RealtimeVoiceVerbs.tokensMatch("raise", "raze"))
        #expect(!RealtimeVoiceVerbs.tokensMatch("minimise", "maximise"))
        #expect(!RealtimeVoiceVerbs.tokensMatch("close", "clone"))
    }

    // MARK: What a press can change besides the count

    @Test func minimiseZoomFullScreenAndHideAreChanges() {
        let frame = CGRect(x: 10, y: 10, width: 400, height: 300)
        let plain = ActionVerifier.WindowState(minimised: false, fullScreen: false, frame: frame)
        func evidence(_ now: ActionVerifier.WindowState) -> String? { ActionVerifier.windowStateEvidence(before: plain, now: now) }
        #expect(evidence(plain) == nil)
        #expect(evidence(.init(minimised: true, fullScreen: false, frame: frame)) == "the window was minimised")
        #expect(evidence(.init(minimised: false, fullScreen: true, frame: frame)) == "the window went full screen")
        #expect(evidence(.init(minimised: false, fullScreen: false, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))) == "the window moved or changed size")
        #expect(evidence(.init(minimised: false, fullScreen: false, frame: frame.offsetBy(dx: 0.5, dy: 0))) == nil)
        // A failed read is never a change.
        #expect(evidence(.init(minimised: nil, fullScreen: nil, frame: nil)) == nil)
        let before = ActionVerifier.MenuPressReading(windows: 1, hidden: false)
        #expect(ActionVerifier.menuPressEvidence(before: before, now: .init(windows: 1, hidden: true)) == "the app was hidden")
        #expect(ActionVerifier.menuPressEvidence(before: before, now: .init(windows: 1, hidden: nil)) == nil)
    }

    // MARK: Silence is not failure

    @Test func notVerifiedTellsTheModelWhatWasSeenNotAVerdict() {
        let result = RealtimeOpenAppTool.toolResult(fromHarnessResponse: ["ok": false, "error": "notVerified", "verification": ["status": "notObserved"]])
        #expect(result["ok"] as? Bool == false)
        let message = result["message"] as? String ?? ""
        #expect(message.contains("cannot confirm"))
        #expect(message.contains("never say it failed"))
        #expect(message.contains("never say it worked"))
        #expect(RealtimeOpenAppTool.systemPrompt.contains("notVerified means it was sent"))
        #expect(!RealtimeOpenAppTool.systemPrompt.contains("or the result says notObserved, say it didn't take"))
    }

    // MARK: Two actions go to the task runner

    @Test func twoActionsAreSeenInTheOwnersWords() {
        for words in ["Minimize Xcode and open Calendar", "open calculator and minimize textedit", "Can you close this tab, then open a new one?",
                      "Please minimise it and then open Notes", "Read the heading on this page, then type it into the search box",
                      "hide Finder and also open Safari", "I'd like you to open mail and write to Bob", "go ahead and open Safari and close Notes"] {
            #expect(RealtimeHeardCheck.namesTwoActions(words), "\(words)")
        }
        for words in ["open calendar", "open safari and notes", "go ahead and open Safari", "try and open Safari", "Yes, so minimize Xcode.", "X code",
                      "type salt and pepper in the search box", "what is this and why", "turn off wifi", "click sign in", "close the tab and the window",
                      "scroll down", "stop"] {
            #expect(!RealtimeHeardCheck.namesTwoActions(words), "\(words)")
        }
    }

    // MARK: Typing where the owner said

    @Test func anUnsaidPointerOnATypingFallsToTheNamedOrFocusedField() {
        var call = RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.typeTextName, appName: "Google Chrome")
        call.underPointer = true
        #expect(!RealtimeOpenAppTool.droppingUnsaidPointer(call, heard: "In the post box, write the words ship slice two today.").underPointer)
        #expect(RealtimeOpenAppTool.droppingUnsaidPointer(call, heard: "type it here").underPointer)
    }

    @Test func theOwnersWordsNameTheField() {
        #expect(RealtimeOpenAppTool.fieldWords(inHeard: "Type Hello World in the search box.") == ["search"])
        #expect(RealtimeOpenAppTool.fieldWords(inHeard: "In the post box, write the words ship slice two today.") == ["post"])
        #expect(RealtimeOpenAppTool.fieldWords(inHeard: "put it into the box") == [])
        #expect(RealtimeOpenAppTool.fieldWords(inHeard: "type hello world") == nil)
        #expect(RealtimeOpenAppTool.fieldWords(inHeard: nil) == nil)

        let searchPage = ["Address and search bar", "Search", "Your name"]
        #expect(RealtimeOpenAppTool.fieldPicked(by: ["search"], all: searchPage, inPage: ["Search", "Your name"]) == "Search")
        // The word fits nothing, and the page has one field: "the post box" is that composer.
        #expect(RealtimeOpenAppTool.fieldPicked(by: ["post"], all: ["Address and search bar", "Text editor for creating content"],
                                                inPage: ["Text editor for creating content"]) == "Text editor for creating content")
        #expect(RealtimeOpenAppTool.fieldPicked(by: [], all: ["A", "B"], inPage: ["A", "B"]) == nil)
        // Two that fit equally pick nothing.
        #expect(RealtimeOpenAppTool.fieldPicked(by: ["name"], all: ["First name", "Last name"], inPage: ["First name", "Last name"]) == nil)
        #expect(RealtimeOpenAppTool.fieldPicked(by: ["zorbit"], all: ["First name", "Last name"], inPage: ["First name", "Last name"]) == nil)
    }

    @Test func theOwnersOrderPicksFromAFindSoTheModelNeedNotAsk() {
        func candidate(_ name: String, y: CGFloat) -> RealtimeScreenCandidate {
            RealtimeScreenCandidate(name: name, role: "AXButton", frame: CGRect(x: 10, y: y, width: 60, height: 20), position: "centre")
        }
        let deletes = [candidate("Delete", y: 300), candidate("Delete", y: 200), candidate("Delete", y: 100), candidate("Drafts", y: 500)]
        #expect(RealtimeOpenAppTool.ordinalHint(heard: "delete the first draft", found: deletes)?.contains("press_element") == true)
        #expect(RealtimeOpenAppTool.ordinalHint(heard: "click delete", found: deletes) == nil)
        #expect(RealtimeOpenAppTool.ordinalHint(heard: "delete the first draft", found: [candidate("Delete", y: 300)]) == nil)
        #expect(RealtimeOpenAppTool.ordinalHint(heard: "delete the first draft", found: nil) == nil)
    }

    // MARK: Section K, 2026-11-03

    @Test func closeIsAWindowUntilTheOwnerSaysQuit() {
        for words in ["could you close that calculator thing, yeah, just, close it", "um, actually, put that away", "High text edit would you?", "close the calculator"] {
            #expect(RealtimeHandsVerbs.closeTarget(what: "app", heard: words) == "window", "\(words)")
        }
        for words in ["quit xcode", "Can you quit Xcode?", "You can completely close the Claude desktop application", "close the app", "exit chrome"] {
            #expect(RealtimeHandsVerbs.closeTarget(what: "app", heard: words) == "app", "\(words)")
        }
        #expect(RealtimeHandsVerbs.closeTarget(what: "tab", heard: "close this") == "tab")
        // No words in time: as sent, and a quit still shows its card.
        #expect(RealtimeHandsVerbs.closeTarget(what: "app", heard: nil) == "app")
    }

    @Test func aQuestionMovesNothing() {
        for words in ["is, uh, x code open right now", "Is A X Code open right now?", "okay is safari running", "are my notes open", "does xcode have a window open"] {
            #expect(RealtimeHeardCheck.isYesNoQuestion(words), "\(words)")
        }
        for words in ["open xcode", "can I get the calculator up", "is it possible to open safari", "could you open notes", "where did my downloads go", "pull up my calendar"] {
            #expect(!RealtimeHeardCheck.isYesNoQuestion(words), "\(words)")
        }
        let refused = RealtimeHeardCheck.questionRefusal(named: "Xcode", isRunning: true)
        #expect(refused["error"] as? String == "questionOnly")
        #expect((refused["message"] as? String)?.contains("is running") == true)
        #expect((RealtimeHeardCheck.questionRefusal(named: "Xcode", isRunning: false)["message"] as? String)?.contains("not running") == true)
    }

    @Test func anUnmappedShortcutGoesToTheLiveMenuBar() {
        let call = RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.pressMenuName, appName: "TextEdit", shortcut: "cmd+m")
        let refused = RealtimeToolRefusal(error: "shortcutNotMapped", message: "m")
        #expect(RealtimeOpenAppTool.shortcutFallback(call, refusal: refused)?.name == RealtimeVoiceVerbs.pressKeysName)
        #expect(RealtimeOpenAppTool.shortcutFallback(call, refusal: refused)?.shortcut == "cmd+m")
        #expect(RealtimeOpenAppTool.shortcutFallback(call, refusal: RealtimeToolRefusal(error: "shortcutAmbiguous", message: "m")) == nil)
    }

    @Test func aSpokenForPathFindsItsListedSpelling() {
        let listed = [RealtimeMenuCandidate(path: ["Window", "Minimise"], shortcut: "\u{2318}M"), RealtimeMenuCandidate(path: ["Window", "Minimise All"], shortcut: nil)]
        #expect(RealtimeOpenAppTool.offeredPath(matching: ["Window", "Minimize"], among: listed) == ["Window", "Minimise"])
        #expect(RealtimeOpenAppTool.offeredPath(matching: ["Window", "Minimise"], among: listed) == ["Window", "Minimise"])
        #expect(RealtimeOpenAppTool.offeredPath(matching: ["Window", "Zoom"], among: listed) == nil)
    }

    @Test func theCascadeSpeaksIntentOnlyBeforeASlowTool() {
        let line = RealtimeOpenAppTool.cascadeIntentLine
        #expect(line.contains("before open_app, open_url or open_settings_pane"))
        #expect(line.contains("before any other tool say nothing"))
    }

    // MARK: The task's report

    private func receipt(_ tool: String, ok: Bool = true, step: Int = 1, shown: String? = nil, typed: String? = nil, awaitsCommit: Bool = false) -> AgentLoop.Receipt {
        var receipt = AgentLoop.Receipt(step: step, toolName: tool, ok: ok, error: ok ? nil : "failed")
        receipt.shown = shown
        receipt.typed = typed
        receipt.awaitsCommit = awaitsCommit
        return receipt
    }

    /// Word for word the refused reports of agent-loop.log, each a read-only question answered right and spoken as failed.
    @MainActor @Test func aReadOnlyTasksReportIsNotADeed() {
        let read = [receipt(AgentLoopTools.readPageName)]
        for summary in ["I couldn't answer which song was most recently added to your Music library.",
                        "Going by modified date, I could not check the date each app was added, since the list stayed sorted by modified date.",
                        "The top headline right now is \"Accused barrister sent 'disgusting' messages to charity worker\", the lead item under Top Stories.",
                        "He argues that much of it was written by agents and published without measurements."] {
            #expect(AgentLoop.doneChallenge(summary: summary, evidence: [], receipts: read, currentStep: 2, readOnly: true) == nil, "\(summary)")
        }
        // In a task that can act, the same effect words still need a receipt, and a first-person claim always does.
        #expect(AgentLoop.doneChallenge(summary: "Your comment was posted.", evidence: [], receipts: read, currentStep: 2) != nil)
        #expect(AgentLoop.doneChallenge(summary: "I clicked Post.", evidence: [], receipts: read, currentStep: 2, readOnly: true) != nil)
    }

    /// E03 stays: Calendar's suggestion line shows the name while nothing exists, so a read never proves an unsubmitted entry.
    /// Launch E12 2026-10-31 (the reminder did exist) ends unconfirmed instead of failed: said with the doubt, not as "did not work".
    @MainActor @Test func aReadStillDoesNotProveAnUnsubmittedEntry() {
        let typed = [receipt(RealtimeVoiceVerbs.typeTextName, typed: "Call Mom", awaitsCommit: true)]
        #expect(AgentLoop.doneChallenge(summary: "I created a reminder titled \"Call Mom\" due today at 5:00 pm.", evidence: [], receipts: typed, currentStep: 2,
                                        seenNow: "Shopping\nCall Mom\nToday at 5:00 pm") != nil)
    }

    @MainActor @Test func anUnconfirmedReportIsSaidWithItsDoubtNotAsAFailure() {
        let line = AgentLoop.finalLine(.unconfirmed(summary: "The reminder is set for 5 pm.", challenge: "no ok press result backs that claim"),
                                       goal: "g", lastProgress: nil, step: 3) ?? ""
        #expect(line.contains("The reminder is set for 5 pm."))
        #expect(line.contains("could not confirm"))
        #expect(!line.contains("tell the owner briefly that it did not work"))
        #expect(AgentTaskPhase.ended(.unconfirmed(summary: "s", challenge: "c")) == .done)
        let status = AgentLoop.statusLine(goal: "g", phase: .done, step: 3, receipts: [], artifacts: [],
                                          outcome: .unconfirmed(summary: "The reminder is set.", challenge: "no receipt"))
        #expect(status.contains("not confirmed"))
        #expect(status.contains("The reminder is set."))
    }
}
