//
//  LaunchSuiteSlice5.swift
//  leanring-buddy
//
//  Launch suite slice 5 (2026-10-17): the first multi-app workflows — find something in one
//  app, put it in another. M01 the web -> a note, M02 Finder -> a reminder, M03 a Safari page ->
//  a note. Truth is read by the checker, never taken from the answer: the Notes note's own text
//  over AX (G21's read), the Reminders row's due label after its title (E12's `dueText`), the
//  sandbox fixture's sizes (big-video.mov is the biggest by construction). Notes are left for the
//  owner; M02's reminder is marked completed when it is provably this task's, never deleted.
//

import Foundation

extension GeneralitySuite {
    static let launchSlice5: [SuiteTask] = [
        // No independent weather read exists (G19): the note must hold A temperature, not THE temperature.
        SuiteTask(id: "M01", pattern: "multi-app: web lookup -> new note", words: "look up the current temperature in Sydney and put it in a new note titled JARVIS weather",
                  apps: [notes, weather, safari, chrome], created: (notes, { $0.listedName?.raw.contains(weatherNoteTitle) == true })) { _, run in
                      let texts = await read { noteTexts(titled: weatherNoteTitle) } ?? nil
                      return noteVerdict(created: createdVerdict(run), title: weatherNoteTitle, texts: texts, holds: saysTemperature)
                  },
        // The reminder lands in whichever list Reminders shows (the owner's Shopping list on this Mac): no way to
        // aim it elsewhere without creating or changing one of the owner's lists. Rows are read across that view.
        SuiteTask(id: "M02", pattern: "multi-app: find a file -> dated reminder", words: "find the biggest file in my JARVIS-sandbox folder and remind me to review it tomorrow",
                  apps: [finder, reminders], sandbox: [],
                  pre: {
                      let before = await readLaunchingIfNeeded(reminders) { reminderButtonsAndRows().flatMap { bigVideoDue(buttons: $0.buttons, rows: $0.rows) } }
                      return ["bigVideoBefore": before as Any? ?? NSNull(), skipReasonKey: reviewSkipReason(before: before) as Any? ?? NSNull()]
                  }) { _, run in
                      let before = run["bigVideoBefore"] as? [String]
                      let after = await readLaunchingIfNeeded(reminders) { reminderButtonsAndRows().flatMap { bigVideoDue(buttons: $0.buttons, rows: $0.rows) } }
                      var result = reviewVerdict(before: before, after: after)
                      let new = (after?.count ?? 0) - (before?.count ?? 0)
                      if new > 0 {
                          // Provably ours (none before, one now): completed so it cannot alert tomorrow. Never deleted.
                          if before?.isEmpty == true, after?.count == 1 {
                              result["markedCompleted"] = await read { completeOnlyCallMom(phrases: bigVideoPhrases) } ?? false
                          }
                          let done = result["markedCompleted"] as? Bool == true
                          result["leftForOwner"] = done ? "a \"review big-video\" reminder, marked completed (delete it in Reminders)"
                              : "\(new) \"review big-video\" reminder(s), NOT completed — they will alert"
                          if !done { print("🚨 M02: a big-video reminder was left for the owner — it will alert") }
                      }
                      return result
                  },
        SuiteTask(id: "M03", pattern: "multi-app: summarise a Safari page -> new note", words: "summarise the lighthouse page I have open in Safari into a new note titled JARVIS lighthouse",
                  apps: [safari, notes], created: (notes, { $0.listedName?.raw.contains(lighthouseNoteTitle) == true }), sandbox: [Sandbox.lighthouseFile],
                  pre: { ["pageOpened": await openFixturePage(Sandbox.lighthouseFile, title: Sandbox.lighthouseTitle)] }) { _, run in
                      let texts = await read { noteTexts(titled: lighthouseNoteTitle) } ?? nil
                      var result = noteVerdict(created: createdVerdict(run), title: lighthouseNoteTitle, texts: texts) {
                          factsVerdict(spoken: $0, facts: lighthouseFacts)["passed"] as? Bool == true
                      }
                      result["factsNamedInNote"] = texts?.map { factsVerdict(spoken: $0, facts: lighthouseFacts)["factsNamed"] as? Int ?? 0 }.max() ?? 0
                      result["pageOpened"] = run["pageOpened"] as? Bool ?? false
                      result["tabClosed"] = await read { closeFixtureTab(title: Sandbox.lighthouseTitle) } ?? [:]
                      return result
                  },
    ]

