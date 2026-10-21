//
//  LaunchSuiteSlice6.swift
//  leanring-buddy
//
//  Launch suite slice 6 (2026-10-19): loops harder than slice 5's straight two-app chains.
//  M04 BRANCHES on a reading (battery below 95 -> a reminder, else just the level), M05 is a
//  THREE-step chain carrying facts (find the biggest sandbox file, read its size, write both
//  into a note), M06 must RECOVER from a missing piece (the destination folder does not exist).
//  Truth is read by the checker: pmset's own percentage, Reminders' All list over AX, the
//  sandbox fixture's sizes, the Notes note's own text, the sandbox listing diff. A charge
//  reminder is marked completed when it is provably this task's, never deleted; notes are left.
//

import ApplicationServices
import EventKit
import Foundation

extension GeneralitySuite {
    static let launchSlice6: [SuiteTask] = [
        SuiteTask(id: "M04", pattern: "branch on a reading: battery -> reminder or answer",
                  words: "if my battery is below 95 percent, remind me to charge my Mac; otherwise just tell me the level",
                  apps: [reminders, settings],
                  pre: {
                      let battery = batteryPercent(pmset: output("/usr/bin/pmset", ["-g", "batt"]))
                      let before = await truthRead(.reminder, reminders, eventKit: { eventKitIncompleteReminders().map { matching($0, chargePhrases).map { reminderRow($0) } } }) { allChargeRows() }
                      return ["batteryBefore": battery as Any? ?? NSNull(), "chargeBefore": before as Any? ?? NSNull(),
                              skipReasonKey: chargeSkipReason(battery: battery, before: before) as Any? ?? NSNull()]
                  }) { spoken, run in
                      let before = run["chargeBefore"] as? [String]
                      let after = await truthRead(.reminder, reminders, eventKit: { eventKitIncompleteReminders().map { matching($0, chargePhrases).map { reminderRow($0) } } }) { allChargeRows() }
                      var result = branchVerdict(batteryBefore: run["batteryBefore"] as? Int,
                                                 batteryAfter: batteryPercent(pmset: output("/usr/bin/pmset", ["-g", "batt"])),
                                                 before: before, after: after, spoken: spoken)
                      result["truthSource"] = truthSource(.reminder)
                      let new = (after?.count ?? 0) - (before?.count ?? 0)
                      if new > 0 {
                          // Provably ours (none before, one now): completed so it cannot alert. Never deleted.
                          if before?.isEmpty == true, after?.count == 1 {
                              result["markedCompleted"] = await read { completeOnlyCallMom(phrases: chargePhrases) } ?? false
                          }
                          let done = result["markedCompleted"] as? Bool == true
                          result["leftForOwner"] = done ? "a \"charge\" reminder, marked completed (delete it in Reminders)"
                              : "\(new) \"charge\" reminder(s), NOT completed — they may alert"
                          if !done { print("🚨 M04: a charge reminder was left for the owner, not completed") }
                      }
                      return result
                  },
        SuiteTask(id: "M05", pattern: "three-step chain: biggest file -> its size -> a new note",
                  words: "find the biggest file in my JARVIS-sandbox folder, check its size, and write both into a new note titled JARVIS biggest file",
                  apps: [finder, notes], created: (notes, namesNote(biggestNoteTitle)), sandbox: [],
                  pre: { [skipReasonKey: noteSkipReason(existing: await countBeforeLaunchingIfNeeded(notes, namesNote(biggestNoteTitle)),
                                                        title: biggestNoteTitle) as Any? ?? NSNull()] }) { _, run in
                      let texts = await read { noteTexts(titled: biggestNoteTitle) } ?? nil
                      let biggest = biggestFixtureFile()
                      var result = noteVerdict(created: createdVerdict(run), title: biggestNoteTitle, texts: texts) {
                          namesFileAndSize($0, stem: biggest.stem, bytes: biggest.bytes)
                      }
                      result["truth"] = "\(biggest.name), \(biggest.bytes) bytes"
                      return result
                  },
        SuiteTask(id: "M06", pattern: "recover: move into a folder that does not exist yet (sandbox)",
                  words: "move invoice-a.pdf and invoice-b.pdf in my JARVIS-sandbox folder into a folder called Paid",
                  // No Paid in the fixture (set-up clears a leftover one: it is in `knownNames`), so the agent meets "not found" first.
                  apps: [finder], sandbox: ["Paid", "Paid/invoice-a.pdf", "Paid/invoice-b.pdf"]) { _, run in
                      moveVerdict(before: run["sandboxBefore"] as? [String: String], after: run["sandboxAfter"] as? [String: String],
                                  folder: "Paid", files: ["invoice-a.pdf", "invoice-b.pdf"])
                  },
    ]

    nonisolated static let biggestNoteTitle = "JARVIS biggest file"
    /// "charge", "charging", "charger" — folded, as `callMomCells` matches.
    nonisolated static let chargePhrases = ["charg"]

    // MARK: M04 — a branch decided by the battery

