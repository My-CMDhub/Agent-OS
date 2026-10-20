//
//  ReminderDueTests.swift
//  leanring-buddyTests
//
//  The owner's due words, read with a fixed "now" (today 09:34) and en_AU: the traps
//  measured 2026-10-21 (invented noon, no roll-forward, a bare hour made pm) each asked or ruled.
//

import Foundation
import Testing
@testable import Clicky

struct ReminderDueTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()
    var now: Date { calendar.date(bySettingHour: 9, minute: 34, second: 0, of: Date())! }
    func at(_ hour: Int, _ minute: Int = 0, plusDays days: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: days, to: now)!)!
    }
    func parse(_ words: String) -> ReminderDue { ReminderDue.parse(words, now: now, calendar: calendar) }
    func phrase(_ words: String) -> String? { parse(words).phrase.map { String(words[$0]) } }

    @Test func aStatedTimeIsTimedAndItsWordsAreKnown() {
        #expect(parse("remind me to call Mom at 5 pm today").kind == .timed(at(17)))
        #expect(phrase("remind me to call Mom at 5 pm today") == "at 5 pm today")
        #expect(parse("remind me at 5:30pm tomorrow to buy milk").kind == .timed(at(17, 30, plusDays: 1)))
    }

    @Test func aDateOnlyPhraseIsAllDayNotAnInventedNoon() {
        #expect(parse("remind me to review it tomorrow").kind == .allDay(calendar.startOfDay(for: at(0, plusDays: 1))))
    }

    @Test func aPastTimeAndABareHourAreAskedNeverPicked() {
        guard case .ambiguous(let past) = parse("remind me at 9 am to stretch").kind else { Issue.record("9 am at 09:34 was not asked"); return }
        #expect(past.contains("9:00 am"))
        #expect(parse("remind me to call Mom at 5 today").kind == .ambiguous("the hour was heard without am or pm"))
        #expect(parse("remind me at 5 o'clock").kind == .ambiguous("the hour was heard without am or pm"))
        #expect(parse("remind me at 5 pm today and tomorrow").kind == .ambiguous("more than one date or time was heard"))
    }

    @Test func wordsTheDetectorMissesGiveNoDue() {
        for words in ["remind me in an hour to call", "remind me next week", "remind me at half past five"] {
            #expect(parse(words) == ReminderDue(kind: .none, phrase: nil), "\(words)")
        }
    }

    @MainActor @Test func theNoteSpeaksOnlyForReminders() {
        let locale = Locale(identifier: "en_AU")
        let timed = ReminderDue.note(heard: "remind me to call Mom at 5 pm today", now: now, calendar: calendar, locale: locale)
        #expect(timed?.hasPrefix("Owner's due time, parsed from their words: Today 5:00 pm (timed).") == true)
        #expect(timed?.contains("\"at 5 pm today\"") == true)
        #expect(timed?.contains("type the time \"5:00 pm\" into the reminder's Add Time field with type_text and submit true") == true)
        #expect(ReminderDue.note(heard: "remind me to review it tomorrow", now: now, calendar: calendar, locale: locale)?
            .contains("Tomorrow (all-day, no time)") == true)
        #expect(ReminderDue.note(heard: "remind me to call Mom at 5 today", now: now, calendar: calendar, locale: locale)?
            .contains("ask_owner") == true)
        #expect(ReminderDue.note(heard: "remind me in an hour", now: now, calendar: calendar, locale: locale) == nil)
        // Not a reminder: a calendar question keeps its own path.
        #expect(ReminderDue.note(heard: "what is on at 5 pm today", now: now, calendar: calendar, locale: locale) == nil)
        // The goal the model wrote is never parsed: only the owner's words carry the line.
        #expect(!AgentLoop.goalText(goal: "remind me at 5 pm tomorrow", heard: nil).contains("parsed from their words"))
        #expect(AgentLoop.goalText(goal: "x", heard: "remind me to call Mom at 5 pm tomorrow").contains("Tomorrow 5:00 pm (timed)"))
    }
}
