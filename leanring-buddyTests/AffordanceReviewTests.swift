//
//  AffordanceReviewTests.swift
//  leanring-buddyTests
//
//  Review of 9adf53f..e98f476: the offer is exactly what the model was shown;
//  dynamic, personal menu lists (recent files, the Window menu's window list,
//  mailbox / folder / device lists, document-like titles) never reach the map
//  sent up front, recognised by position and shape, never by app name, and
//  stay reachable through find_menu_items; landmark names stay quoted; two
//  instances of one app keep two maps.
//

import Foundation
import Testing
@testable import Clicky

private func item(_ path: [String], shortcut: String? = nil, enabled: Bool = true) -> [String: Any] {
    ["path": path, "enabled": enabled, "shortcut": shortcut ?? NSNull(), "hasSubmenu": false]
}

struct AffordanceReviewTests {

    @Test func theOfferIsExactlyTheShownLines() throws {
        var items = (0..<150).map { item(["View", "Item \($0)"]) }
        items.append(item(["File", "New Folder"], shortcut: "⇧⌘N"))
        let map = try #require(AffordanceMap(menusResponse: ["ok": true, "items": items], bundleIdentifier: "b", version: "1", pid: 1, builtUptime: 0))
        let shown = map.menuLines(readOnly: false)
        let offer = map.offer(readOnly: false)
        #expect(offer.candidates.count == shown.count)
        #expect(offer.candidates.map { $0.path.joined(separator: " > ") } == shown)
        #expect(!offer.candidates.contains { $0.path == ["View", "Item 149"] }, "a line cut by the budget is no offer")
        #expect(!map.offer(readOnly: true).candidates.contains { $0.path == ["File", "New Folder"] })
    }
}