    /// Incomplete charge rows of Reminders' All smart list (every list, dated or not: an undated reminder lands in
    /// whichever list Reminders shows, M02 2026-10-17). Shown by View > Go To > All over AX (menu closed, a read-only
    /// view change); nil — never [] — when the item is missing or the rows never hold still across two reads.
    nonisolated static func allChargeRows() -> [String]? {
        guard let pid = pid(reminders), ["All", "All Reminders"].contains(where: { pressMenuPath(["View", "Go To", $0], pid: pid) }) else { return nil }
        var last: [String]?
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            // ponytail: "the view switched" is read as two equal reads after the press; a heading check needs the All list's measured shape.
            let rows = reminderButtonsAndRows().flatMap { incompleteRows(buttons: $0.buttons, rows: $0.rows, phrases: chargePhrases) }
            if let rows, rows == last { return rows }
            last = rows
        }
        return nil
    }

    /// Each incomplete row holding one of `phrases`; nil until the sidebar's Today count has loaded.
    nonisolated static func incompleteRows(buttons: [String], rows: [(description: String, title: String?)], phrases: [String]) -> [String]? {
        guard buttons.compactMap(reminderList).contains(where: { $0.name == "Today" }) else { return nil }
        return rows.map(\.description).filter { row in row.hasPrefix("Incomplete, ") && phrases.contains { folded(row).contains($0) } }
    }

    /// Skipped unless provable: an unreadable battery or rows, or an old incomplete charge reminder (a new one
    /// could not be told from it, and "remind me" with one already there has two honest answers).
    nonisolated static func chargeSkipReason(battery: Int?, before: [String]?) -> String? {
        guard battery != nil else { return "battery unreadable: no percentage in pmset -g batt" }
        guard let before else { return "Reminders' All list unreadable (the count before is unknown)" }
        return before.isEmpty ? nil : "an incomplete charge reminder already exists (left for the owner)"
    }

    /// M04: below 95 -> exactly one new incomplete charge reminder; at/above -> none, and the answer states the
    /// level (±2). A battery that crossed 95 during the run makes either branch honest.
    nonisolated static func branchVerdict(batteryBefore: Int?, batteryAfter: Int?, before: [String]?, after: [String]?, spoken: String) -> [String: Any] {
        guard let level = batteryBefore, let before, let after else {
            return ["passed": false, "truth": "unreadable", "batteryBefore": batteryBefore as Any? ?? NSNull(),
                    "readBefore": before != nil, "readAfter": after != nil]
        }
        let levels = [level, batteryAfter ?? level]
        let new = after.count - before.count
        let reminded = new == 1
        let told = new == 0 && levels.contains { saysNumber(spoken, near: $0, within: 2) }
        let passed = (levels.contains { $0 < 95 } && reminded) || (levels.contains { $0 >= 95 } && told)
        return ["passed": passed, "batteryBefore": level, "batteryAfter": batteryAfter as Any? ?? NSNull(),
                "branch": level < 95 ? "remind" : "tell", "chargeBefore": before.count, "chargeAfter": after.count,
                "levelInAnswer": levels.contains { saysNumber(spoken, near: $0, within: 2) }, "rowsSeen": after.map { String($0.prefix(120)) }]
    }

    /// Some standalone number in `text` within `within` of `truth` ("68%" yes, "2026" or "168" no).
    nonisolated static func saysNumber(_ text: String, near truth: Int, within: Int) -> Bool {
        let standalone = try! NSRegularExpression(pattern: #"(?<![0-9.])\d{1,3}(?![0-9])"#)
        return standalone.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).flatMap { Int(text[$0]) } }.contains { abs($0 - truth) <= within }
    }

    // MARK: M05 — the biggest file and its size, carried into a note

    /// The fixture's biggest file by construction (big-video.mov, 3,000,000 bytes) — from the manifest, not the answer.
    nonisolated static func biggestFixtureFile() -> (name: String, stem: String, bytes: Int) {
        let biggest = Sandbox.manifest.max { $0.value.count < $1.value.count }!
        return (biggest.key, (biggest.key as NSString).deletingPathExtension, biggest.value.count)
    }

    /// The text names the file (stem, "-" or a space) AND carries a size within 10% of `bytes`, read in decimal or
    /// binary units ("3 MB", "2.9 MB", "2.86 MiB", "3,000,000 bytes", "2,930 KB").
    nonisolated static func namesFileAndSize(_ text: String, stem: String, bytes: Int) -> Bool {
        let folded = folded(text)
        guard folded.contains(stem.lowercased()) || folded.contains(stem.lowercased().replacingOccurrences(of: "-", with: " ")) else { return false }
        let pattern = try! NSRegularExpression(pattern: #"(?<![0-9.,])(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s*(bytes?|[kmg]i?b|kilobytes?|megabytes?|gigabytes?)\b"#,
                                               options: .caseInsensitive)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[numberRange].replacingOccurrences(of: ",", with: "")) else { return false }
            let unit = text[unitRange].lowercased()
            // "2.86 MB" written for 2.86 MiB is 4.7% under 3,000,000 bytes: inside 10% either way.
            let base = pow(unit.count == 3 && unit.contains("i") ? 1024.0 : 1000.0, Double(["k": 1, "m": 2, "g": 3][unit.first!] ?? 0))
            return abs(number * base - Double(bytes)) <= Double(bytes) * 0.1
        }
    }
}
