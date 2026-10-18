//
//  RowClickSelectionTests.swift
//  leanring-buddyTests
//
//  E04 2026-10-17: a click on Reminders' sidebar row was refused clickTargetObscured
//  (its own name field sits at the row's centre), then the rerun's click on the name
//  field left the list name in edit mode. A row of a native list is selected, not
//  clicked. Pure; SYNTHETIC nodes - the live half is the E04 run.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct RowClickSelectionTests {

    func node(_ role: String, frame: CGRect = CGRect(x: 0, y: 0, width: 250, height: 18),
              value: String? = nil, frameReadFailed: Bool = false, childrenReadFailed: Bool = false) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: nil, value: value, frameInAppKitCoordinates: frame,
                                 depth: 0, children: [], frameReadFailed: frameReadFailed, childrenReadFailed: childrenReadFailed)
    }

    @Test func aClickOnANativeOutlineOrTableRowIsASelection() {
        let outline = ["AXWindow", "AXSplitGroup", "AXScrollArea", "AXOutline"].map { node($0) }
        #expect(HarnessPolicy.clickSelectsRow(chain: outline + [node("AXRow")], forced: nil))
        #expect(HarnessPolicy.clickSelectsRow(chain: outline + [node("AXRow"), node("AXCell")], forced: nil))
        let table = ["AXWindow", "AXScrollArea", "AXTable", "AXRow"].map { node($0) }
        #expect(HarnessPolicy.clickSelectsRow(chain: table, forced: nil))
        // A forced method is the caller's: it clicks.
        #expect(!HarnessPolicy.clickSelectsRow(chain: outline + [node("AXRow")], forced: .click))
        // A web row's selection would run none of the page's click handlers.
        let web = ["AXWindow", "AXWebArea", "AXTable", "AXRow"].map { node($0) }
        #expect(!HarnessPolicy.clickSelectsRow(chain: web, forced: nil))
        // Not a row of a list, and not a control inside the row: unchanged.
        #expect(!HarnessPolicy.clickSelectsRow(chain: ["AXWindow", "AXGroup", "AXRow"].map { node($0) }, forced: nil))
        #expect(!HarnessPolicy.clickSelectsRow(chain: outline + [node("AXRow"), node("AXCell"), node("AXTextField")], forced: nil))
        #expect(!HarnessPolicy.clickSelectsRow(chain: outline + [node("AXRow"), node("AXButton")], forced: nil))
        #expect(!HarnessPolicy.clickSelectsRow(chain: [node("AXRow")], forced: nil))
    }

    @Test func aClickOnAnUnselectedRowsOnlyNameFieldSelectsTheRow() {
        // Live 2026-10-19, Reminders' sidebar: AXOutline > AXRow > AXCell > AXUnknown > AXTextField "Shopping".
        func row(selected: Bool?, fields: Int) -> [AccessibilityElementNode] {
            let field = node("AXTextField", value: "Shopping")
            let extra = (1..<max(fields, 1)).map { _ in node("AXTextField", value: "Add Time") }
            let unknown = AccessibilityElementNode(role: "AXUnknown", subrole: nil, title: nil, value: nil,
                                                   frameInAppKitCoordinates: .zero, depth: 0, children: [field] + extra)
            let cell = AccessibilityElementNode(role: "AXCell", subrole: nil, title: nil, value: nil,
                                                frameInAppKitCoordinates: .zero, depth: 0, children: [unknown])
            let rowNode = AccessibilityElementNode(role: "AXRow", subrole: nil, title: nil, value: nil,
                                                   frameInAppKitCoordinates: .zero, depth: 0, children: [cell], selected: selected)
            return [node("AXWindow"), node("AXOutline"), rowNode, cell, unknown, field]
        }
        #expect(HarnessPolicy.clickSelectsRow(chain: row(selected: false, fields: 1), forced: nil))
        // A selected row's field is edited, as a second click does; unknown selection changes nothing.
        #expect(!HarnessPolicy.clickSelectsRow(chain: row(selected: true, fields: 1), forced: nil))
        #expect(!HarnessPolicy.clickSelectsRow(chain: row(selected: nil, fields: 1), forced: nil))
        // A row with several fields (a reminder being edited) keeps its fields clickable.
        #expect(!HarnessPolicy.clickSelectsRow(chain: row(selected: false, fields: 2), forced: nil))
        #expect(!HarnessPolicy.clickSelectsRow(chain: row(selected: false, fields: 1), forced: .axFocus))
    }
}
