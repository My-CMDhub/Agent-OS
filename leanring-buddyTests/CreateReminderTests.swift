//
//  CreateReminderTests.swift
//  leanring-buddyTests
//
//  create_reminder's pure half: the wire, the title cleaned of the owner's date words, the due as
//  EventKit components (all-day = a date only), the ambiguity refusal, and the agent loop counting an
//  ok create as a making receipt. The EventKit write and read-back are proven live, not here.
//

import Foundation
import Testing
@testable import Clicky

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

struct CreateReminderTests {
    let calendar = HarnessCreateReminder.fixedCalendar()
    var now: Date { calendar.date(bySettingHour: 9, minute: 34, second: 0, of: Date())! }

    // MARK: The wire

    @Test func theVerbNeedsATitleAndTheOwnersWords() throws {
        let ok = try HarnessPolicy.decode(line: line(["verb": "createReminder", "title": "Call Mom", "text": "remind me to call Mom",
                                                      "withinNamed": "Family"])).get()
        #expect(ok.verb == .createReminder && ok.verb.isMutating)
        #expect(ok.title == "Call Mom", "the audit line names the reminder")
        #expect(ok.text == "remind me to call Mom" && ok.withinNamed == "Family")
        for (raw, field) in [(["verb": "createReminder", "text": "x"], "title"), (["verb": "createReminder", "title": "x"], "text")] {
            guard case .failure(.missingField(field)) = HarnessPolicy.decode(line: line(raw)) else { Issue.record("no \(field) must refuse"); continue }
        }
        guard case .failure(.invalidField(field: "title", _)) = HarnessPolicy.decode(
            line: line(["verb": "createReminder", "title": "a\nb", "text": "x"])) else { Issue.record("a control character must refuse"); return }
    }

    @Test func theModelNeverSuppliesTheDue() throws {
        // The model's `words` are dropped at parse; runToolCall alone sets them to the owner's words.
        let call = RealtimeToolCall.parsed(callID: "1", name: RealtimeVoiceVerbs.createReminderName,
                                           arguments: ["title": "Call Mom", "list": "Family", "words": "at 5 pm today"])
        #expect(call.words == nil && call.text == "Call Mom" && call.elementName == "Family" && call.appName == nil)
        guard case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(for: call) else { Issue.record("no heard words must refuse"); return }
        #expect(refusal.error == "heardUnavailable")
        var heard = call
        heard.words = "remind me to call Mom at 5 pm today"
        let sent = try JSONSerialization.jsonObject(with: Data(RealtimeOpenAppTool.harnessRequestLine(for: heard).get().utf8)) as? [String: Any]
        #expect(sent?["verb"] as? String == "createReminder" && sent?["text"] as? String == "remind me to call Mom at 5 pm today")
        #expect(sent?["title"] as? String == "Call Mom" && sent?["withinNamed"] as? String == "Family")
    }

    // MARK: The plan

    @Test func theTitleLosesTheOwnersDateWords() {
        #expect(HarnessCreateReminder.cleanedTitle("Call Mom at 5 pm today", removing: "at 5 pm today") == "Call Mom")
        #expect(HarnessCreateReminder.cleanedTitle("Review big-video.mov tomorrow", removing: "tomorrow") == "Review big-video.mov")
        #expect(HarnessCreateReminder.cleanedTitle("Call Mom", removing: "at 5 pm today") == "Call Mom")
        #expect(HarnessCreateReminder.cleanedTitle("Call   Mom  AT 5 PM TODAY", removing: "at 5 pm today") == "Call Mom")
        guard case .success(let plan) = HarnessCreateReminder.plan(title: "Call Mom at 5 pm today", heard: "remind me to call Mom at 5 pm today",
                                                                   now: now, calendar: calendar) else { Issue.record("a clear time must plan"); return }
        #expect(plan.title == "Call Mom" && plan.titleWasCleaned)
    }

    @Test func aTimedDueCarriesItsClockAndAnAllDayDueOnlyADate() {
        guard case .success(let timed) = HarnessCreateReminder.plan(title: "Call Mom", heard: "remind me to call Mom at 5 pm today",
                                                                    now: now, calendar: calendar) else { Issue.record("timed"); return }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        #expect(timed.due?.year == today.year && timed.due?.day == today.day && timed.due?.hour == 17 && timed.due?.minute == 0)
        #expect(timed.due?.calendar?.identifier == .gregorian && timed.due?.timeZone == .current)
        guard case .success(let allDay) = HarnessCreateReminder.plan(title: "Review it", heard: "remind me to review it tomorrow",
                                                                     now: now, calendar: calendar) else { Issue.record("all-day"); return }
        #expect(allDay.due?.day != nil && allDay.due?.hour == nil && allDay.due?.minute == nil, "a date only is what EventKit files all-day")
        guard case .success(let none) = HarnessCreateReminder.plan(title: "Charge my Mac", heard: "remind me to charge my Mac",
                                                                   now: now, calendar: calendar) else { Issue.record("none"); return }
        #expect(none.due == nil)
    }

