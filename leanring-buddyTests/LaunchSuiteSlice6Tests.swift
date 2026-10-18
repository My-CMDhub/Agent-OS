//
//  LaunchSuiteSlice6Tests.swift
//  leanring-buddyTests
//
//  Slice 6's pure checkers on hand-built readings: both branches of M04, M05's size
//  reading, M06's diff. Whether Reminders' All list reads as rows is the live run's question.
//

import Foundation
import Testing
@testable import Clicky

struct LaunchSuiteSlice6Tests {
    typealias Suite = GeneralitySuite

    @Test func onlyIncompleteChargeRowsCountOnceTodayHasLoaded() {
        let rows: [(description: String, title: String?)] = [(description: "Incomplete, Charge my Mac", title: "Charge my Mac"),
                                                             (description: "Completed, charging cable", title: nil),
                                                             (description: "Incomplete, milk", title: "milk")]
        #expect(Suite.incompleteRows(buttons: ["All, 7 reminders"], rows: rows, phrases: Suite.chargePhrases) == nil)
        #expect(Suite.incompleteRows(buttons: ["Today, 0 reminders"], rows: rows, phrases: Suite.chargePhrases) == ["Incomplete, Charge my Mac"])
    }

    @Test func aLeftoverReminderOrAnUnreadableReadingSkipsTheBranch() {
        #expect(Suite.chargeSkipReason(battery: 68, before: []) == nil)
        #expect(Suite.chargeSkipReason(battery: nil, before: []) != nil)
        #expect(Suite.chargeSkipReason(battery: 68, before: nil) != nil)
        #expect(Suite.chargeSkipReason(battery: 68, before: ["Incomplete, Charge Mac"]) != nil)
    }

    /// Below 95: exactly one new charge reminder; an answer alone, or two reminders, fails.
    @Test func belowNinetyFiveTheBranchIsAReminder() {
        let one = ["Incomplete, Charge my Mac"]
        #expect(Suite.branchVerdict(batteryBefore: 68, batteryAfter: 67, before: [], after: one, spoken: "Done.")["passed"] as? Bool == true)
        #expect(Suite.branchVerdict(batteryBefore: 68, batteryAfter: 67, before: [], after: [], spoken: "Your battery is at 68%.")["passed"] as? Bool == false)
        #expect(Suite.branchVerdict(batteryBefore: 68, batteryAfter: 67, before: [], after: one + one, spoken: "Done.")["passed"] as? Bool == false)
        #expect(Suite.branchVerdict(batteryBefore: 68, batteryAfter: 67, before: nil, after: one, spoken: "Done.")["passed"] as? Bool == false)
    }

    /// At or above 95: no reminder, and the level (±2) in the answer.
    @Test func atOrAboveNinetyFiveTheBranchIsTheLevel() {
        #expect(Suite.branchVerdict(batteryBefore: 97, batteryAfter: 97, before: [], after: [], spoken: "You're at 98 percent.")["passed"] as? Bool == true)
        #expect(Suite.branchVerdict(batteryBefore: 95, batteryAfter: 95, before: [], after: [], spoken: "95%, no reminder needed.")["passed"] as? Bool == true)
        #expect(Suite.branchVerdict(batteryBefore: 97, batteryAfter: 97, before: [], after: [], spoken: "It's at 90 percent.")["passed"] as? Bool == false)
        #expect(Suite.branchVerdict(batteryBefore: 97, batteryAfter: 97, before: [], after: ["Incomplete, Charge"], spoken: "97%")["passed"] as? Bool == false)
        // Crossing 95 during the run makes either branch honest.
        #expect(Suite.branchVerdict(batteryBefore: 95, batteryAfter: 94, before: [], after: ["Incomplete, Charge"], spoken: "Done.")["passed"] as? Bool == true)
    }

    @Test func aSizeIsReadInAnyCommonUnitWithinTenPercent() {
        let bytes = 3_000_000
        #expect(Suite.namesFileAndSize("JARVIS biggest file\nbig-video.mov — 3 MB", stem: "big-video", bytes: bytes))
        #expect(Suite.namesFileAndSize("Biggest: big video (2.86 MB)", stem: "big-video", bytes: bytes))
        #expect(Suite.namesFileAndSize("big-video.mov, 3,000,000 bytes", stem: "big-video", bytes: bytes))
        #expect(Suite.namesFileAndSize("big-video.mov 2,930 KB", stem: "big-video", bytes: bytes))
        #expect(Suite.namesFileAndSize("big-video.mov 2.86 MiB", stem: "big-video", bytes: bytes))
        #expect(!Suite.namesFileAndSize("big-video.mov 3 GB", stem: "big-video", bytes: bytes))
        #expect(!Suite.namesFileAndSize("big-video.mov is the biggest", stem: "big-video", bytes: bytes))
        #expect(!Suite.namesFileAndSize("report-draft.txt 3 MB", stem: "big-video", bytes: bytes))
        let biggest = Suite.biggestFixtureFile()
        #expect(biggest.name == "big-video.mov" && biggest.stem == "big-video" && biggest.bytes == 3_000_000)
    }

    @Test func aBiggestFileNoteMustBeNewAndCarryBothFacts() {
        let grew: [String: Any] = ["passed": true, "countBefore": 0, "countAfter": 1]
        let holds = { (text: String) in Suite.namesFileAndSize(text, stem: "big-video", bytes: 3_000_000) }
        #expect(Suite.noteVerdict(created: grew, title: Suite.biggestNoteTitle, texts: ["JARVIS biggest file\nbig-video.mov, 3 MB"], holds: holds)["passed"] as? Bool == true)
        #expect(Suite.noteVerdict(created: grew, title: Suite.biggestNoteTitle, texts: ["JARVIS biggest file\nbig-video.mov"], holds: holds)["passed"] as? Bool == false)
    }

    /// M06: Paid created, both PDFs inside it, nothing else changed.
    @Test func paidMustHoldBothInvoicesAndNothingElseMoves() {
        let before = ["invoice-a.pdf": "a", "invoice-b.pdf": "b", "notes.txt": "n"]
        let after = ["Paid": "dir", "Paid/invoice-a.pdf": "a", "Paid/invoice-b.pdf": "b", "notes.txt": "n"]
        let files = ["invoice-a.pdf", "invoice-b.pdf"]
        #expect(Suite.moveVerdict(before: before, after: after, folder: "Paid", files: files)["passed"] as? Bool == true)
        var oneLeft = after
        oneLeft["Paid/invoice-b.pdf"] = nil
        oneLeft["invoice-b.pdf"] = "b"
        #expect(Suite.moveVerdict(before: before, after: oneLeft, folder: "Paid", files: files)["passed"] as? Bool == false)
        #expect(Suite.moveVerdict(before: before, after: before, folder: "Paid", files: files)["passed"] as? Bool == false)
    }
}
