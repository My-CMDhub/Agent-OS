//
//  AffordanceMapTests.swift
//  leanring-buddyTests
//
//  The per-app affordance map's pure parts (design 2026-10-07 §A): which menu
//  items reach the model (privacy, read-only, budget), the cache's bounds and
//  invalidation, the shortcut resolution, the map as an offer, and the
//  landmark lines. Whether the live `menus` read fills it is the live run's.
//

import Foundation
import Testing
@testable import Clicky

private func item(_ path: [String], enabled: Bool = true, shortcut: String? = nil, submenu: Bool = false) -> [String: Any] {
    ["path": path, "enabled": enabled, "shortcut": shortcut ?? NSNull(), "hasSubmenu": submenu, "role": "AXMenuItem", "marked": false]
}

private let finderMenus: [String: Any] = ["ok": true, "listingStopReasons": [String](), "items": [
    item(["File"], submenu: true),
    item(["File", "New Folder"], shortcut: "⇧⌘N"),
    item(["File", "Get Info"], enabled: false, shortcut: "⌘I"),
    item(["File", "Burn to Disc"], enabled: false),
    item(["File", "Open Recent"], submenu: true),
    item(["File", "Open Recent", "Taxes 2025.pdf"]),
    item(["File", "Get Info on \u{201C}Taxes.pdf\u{201D}"]),
    item(["View", "as List"], shortcut: "⌘2"),
    item(["View", "as Icons"], shortcut: "⌘1"),
    item(["Go", "Downloads"], shortcut: "⌥⌘L"),
    item(["Finder", "Services", "Make Sticky"]),
    item(["Edit", "Paste token sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEF"]),
    item(["Help"], submenu: true),
    item(["Help", "macOS Help"])
]]

struct AffordanceMapTests {

    @Test func buildsLeavesWithoutPrivateOrSecretItems() throws {
        let map = try #require(AffordanceMap(menusResponse: finderMenus, bundleIdentifier: "com.apple.finder", version: "15.5|1", pid: 1, builtUptime: 0))
        let paths = map.items.map(\.path)
        #expect(paths.contains(["File", "New Folder"]))
        #expect(!paths.contains(["File"]), "a submenu parent is not a leaf")
        #expect(!paths.contains { $0.contains("Open Recent") }, "Open Recent names the owner's files")
        #expect(!paths.contains { $0.last?.contains("Taxes") == true }, "an item quoting the selection is private")
        #expect(!paths.contains { $0.last?.contains("sk-ant") == true }, "a label holding a secret is dropped, never redacted into a fake path")
        #expect(map.hasHelpMenu)
    }

    @Test func linesKeepADisabledItemOnlyWithItsShortcut() throws {
        let map = try #require(AffordanceMap(menusResponse: finderMenus, bundleIdentifier: "com.apple.finder", version: "1", pid: 1, builtUptime: 0))
        let lines = map.menuLines(readOnly: false)
        // The cached enabled flag goes stale; the kernel judges it live at press time (review of e98f476).
        #expect(lines.contains("File > Get Info (⌘I)"))
        #expect(!lines.contains { $0.contains("disabled") })
        #expect(!lines.contains { $0.contains("Burn to Disc") })
        #expect(lines.contains("View > as List (⌘2)"))
        #expect(lines.contains("Go > Downloads (⌥⌘L)"))
    }

    @Test func aReadOnlyMapShowsOnlyWhatThePressWouldAllow() throws {
        let map = try #require(AffordanceMap(menusResponse: finderMenus, bundleIdentifier: "com.apple.finder", version: "1", pid: 1, builtUptime: 0))
        let lines = map.menuLines(readOnly: true)
        #expect(!lines.contains { $0.contains("New Folder") }, "File > New Folder makes something: never in a read-only map")
        #expect(lines.contains("View > as List (⌘2)"))
        #expect(lines.contains("File > Get Info (⌘I)"))
    }

    @Test func overBudgetDropsBoilerplateThenDeepItemsThenTheTail() throws {
        var items: [[String: Any]] = (0..<10).map { item(["App", "Services", "Service \($0)"]) }
        items += (0..<20).map { item(["Edit", "Deep", "Deep item \($0)"]) }
        items += (0..<150).map { item(["View", "Item \($0)"]) }
        let map = try #require(AffordanceMap(menusResponse: ["ok": true, "items": items], bundleIdentifier: "b", version: "1", pid: 1, builtUptime: 0))
        let lines = map.menuLines(readOnly: false)
        #expect(lines.count == AffordanceMap.maximumMenuLines)
        #expect(!lines.contains { $0.contains("Service ") })
        #expect(!lines.contains { $0.contains("Deep item") })
        #expect(lines.first == "View > Item 0")
    }