    @Test func anUnclearDueIsAskedAndNothingIsWritten() {
        for heard in ["remind me to call Mom at 5 today", "remind me at 9 am to stretch", "remind me at 5 pm today and tomorrow"] {
            guard case .failure(let failure) = HarnessCreateReminder.plan(title: "x", heard: heard, now: now, calendar: calendar) else {
                Issue.record("\(heard) must be asked"); continue
            }
            #expect(failure.code == "reminderDueUnclear" && failure.message.contains("ask_owner"))
        }
        guard case .failure(let empty) = HarnessCreateReminder.plan(title: "at 5 pm today", heard: "remind me at 5 pm today",
                                                                    now: now, calendar: calendar) else { Issue.record("an all-date title"); return }
        #expect(empty.code == "reminderTitleEmpty")
    }

    @Test func aListIsTakenOnlyByItsExactName() {
        #expect(HarnessCreateReminder.exactList(named: "Family", among: ["Reminders", "Family"]) == 1)
        #expect(HarnessCreateReminder.exactList(named: "family", among: ["Reminders", "Family"]) == nil, "never nearest")
        #expect(HarnessCreateReminder.exactList(named: "Work", among: ["Work", "Work"]) == nil)
        #expect(HarnessCreateReminder.exactList(named: nil, among: ["Reminders"]) == nil)
    }

    @Test func theReadBackComparesTheDayAndTheClock() {
        var wanted = DateComponents(year: 2026, month: 10, day: 21, hour: 17, minute: 0)
        var read = wanted
        read.second = 0
        #expect(HarnessCreateReminder.sameDue(read, wanted))
        read.hour = 5
        #expect(!HarnessCreateReminder.sameDue(read, wanted))
        wanted = DateComponents(year: 2026, month: 10, day: 22)
        #expect(HarnessCreateReminder.sameDue(DateComponents(year: 2026, month: 10, day: 22), wanted))
        #expect(!HarnessCreateReminder.sameDue(nil, wanted) && HarnessCreateReminder.sameDue(nil, nil))
        let spoken = HarnessCreateReminder.spokenReadBack(title: "Call Mom", due: DateComponents(calendar: calendar, timeZone: calendar.timeZone,
            year: calendar.component(.year, from: now), month: calendar.component(.month, from: now), day: calendar.component(.day, from: now),
            hour: 17, minute: 0), list: "Reminders", now: now, calendar: calendar)
        #expect(spoken == "Call Mom, Today at 5:00 pm, in your Reminders list")
    }

    // MARK: The loop

    @MainActor @Test func anOkCreateIsAMakingReceipt() {
        let made = AgentLoop.Receipt(step: 1, toolName: RealtimeVoiceVerbs.createReminderName, ok: true, error: nil, typed: "Call Mom")
        #expect(AgentLoop.doneChallenge(summary: "I added a reminder to call Mom today at 5 pm.", evidence: [1], receipts: [made]) == nil)
        #expect(AgentLoop.doneChallenge(summary: "I created a reminder called \"Call Mom\".", evidence: [1], receipts: [made]) == nil)
        let refused = AgentLoop.Receipt(step: 1, toolName: RealtimeVoiceVerbs.createReminderName, ok: false, error: "reminderDueUnclear")
        #expect(AgentLoop.doneChallenge(summary: "I added a reminder to call Mom.", evidence: [], receipts: [refused]) != nil)
        // The due came from the owner's words and was read back: no screen holds it to judge by.
        #expect(AgentLoop.unsetClockTime(heard: "remind me to call Mom at 5 pm today", receipts: [made], screen: "Finder") == nil)
        #expect(AgentLoop.namingTools.contains(RealtimeVoiceVerbs.createReminderName))
    }

    @MainActor @Test func theStructuredNotePointsAtTheTool() {
        let locale = Locale(identifier: "en_AU")
        let timed = ReminderDue.note(heard: "remind me to call Mom at 5 pm today", now: now, calendar: calendar, locale: locale, structured: true)
        #expect(timed?.hasPrefix("Owner's due time, parsed from their words: Today 5:00 pm (timed).") == true)
        #expect(timed?.contains("create_reminder") == true && timed?.contains("Add Time") == false)
        #expect(ReminderDue.note(heard: "remind me to call Mom at 5 today", now: now, calendar: calendar, locale: locale, structured: true)?
            .contains("ask_owner") == true)
    }
}
