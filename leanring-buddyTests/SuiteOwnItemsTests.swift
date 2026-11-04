//
//  SuiteOwnItemsTests.swift
//  leanring-buddyTests
//
//  A test note is taken back by the id in its row, never by its title (2026-11-04). Pure; the removal itself was proven live.
//

import Foundation
import Testing
@testable import Clicky

struct SuiteNoteIdentityTests {
    private let item = SuiteOwnItems.Item(bundle: GeneralitySuite.notes, title: "jarvis test 1")

    @Test func aNoteIsKnownByTheIdInItsRow() {
        #expect(SuiteOwnItems.noteID(fromIdentifier: "ICMNoteListCell, Note[id=2EEA29D8-E7C5-4E9D-9DE2-FF6CDF83E4A1]") == "2EEA29D8-E7C5-4E9D-9DE2-FF6CDF83E4A1")
        #expect(SuiteOwnItems.noteID(fromIdentifier: "_NS:44") == nil)
        #expect(SuiteOwnItems.noteID(fromIdentifier: "Note[id=]") == nil)
    }

    @Test func onlyWhatTheTaskMadeGoes() {
        let rows = [(id: "new", title: "JARVIS test 1"), (id: "older", title: "JARVIS test 1"), (id: "owner", title: "Groceries"),
                    (id: "synced", title: "Groceries 2"), (id: "blank", title: "New Note")]
        #expect(SuiteOwnItems.notesMadeByTask(item, before: ["older", "owner"], rows: rows) == ["new", "blank"],
                "an older note of the same title stays, and so does a new note of another title")
        #expect(SuiteOwnItems.notesMadeByTask(item, before: Set(rows.map(\.id)), rows: rows).isEmpty)
    }

    @Test func theRowsOwnActionAndTheFoldersCount() {
        #expect(SuiteOwnItems.binAction(among: ["Name:pin\nTarget:0x0\nSelector:(null)", "Name:bin\nTarget:0x0\nSelector:(null)"]) == "Name:bin\nTarget:0x0\nSelector:(null)")
        #expect(SuiteOwnItems.binAction(among: ["AXShowMenu", "Name:binder\nTarget:0x0"]) == nil)
        #expect(SuiteOwnItems.noteCount(inWindowTitle: "Notes – 21 notes") == 21)
        #expect(SuiteOwnItems.noteCount(inWindowTitle: "Work – 1 note") == 1)
        #expect(SuiteOwnItems.noteCount(inWindowTitle: "Notes") == nil)
    }
}