    nonisolated static let weatherNoteTitle = "JARVIS weather", lighthouseNoteTitle = "JARVIS lighthouse"
    nonisolated static let bigVideoPhrases = ["big-video", "big video"]

    // MARK: M01, M03 — a note's own text (G21's read: the editor's AXTextArea value, title line first)

    /// Every name or value in Notes holding `title` (case aside); nil when Notes is not running or a read failed.
    /// ponytail: the editor shows only the selected note, so the text is read only when the new note is the one shown.
    nonisolated static func noteTexts(titled title: String) -> [String]? {
        appNodes(notes).map { nodes in
            nodes.flatMap { [$0.listedName?.raw, $0.value?.raw].compactMap { $0 } }.filter { $0.lowercased().contains(title.lowercased()) }
        }
    }

    /// "22°C", "about 18 degrees", "-3 °F", "21.5 celsius" — a number standing before a temperature unit.
    nonisolated static func saysTemperature(_ text: String) -> Bool {
        text.range(of: #"(?<![0-9])-?\d+(\.\d+)?\s*(°|º|degrees?\b|celsius\b|fahrenheit\b)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A note created (its count grew) AND some text titled with it holds what was asked for.
    nonisolated static func noteVerdict(created: [String: Any], title: String, texts: [String]?, holds: (String) -> Bool) -> [String: Any] {
        let grew = created["passed"] as? Bool == true
        let holding = texts?.contains(where: holds) ?? false
        var result = created.merging(["passed": grew && holding, "noteTextRead": texts.map { !$0.isEmpty } ?? false, "noteTextHolds": holding,
                                      "noteTextsSeen": (texts ?? []).map { String($0.prefix(160)) }]) { _, new in new }
        if let before = created["countBefore"] as? Int, let after = created["countAfter"] as? Int, after > before {
            result["leftForOwner"] = "\(after - before) note(s) titled \"\(title)\" in Notes (delete in Notes)"
        }
        return result
    }

    // MARK: M02 — a dated reminder (rows as E12 measured them: "Incomplete, <title>, <due>")

    /// Each incomplete big-video row's due text (after the title); nil until the sidebar's Today count has loaded.
    nonisolated static func bigVideoDue(buttons: [String], rows: [(description: String, title: String?)]) -> [String]? {
        guard buttons.compactMap(reminderList).contains(where: { $0.name == "Today" }) else { return nil }
        return rows.filter { row in row.description.hasPrefix("Incomplete, ") && bigVideoPhrases.contains { folded(row.description).contains($0) } }
            .map { dueText($0.description, title: $0.title) }
    }

    nonisolated static func reviewSkipReason(before: [String]?) -> String? {
        guard let before else { return "Reminders' rows unreadable" }
        return before.isEmpty ? nil : "an incomplete big-video reminder already exists (left for the owner)"
    }

    /// "Tomorrow", "Tomorrow at 9:00 am", or tomorrow's date as Calendar or the short style writes it.
    nonisolated static func saysTomorrow(_ text: String, now: Date = Date(), locale: Locale = .current) -> Bool {
        let short = DateFormatter()
        short.locale = locale
        short.dateStyle = .short
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        let text = folded(text)
        return text.contains("tomorrow") || text.contains(tomorrowDay(now: now, locale: locale).lowercased()) || text.contains(short.string(from: tomorrow))
    }

    /// M02: one more incomplete big-video reminder, and one of them is DUE tomorrow (its row, not its typed title).
    nonisolated static func reviewVerdict(before: [String]?, after: [String]?, now: Date = Date()) -> [String: Any] {
        guard let before, let after else { return ["passed": false, "truth": "unreadable (Reminders' rows did not load)", "readBefore": before != nil, "readAfter": after != nil] }
        let dueTomorrow = after.contains { saysTomorrow($0, now: now) }
        return ["passed": after.count > before.count && dueTomorrow, "bigVideoBefore": before.count, "bigVideoAfter": after.count,
                "dueTomorrow": dueTomorrow, "dueSeen": after]
    }
}
