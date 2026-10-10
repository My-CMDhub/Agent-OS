//
//  HarnessHelpSearch.swift
//  leanring-buddy
//
//  `helpSearch`: the frontmost app's Help-menu search (design 2026-10-07 §A,
//  build step 5). A CLOSED Help menu publishes no search field, so the verb
//  opens it, and every step is what the coordinator measured 2026-10-11 on
//  Calculator x3 and TextEdit x1:
//    - `AXPress` on the top-level Help AXMenuBarItem: err 0, its AXSelected 1.
//    - The open AXMenu's first AXMenuItem holds an AXTextField (subrole
//      AXSearchField) and an AXTable described "search result".
//    - Writing the field's AXValue RUNS the search (err 0, 2-430 ms): no
//      AXConfirm, no keystroke.
//    - Rows within 250 ms: AXRow > AXCell > AXStaticText, text = AXValue. Menu
//      hits are paths joined by " > ", topics are titles, "Show All Help
//      Topics" is last, and a blank row is a section header.
//    - `AXCancel` on the open AXMenu closes it in 6-16 ms (AXSelected 0), 4/4.
//      A second press does not (CoverageAudit 2026-10-06: left open 18/18).
//
//  The pure half (rows -> menu paths / topics, path resolution against the
//  live listing, settling) is unit-tested; the live half is proven by running it.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum HarnessHelpSearch {
    static let maximumQueryLength = 100
    static let pressTimeoutSeconds: Float = 0.5
    static let openDeadlineSeconds = 1.0
    static let pollIntervalSeconds = 0.1
    static let resultDeadlineSeconds = 1.5
    static let closeDeadlineSeconds = 0.5
    /// The open menu's own items plus the field and the table: the audit saw the field within 80.
    static let maximumNodesSearched = 80
    static let maximumRowsRead = 40
    static let pathSeparator = " > "
    /// ponytail: English only; without it a section is told apart by its " > " paths.
    static let showAllTopicsRow = "Show All Help Topics"

    // MARK: Pure

    /// Why the query may not be typed, nil when it may.
    static func queryProblem(_ query: String) -> String? {
        if query.count > maximumQueryLength { return "longer than \(maximumQueryLength) characters" }
        if query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return "a control character" }
        if !SecretScanner.matches(in: query).isEmpty { return "something shaped like a secret" }
        return nil
    }

    static func isHelpLabel(_ label: String?) -> Bool {
        label.map { RealtimeVoiceVerbs.foldedTokens($0) == ["help"] } ?? false
    }

    struct Classified: Equatable {
        var menuPaths: [[String]]
        var topics: [String]
    }

    /// Sections split at blank rows. The section holding "Show All Help Topics"
    /// is the topics (that row dropped); every other is menu hits. With no such
    /// row, a section with a " > " path is menus and any other is topics.
    static func classify(rows: [String]) -> Classified {
        var sections: [[String]] = [[]]
        for row in rows.map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if row.isEmpty { sections.append([]) } else { sections[sections.count - 1].append(row) }
        }
        sections.removeAll(where: \.isEmpty)
        let topicsIndex = sections.firstIndex { $0.contains(showAllTopicsRow) }
        var result = Classified(menuPaths: [], topics: [])
        for (index, section) in sections.enumerated() {
            let isTopics = topicsIndex.map { $0 == index } ?? !section.contains { $0.contains(pathSeparator) }
            if isTopics {
                result.topics += section.filter { $0 != showAllTopicsRow }
            } else {
                result.menuPaths += section.map { $0.components(separatedBy: pathSeparator) }.filter { !$0.contains(where: \.isEmpty) }
            }
        }
        return result
    }

    /// Two identical non-empty reads in a row: the table stopped filling.
    static func isSettled(previous: [String]?, current: [String]) -> Bool {
        !current.isEmpty && current == previous
    }

    /// Each hit kept only when it names exactly one ENABLED LEAF of the live
    /// listing: its whole path, or else the one item whose path ends with it
    /// (TextEdit's "Font > Bold" is Format > Font > Bold). A submenu parent, a
    /// disabled item, two endings or none are dropped and counted.
    static func resolve(_ hits: [[String]], in items: [AccessibilityMenu.ListedItem]) -> (paths: [[String]], dropped: Int) {
        var paths: [[String]] = [], dropped = 0, seen = Set<[String]>()
        for hit in hits where seen.insert(hit).inserted {
            var matches = items.filter { $0.path == hit }
            if matches.isEmpty { matches = items.filter { $0.path.count > hit.count && Array($0.path.suffix(hit.count)) == hit } }
            guard matches.count == 1, let match = matches.first, match.isEnabled, !match.hasSubmenu else { dropped += 1; continue }
            if !paths.contains(match.path) { paths.append(match.path) }
        }
        return (paths, dropped)
    }

    // MARK: Live

    /// The top-level Help item of a menu bar (the last one so named).
    static func helpBarItem(in bar: AccessibilityMenu.Node) -> AccessibilityMenu.Node? {
        AccessibilityMenu.liveChildren(of: bar).last { isHelpLabel($0.label) }
    }

    struct Search {
        var report: [String: Any] = [:]
        var rows: [String] = []
        /// (error code, message); nil when the search ran and the menu closed.
        var failure: (code: String, message: String)?
    }

    /// Opens Help, types the query into its search field, reads the result
    /// rows, and ALWAYS closes the menu with `AXCancel` — whatever failed.
    static func search(query: String, helpItem: AXUIElement) -> Search {
        var search = Search()
        var timings: [String: Int] = [:]
        func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        let opening = Date()
        AXUIElementSetMessagingTimeout(helpItem, pressTimeoutSeconds)
        let press = AXUIElementPerformAction(helpItem, kAXPressAction as CFString)
        search.report["pressAxError"] = press.rawValue
        // -25204: menu tracking held the reply past the timeout — sent, unconfirmed; the field decides.
        let pressSent = press == .success || press == .cannotComplete
        var menu: AXUIElement?
        var parts: (field: AXUIElement, table: AXUIElement)?
        if pressSent {
            let deadline = Date().addingTimeInterval(openDeadlineSeconds)
            repeat {
                menu = children(helpItem).first { string($0, kAXRoleAttribute) == "AXMenu" }
                if let menu, let found = fieldAndTable(in: menu) { parts = found; break }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
        }
        timings["openMs"] = milliseconds(since: opening)

        if let parts {
            let writing = Date()
            AXUIElementSetMessagingTimeout(parts.field, 1.0)
            let write = AXUIElementSetAttributeValue(parts.field, kAXValueAttribute as CFString, query as CFString)
            search.report["writeAxError"] = write.rawValue
            timings["writeMs"] = milliseconds(since: writing)
            if write == .success {
                let polling = Date()
                let deadline = polling.addingTimeInterval(resultDeadlineSeconds)
                var previous: [String]?
                var settled = false
                repeat {
                    Thread.sleep(forTimeInterval: pollIntervalSeconds)
                    let current = rowTexts(parts.table)
                    search.rows = current
                    settled = isSettled(previous: previous, current: current)
                    previous = current
                } while !settled && Date() < deadline
                search.report["settled"] = settled
                search.report["rowCount"] = search.rows.count
                timings["resultsMs"] = milliseconds(since: polling)
            } else {
                search.failure = ("helpSearchFailed", "the Help menu's search field did not take the words (AXError \(write.rawValue)); nothing was searched")
            }
        } else {
            search.failure = ("helpSearchUnavailable", pressSent
                ? "the Help menu showed no search field; it was closed and nothing was typed"
                : "the Help menu did not open (AXError \(press.rawValue)); nothing was typed")
        }

        // Always, even after a failure: a menu left open sits over the owner's work.
        let closing = Date()
        let closed = close(helpItem: helpItem, menu: menu)
        timings["closeMs"] = milliseconds(since: closing)
        search.report["closed"] = closed
        search.report["timings"] = timings
        if !closed {
            search.failure = ("helpMenuLeftOpen", "the Help menu did not close (AXSelected still true after AXCancel); the owner may need to dismiss it")
        }
        return search
    }

    /// `AXCancel` on the open AXMenu, then AXSelected read back until false.
    static func close(helpItem: AXUIElement, menu: AXUIElement?) -> Bool {
        if let menu = menu ?? children(helpItem).first(where: { string($0, kAXRoleAttribute) == "AXMenu" }) {
            AXUIElementSetMessagingTimeout(menu, pressTimeoutSeconds)
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
        let deadline = Date().addingTimeInterval(closeDeadlineSeconds)
        while true {
            var selected: AnyObject?
            AXUIElementCopyAttributeValue(helpItem, kAXSelectedAttribute as CFString, &selected)
            // A failed read is not a closed menu.
            if (selected as? Bool) == false { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// The search field and the "search result" table, breadth-first from the open menu.
    static func fieldAndTable(in menu: AXUIElement) -> (field: AXUIElement, table: AXUIElement)? {
        var queue = [menu], seen = 0
        var field: AXUIElement?, table: AXUIElement?
        while !queue.isEmpty, seen < maximumNodesSearched {
            let node = queue.removeFirst()
            seen += 1
            switch string(node, kAXRoleAttribute) {
            case "AXTextField" where string(node, kAXSubroleAttribute) == "AXSearchField":
                field = field ?? node
            case "AXTable" where string(node, kAXDescriptionAttribute) == "search result":
                table = table ?? node
                continue
            default:
                break
            }
            if let field, let table { return (field, table) }
            queue += children(node)
        }
        return nil
    }

    /// Each row's text: the first AXStaticText's AXValue a few levels down ("" for a header).
    static func rowTexts(_ table: AXUIElement) -> [String] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(table, "AXRows" as CFString, &value)
        return ((value as? [AXUIElement]) ?? []).prefix(maximumRowsRead).map { row in
            var queue = [row], seen = 0
            while !queue.isEmpty, seen < 10 {
                let node = queue.removeFirst()
                seen += 1
                if string(node, kAXRoleAttribute) == "AXStaticText" { return string(node, kAXValueAttribute) ?? "" }
                queue += children(node)
            }
            return ""
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? String : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }
}
