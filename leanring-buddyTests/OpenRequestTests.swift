//
//  OpenRequestTests.swift
//  The owner's live test of 2026-11-04, turn by turn: their words as heard, and what each must lead to.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct OpenRequestTests {
    private let open = OpenRequest(words: "All right now, set a taste meeting with Jarvis at seven pm today.", uptime: 100)

    @Test func theOwnersFollowUpsCarryItOn() {
        for words in ["Try to add the test meeting right now again", "All right, yes. Today, a jar with taste meeting at 7:00 p.m.", "Yes, I say today 7:00 p.m.",
                      "Try to perform the action again in calendar you should be able to now access it because I have given you full access as you can see.",
                      "I just specified you recently. Okay, I will tell you again today 7:00 p.m.", "No, you you have to add by yourself. I have given you full access.",
                      "Why you are asking me at every single click? I already said you to book the meeting 7:00 p.m. today. I am not guiding you.",
                      "try again", "yes do it", "you have access now", "tomorrow at 3 pm"] {
            #expect(open.continued(by: words), "\(words)")
        }
    }

    @Test func aNewRequestOrAQuestionIsItsOwn() {
        for words in ["open safari", "hide text edit", "what's the time", "how many windows do I have", "stop", "never mind", ""] {
            #expect(!open.continued(by: words), "\(words)")
        }
    }

    @Test func itHasAWindow() {
        #expect(open.isAlive(now: 400))
        #expect(!open.isAlive(now: 401))
    }

    /// Authority and the date parser read every turn: the day and time said one turn earlier stand.
    @Test func theTimeSaidEarlierStands() throws {
        let now = try #require(Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()))
        let expected = try #require(Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: now))
        let words = open.words(adding: "Try to add the test meeting right now again")
        #expect(ReminderDue.parse(words, now: now).kind == .timed(expected))
        let twice = OpenRequest(words: words, uptime: 100).words(adding: "yes do it")
        #expect(ReminderDue.parse(twice, now: now).kind == .timed(expected))
        #expect(OpenRequest(words: twice, uptime: 100).turns.count == 3)
    }

    @Test func aDayAndAnHourSaidApartAreOneTime() throws {
        let now = try #require(Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()))
        let seven = try #require(Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: now))
        #expect(ReminderDue.parse("All right, yes. Today, a jar with taste meeting at 7:00 p.m.", now: now).kind == .timed(seven))
        #expect(ReminderDue.parse("Today a meeting at 7pm", now: now).kind == .timed(seven))
        // Two days, or two hours, are still a question.
        #expect(ReminderDue.parse("tomorrow or friday", now: now).kind != .timed(seven))
        if case .ambiguous = ReminderDue.parse("3 pm and 5 pm", now: now).kind {} else { Issue.record("two hours must ask") }
    }

    @Test func aTitleIsTheOwnersWords() {
        let heard = "All right now, set a test meeting with Jarvis at seven pm today."
        #expect(OwnerWordsTitle.strangeWords("test meeting with Jarvis", heard: heard).isEmpty)
        #expect(OwnerWordsTitle.strangeWords("Test Meeting", heard: heard).isEmpty)
        #expect(OwnerWordsTitle.strangeWords("test meeting with Jarvis today at 7pm", heard: heard).isEmpty)
        #expect(OwnerWordsTitle.strangeWords("Meeting with Tim today at 7pm", heard: heard) == ["tim"])
        // A plural or a tense is still theirs.
        #expect(OwnerWordsTitle.strangeWords("Meetings", heard: heard).isEmpty)
        #expect(OwnerWordsTitle.strangeWords("Call Mom", heard: "remind me to call mom at 5 pm").isEmpty)
    }

    @Test func aQuestionAlreadyAnsweredIsNotAsked() throws {
        let now = try #require(Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()))
        let words = "set a test meeting with Jarvis at seven pm today\ntry again"
        #expect(AgentLoop.alreadyGiven(question: "What day and time should the meeting be?", heard: words, now: now) != nil)
        #expect(AgentLoop.alreadyGiven(question: "What should I call it?", heard: words, now: now) == nil)
        #expect(AgentLoop.alreadyGiven(question: "What time?", heard: "add a meeting with Sam", now: now) == nil)
    }
}

@MainActor
struct AnotherRouteTests {
    @Test func makingSomethingIsTheWholeRequest() {
        for words in ["book the meeting 7:00 p.m. today", "set a test meeting with Jarvis at seven pm today", "can you add an event tomorrow", "uh please create a note"] {
            #expect(RealtimeHeardCheck.asksToMakeSomething(words), "\(words)")
        }
        for words in ["press the add button", "open the calculator", "hide text edit", "what is on my calendar"] {
            #expect(!RealtimeHeardCheck.asksToMakeSomething(words), "\(words)")
        }
    }

    @Test func aGuardIsNeverRoutedAround() {
        for error in ["confirmationRequired", "confirmationDenied", "killSwitch", "kernelRefused", "heardNamedMismatch", "ambiguousApp", "ownerActive", "targetIsHarnessItself"] {
            #expect(!RealtimeHeardCheck.failuresWithAnotherRoute.contains(error), "\(error)")
        }
        #expect(RealtimeHeardCheck.failuresWithAnotherRoute.contains("calendarNotAuthorized"))
    }

    @Test func pageUnreadIsForGoalsThatReadAPage() {
        #expect(AgentLoop.asksToReadAPage("summarise this page"))
        #expect(AgentLoop.asksToReadAPage("read this page and summarise it"))
        #expect(!AgentLoop.asksToReadAPage("where did my downloads go"))
    }

    @Test func anEventTypedIntoTheWindowIsReadBack() async {
        let typed = AgentLoop.Receipt(step: 2, toolName: RealtimeVoiceVerbs.typeTextName, ok: true, error: nil, typed: "test meeting with Jarvis today at 7pm")
        let made = AgentLoop.Receipt(step: 2, toolName: RealtimeVoiceVerbs.createEventName, ok: true, error: nil, typed: "test meeting")
        let heard = "set a test meeting with Jarvis at seven pm today"
        #expect(AgentLoop.eventTypedInWindow(heard: heard, receipts: [typed]) == typed.typed)
        #expect(AgentLoop.eventTypedInWindow(heard: heard, receipts: [typed, made]) == nil)
        #expect(AgentLoop.eventTypedInWindow(heard: "type hello into notes", receipts: [typed]) == nil)
        // The window: the title, with the date words off, is what must show. (Under a unit test EventKit is not granted, so the window is the witness.)
        #expect(await AgentLoop.eventNotReadBack("test meeting with Jarvis today at 7pm", heard: heard, screen: "Wednesday\ntest meeting with Jarvis\n7:00 PM") == nil)
        #expect(await AgentLoop.eventNotReadBack("test meeting with Jarvis today at 7pm", heard: heard, screen: "Wednesday") != nil)
        #expect(await AgentLoop.eventNotReadBack("test meeting with Jarvis today at 7pm", heard: heard, screen: nil) != nil)
    }
}
