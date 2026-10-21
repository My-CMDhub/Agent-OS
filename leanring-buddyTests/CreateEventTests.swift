//
//  CreateEventTests.swift
//  leanring-buddyTests
//
//  create_event's pure half (the EventKit write and read-back are proven live, not here): the wire
//  and its invitee refusal, the start from the owner's words (an hour, a spoken range, all-day), the
//  refusals that ask, and the ask_owner answer read on the task's own day (2026-10-21's bug: joined
//  with a space, "at 5 today" + "5 pm" read as two times and asked again).
//

import Foundation
import Testing
@testable import Clicky

struct CreateEventTests {
    let calendar = HarnessCreateReminder.fixedCalendar()
    var now: Date { calendar.date(bySettingHour: 9, minute: 34, second: 0, of: Date())! }
    func at(_ hour: Int, _ minute: Int = 0, plusDays days: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: days, to: now)!)!
    }
    func plan(_ title: String, _ heard: String) -> Result<HarnessCreateEvent.Plan, HarnessCreateReminder.Failure> {
        HarnessCreateEvent.plan(title: title, heard: heard, now: now, calendar: calendar)
    }

    @Test func theWireCarriesTheOwnersWordsAndNeverAnInvitee() throws {
        let call = RealtimeToolCall.parsed(callID: "1", name: RealtimeVoiceVerbs.createEventName,
                                           arguments: ["title": "Team sync", "calendar": "Work", "words": "at 3 pm"])
        #expect(call.words == nil && call.text == "Team sync" && call.elementName == "Work" && call.path == nil)
        var heard = call
        heard.words = "add team sync tomorrow at 3 pm"
        let sent = try JSONSerialization.jsonObject(with: Data(RealtimeOpenAppTool.harnessRequestLine(for: heard).get().utf8)) as? [String: Any]
        #expect(sent?["verb"] as? String == "createEvent" && sent?["text"] as? String == "add team sync tomorrow at 3 pm")
        #expect(sent?["title"] as? String == "Team sync" && sent?["withinNamed"] as? String == "Work")
        var invited = RealtimeToolCall.parsed(callID: "2", name: RealtimeVoiceVerbs.createEventName,
                                              arguments: ["title": "Team sync", "attendees": ["bob@example.com"]])
        invited.words = "add team sync tomorrow at 3 pm with Bob"
        guard case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(for: invited) else { Issue.record("an invitee must refuse"); return }
        #expect(refusal.error == "noInvitees")
        let decoded = try HarnessPolicy.decode(line: "{\"verb\":\"createEvent\",\"title\":\"Team sync\",\"text\":\"tomorrow at 3 pm\"}").get()
        #expect(decoded.verb == .createEvent && decoded.verb.isMutating)
    }

    @Test func theStartIsTheOwnersAndAnHourLongUnlessTheySaidAnEnd() throws {
        let meeting = try plan("JARVIS test meeting tomorrow at 3 pm", "add a meeting called JARVIS test meeting tomorrow at 3 pm to my calendar").get()
        #expect(meeting.title == "JARVIS test meeting" && meeting.titleWasCleaned && !meeting.allDay)
        #expect(meeting.start == at(15, plusDays: 1) && meeting.end == at(16, plusDays: 1))
        let ranged = try plan("Review", "put a review in my calendar tomorrow from 3 to 4:30 pm").get()
        #expect(ranged.start == at(15, plusDays: 1) && ranged.end == at(16, 30, plusDays: 1))
        let allDay = try plan("Offsite", "add the offsite to my calendar tomorrow").get()
        #expect(allDay.allDay && allDay.start == calendar.startOfDay(for: at(0, plusDays: 1)))
        #expect(HarnessCreateEvent.spokenReadBack(meeting, calendarName: "Home", now: now, calendar: calendar)
            == "JARVIS test meeting, Tomorrow from 3:00 pm to 4:00 pm, in your Home calendar")
    }

    @Test func noTimeOrAnUnclearOneAsksAndCreatesNothing() {
        for (heard, code) in [("add a meeting with the team to my calendar", "eventTimeMissing"),
                              ("add a meeting at 5 today", "eventTimeUnclear"), ("add a meeting at 9 am today", "eventTimeUnclear")] {
            guard case .failure(let failure) = plan("Meeting", heard) else { Issue.record("\(heard) must refuse"); continue }
            #expect(failure.code == code && failure.message.contains("ask_owner"), "\(heard)")
        }
    }

    @Test func anAskOwnerAnswerIsReadOnTheTasksDay() {
        let task = "remind me to call Mom at 5 today"
        let joined = ReminderDue.joined(task, answer: "5 pm")
        let due = ReminderDue.parse(joined, now: now, calendar: calendar)
        #expect(due.kind == .timed(at(17)))
        #expect(due.phrase.map { String(joined[$0]) } == "5 pm")
        // The answer's own day wins; an answer with no time keeps the task's words (still asked).
        #expect(ReminderDue.parse(ReminderDue.joined(task, answer: "tomorrow at 6 pm"), now: now, calendar: calendar).kind == .timed(at(18, plusDays: 1)))
        #expect(ReminderDue.parse(ReminderDue.joined("add a meeting tomorrow at 3", answer: "3 pm"), now: now, calendar: calendar).kind
            == .timed(at(15, plusDays: 1)))
        #expect(ReminderDue.parse(ReminderDue.joined(task, answer: "the Family list"), now: now, calendar: calendar).kind
            == .ambiguous("the hour was heard without am or pm"))
        // Both verbs: the reminder's plan and the event's read the same answer.
        guard case .success(let reminder) = HarnessCreateReminder.plan(title: "Call Mom", heard: joined, now: now, calendar: calendar) else {
            Issue.record("the answered reminder must plan"); return
        }
        #expect(reminder.due?.hour == 17 && reminder.title == "Call Mom")
        guard case .success(let event) = plan("Call with Mom", ReminderDue.joined("add a call with Mom at 5 today to my calendar", answer: "5 pm")) else {
            Issue.record("the answered event must plan"); return
        }
        #expect(event.start == at(17) && event.end == at(18))
    }

    @MainActor @Test func theReceiptCountsForMakingClaims() {
        let made = AgentLoop.Receipt(step: 1, toolName: RealtimeVoiceVerbs.createEventName, ok: true, error: nil, typed: "JARVIS test meeting")
        #expect(AgentLoop.doneChallenge(summary: "I added a meeting called \"JARVIS test meeting\" to your calendar.", evidence: [1], receipts: [made]) == nil)
        #expect(AgentLoop.doneChallenge(summary: "I scheduled the JARVIS test meeting.", evidence: [1], receipts: [made]) == nil)
        let refused = AgentLoop.Receipt(step: 1, toolName: RealtimeVoiceVerbs.createEventName, ok: false, error: "eventTimeMissing")
        #expect(AgentLoop.doneChallenge(summary: "I added the meeting.", evidence: [], receipts: [refused]) != nil)
        #expect(AgentLoop.unsetClockTime(heard: "add a meeting tomorrow at 3 pm", receipts: [made], screen: "Finder") == nil)
        #expect(AgentLoop.namingTools.contains(RealtimeVoiceVerbs.createEventName))
    }

    @Test func theNoteSpeaksOnlyForEvents() {
        let locale = Locale(identifier: "en_AU")
        let timed = HarnessCreateEvent.note(heard: "add a meeting called JARVIS test meeting tomorrow at 3 pm to my calendar",
                                            now: now, calendar: calendar, locale: locale)
        #expect(timed?.contains("create_event") == true && timed?.contains("Tomorrow 3:00 pm") == true)
        #expect(HarnessCreateEvent.note(heard: "add a meeting to my calendar", now: now, calendar: calendar, locale: locale)?.contains("ask_owner") == true)
        #expect(HarnessCreateEvent.note(heard: "remind me about the meeting at 5 pm", now: now, calendar: calendar, locale: locale) == nil)
        #expect(HarnessCreateEvent.note(heard: "open Safari", now: now, calendar: calendar, locale: locale) == nil)
    }
}