    @Test func aShortcutResolvesToTheOneItemThatOwnsIt() throws {
        let map = try #require(AffordanceMap(menusResponse: finderMenus, bundleIdentifier: "com.apple.finder", version: "1", pid: 1, builtUptime: 0))
        let offer = map.offer(readOnly: false)
        #expect(AffordanceMap.resolve(shortcut: "cmd+shift+n", in: offer) == .success(["File", "New Folder"]))
        #expect(AffordanceMap.resolve(shortcut: "⌘2", in: offer) == .success(["View", "as List"]))
        if case .failure(let refusal) = AffordanceMap.resolve(shortcut: "⌘9", in: offer) {
            #expect(refusal.error == "shortcutNotMapped")
        } else { Issue.record("an unmapped shortcut must refuse") }
        if case .failure(let refusal) = AffordanceMap.resolve(shortcut: "⌘2", in: nil) {
            #expect(refusal.error == "shortcutNotMapped")
        } else { Issue.record("no map: nothing to resolve against") }
        let twice = RealtimeStandingOffer(candidates: [RealtimeMenuCandidate(path: ["A", "One"], shortcut: "⌘K"),
                                                       RealtimeMenuCandidate(path: ["B", "Two"], shortcut: "⌘K")], app: "b", uptime: 0)
        if case .failure(let refusal) = AffordanceMap.resolve(shortcut: "⌘K", in: twice) {
            #expect(refusal.error == "shortcutAmbiguous")
            #expect(refusal.message.contains("A > One") && refusal.message.contains("B > Two"))
        } else { Issue.record("two owners must refuse with both") }
    }

    @Test func theCacheIsBoundedAndInvalidatedByVersionPidAgeAndNotFound() throws {
        let cache = AffordanceMapCache()
        func map(_ bundle: String, version: String = "1", pid: pid_t = 1, at uptime: TimeInterval = 0) -> AffordanceMap {
            AffordanceMap(menusResponse: finderMenus, bundleIdentifier: bundle, version: version, pid: pid, builtUptime: uptime)!
        }
        for index in 0..<30 { cache.store(map("app\(index)")) }
        #expect(cache.count == AffordanceMapCache.maximumApps)
        #expect(cache.map(bundle: "app0", version: "1", pid: 1, now: 1) == nil, "the least recently used went first")
        #expect(cache.map(bundle: "app29", version: "1", pid: 1, now: 1) != nil)
        #expect(cache.map(bundle: "app29", version: "2", pid: 1, now: 1) == nil, "a new version is a new map")
        cache.store(map("x"))
        #expect(cache.map(bundle: "x", version: "1", pid: 2, now: 1) == nil, "a relaunch is a new map")
        cache.store(map("y"))
        #expect(cache.map(bundle: "y", version: "1", pid: 1, now: AffordanceMapCache.maximumAgeSeconds + 1) == nil)
        cache.store(map("z"))
        cache.invalidate(bundle: "z")
        #expect(cache.map(bundle: "z", version: "1", pid: 1, now: 1) == nil)
    }

    @Test func landmarksNameControlsNeverContents() {
        let elements: [[String: Any]] = [
            ["role": "AXWindow", "name": "Downloads", "frame": ["x": 0, "y": 0, "w": 800, "h": 600], "nameSource": "title"],
            ["role": "AXButton", "name": "Back", "frame": ["x": 10, "y": 560, "w": 30, "h": 30], "nameSource": "description", "parent": 0],
            ["role": "AXTextField", "subrole": "AXSearchField", "name": "Search", "frame": ["x": 600, "y": 560, "w": 150, "h": 30],
             "nameSource": "placeholder", "parent": 0],
            ["role": "AXTextField", "name": "my secret draft", "frame": ["x": 100, "y": 100, "w": 300, "h": 30], "nameSource": "value", "parent": 0],
            ["role": "AXRadioButton", "subrole": "AXTabButton", "name": "General", "frame": ["x": 100, "y": 400, "w": 60, "h": 20],
             "nameSource": "title", "parent": 0],
            ["role": "AXOutline", "name": "Files", "frame": ["x": 0, "y": 0, "w": 800, "h": 500], "nameSource": "description", "parent": 0],
            ["role": "AXTextField", "name": "report.pdf", "frame": ["x": 10, "y": 300, "w": 200, "h": 20], "nameSource": "value",
             "actions": ["AXOpen"], "parent": 5],
            ["role": "AXTextField", "name": "notes.txt", "frame": ["x": 10, "y": 280, "w": 200, "h": 20], "nameSource": "value",
             "actions": ["AXOpen"], "parent": 5]
        ]
        let lines = AffordanceMap.landmarkLines(fromSnapshotResponse: ["ok": true, "elements": elements])
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("toolbar: \"Back\""))
        #expect(joined.contains("search field \"Search\""))
        #expect(joined.contains("tabs: \"General\""))
        #expect(joined.contains("outline \"Files\": 2 visible"), "an elided table lists only what is in view")
        #expect(!joined.contains("secret draft"), "a field named by what was typed is never a landmark")
        #expect(!joined.contains("report.pdf"), "a table gives its row count, never its rows")
        #expect(lines.count <= AffordanceMap.maximumLandmarkLines)
    }
}
