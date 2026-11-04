//
//  SuiteOwnItems.swift
//  leanring-buddy
//
//  What a suite or a scenario made in the owner's Notes, Reminders and Calendar goes again (owner 2026-11-04: test items
//  were piling up there). Reminders and Calendar by identity: EventKit's identifiers before and after a task, so only what
//  that task made can go, whatever title it ended with. So they need the grant: without it nothing could be removed safely, and the
//  task is skipped (`needsGrant`). 2026-11-04, measured the hard way: Calendar's tile for a sixth event in a day has a (0,0) frame and takes no selection,
//  so window cleanup left six test events behind. Notes has no API: its own Edit > Delete on the row (it goes to Recently Deleted), read back, undone if anything else went.
//

import AppKit
import ApplicationServices
import EventKit
import Foundation

nonisolated enum SuiteOwnItems {
    struct Item: Sendable, Hashable {
        let bundle: String
        /// Lowercased; an empty title always counts (an abandoned edit leaves one).
        let title: String
    }

    private static let notes = GeneralitySuite.notes, reminders = GeneralitySuite.reminders, calendar = GeneralitySuite.calendar

    /// Task id -> what its words make. ponytail: a table beside the tasks, like `SuiteSideEffects.mayChange`.
    static let byTask: [String: [Item]] = [
        "G04": [Item(bundle: notes, title: "jarvis test 1")], "G05": [Item(bundle: reminders, title: "jarvis test reminder")],
        "G21": [Item(bundle: notes, title: "jarvis test 2")], "E03": [Item(bundle: calendar, title: "jarvis test meeting")],
        "E04": [Item(bundle: reminders, title: "milk"), Item(bundle: reminders, title: "eggs")], "E12": [Item(bundle: reminders, title: "call mom")],
        "M01": [Item(bundle: notes, title: "jarvis weather")], "M02": [Item(bundle: reminders, title: "big-video")],
        "M03": [Item(bundle: notes, title: "jarvis lighthouse")], "M04": [Item(bundle: reminders, title: "charge my mac")],
        "M05": [Item(bundle: notes, title: "jarvis biggest file")]
    ]

    private static func matches(_ name: String?, _ item: Item) -> Bool {
        let name = name?.lowercased() ?? ""
        return name.isEmpty || name.contains(item.title)
    }

    /// Why the task may not run: what it makes could not be taken back.
    static func needsGrant(_ items: [Item]) -> String? {
        for item in items {
            if item.bundle == calendar, !GeneralitySuite.eventKitReady(.event) { return "no Calendars grant, so its event could not be removed by identity (Panel > Permissions)" }
            if item.bundle == reminders, !GeneralitySuite.eventKitReady(.reminder) { return "no Reminders grant, so its reminder could not be removed by identity (Panel > Permissions)" }
        }
        return nil
    }

    /// Calendar's events from yesterday to two weeks out, every reminder: identifier -> title. nil: not granted.
    private static func held(_ item: Item, in store: EKEventStore) -> [String: String]? {
        if item.bundle == calendar, GeneralitySuite.eventKitReady(.event) {
            let now = Date()
            let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(14 * 86_400), calendars: nil))
            return Dictionary(events.map { ($0.calendarItemIdentifier, $0.title ?? "") }, uniquingKeysWith: { first, _ in first })
        }
        if item.bundle == reminders, GeneralitySuite.eventKitReady(.reminder) {
            final class Box: @unchecked Sendable { var found: [EKReminder]? }
            let box = Box(), done = DispatchSemaphore(value: 0)
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { box.found = $0; done.signal() }
            guard done.wait(timeout: .now() + 5) == .success, let found = box.found else { return nil }
            return Dictionary(found.map { ($0.calendarItemIdentifier, $0.title ?? "") }, uniquingKeysWith: { first, _ in first })
        }
        return nil
    }

    /// What the task started from: identifiers (Reminders, Calendar), or a count of rows (Notes).
    enum Before: Sendable { case identifiers(Set<String>), rows(Int) }

    static func before(_ item: Item) -> Before? {
        if item.bundle == notes { return rows(item).map { .rows($0.count) } }
        return held(item, in: EKEventStore()).map { .identifiers(Set($0.keys)) }
    }

    /// New events with their starts, for a scenario's own check.
    static func newEvents(_ item: Item, before: Set<String>) -> [(title: String, start: Date)] {
        guard GeneralitySuite.eventKitReady(.event) else { return [] }
        let store = EKEventStore(), now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(14 * 86_400), calendars: nil))
        return events.filter { !before.contains($0.calendarItemIdentifier) && matches($0.title, item) }.map { ($0.title ?? "", $0.startDate) }
    }

    private static func removeThroughEventKit(_ item: Item, before: Set<String>) -> (removed: Int, left: Int) {
        let store = EKEventStore()
        let new = (held(item, in: store) ?? [:]).filter { !before.contains($0.key) && matches($0.value, item) }.keys
        var removed = 0
        for identifier in new {
            guard let found = store.calendarItem(withIdentifier: identifier) else { continue }
            let gone = if let event = found as? EKEvent { (try? store.remove(event, span: .thisEvent, commit: true)) != nil }
                else if let reminder = found as? EKReminder { (try? store.remove(reminder, commit: true)) != nil } else { false }
            if gone { removed += 1 }
        }
        return (removed, new.count - removed)
    }

    // MARK: Notes

    private static func rows(_ item: Item) -> [AccessibilityElementNode]? {
        GeneralitySuite.appNodes(item.bundle)?.filter { node in
            guard let name = node.listedName?.raw, name.lowercased().contains(item.title) else { return false }
            return !["AXWindow", "AXTextArea", "AXTextField", "AXHeading", "AXWebArea"].contains(node.role)
        }
    }

    private static func listNames(_ bundle: String) -> [String: Int]? {
        GeneralitySuite.appNodes(bundle).map { nodes in
            nodes.filter { ["AXStaticText", "AXCell", "AXRow"].contains($0.role) }.compactMap { $0.listedName?.raw }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
    }

    /// The first ancestor that says its AXSelected can be set: the row.
    private static func select(_ node: AccessibilityElementNode) -> Bool {
        var current = node.accessibilityElement
        for _ in 0..<6 {
            guard let element = current else { return false }
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXSelectedAttribute as CFString, &settable) == .success, settable.boolValue {
                return AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
            }
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            current = (value as! AXUIElement)
        }
        return false
    }

    private static func undoLastEdit(pid: pid_t) {
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        guard let bar = attribute(AXUIElementCreateApplication(pid), kAXMenuBarAttribute),
              let edit = (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first(where: { attribute($0, kAXTitleAttribute) as? String == "Edit" }),
              let menu = (attribute(edit, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let undo = (attribute(menu, kAXChildrenAttribute) as? [AXUIElement])?.first(where: { (attribute($0, kAXTitleAttribute) as? String)?.hasPrefix("Undo") == true }) else { return }
        AXUIElementPerformAction(undo, kAXPressAction as CFString)
    }

    /// The newest note of that title (Notes lists newest first), selected, Edit > Delete, read back.
    private static func removeNote(_ item: Item, pid: pid_t) -> Bool {
        guard let rows = rows(item), let row = rows.first, let namesBefore = listNames(item.bundle), select(row) else { return false }
        Thread.sleep(forTimeInterval: 0.4)
        guard GeneralitySuite.pressMenuPath(["Edit", "Delete"], pid: pid) else { return false }
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.2)
            guard let names = listNames(item.bundle), names != namesBefore else { continue }
            // Anything else gone means the selection was not what it seemed: taken back, and left for the owner.
            let gone = namesBefore.filter { names[$0.key, default: 0] < $0.value }.map(\.key)
            guard gone.allSatisfy({ $0.lowercased().contains(item.title) }) else {
                undoLastEdit(pid: pid)
                return false
            }
            if let now = Self.rows(item)?.count, now < rows.count { return true }
        }
        return false
    }

    /// Off the main actor. Evidence: what went, and what was left and why.
    static func remove(_ items: [Item], before: [Item: Before]) -> [String: Any] {
        var removed: [String] = [], left: [String] = []
        for item in items {
            switch before[item] {
            case .identifiers(let identifiers):
                let result = removeThroughEventKit(item, before: identifiers)
                if result.removed > 0 { removed.append("\(item.title) x\(result.removed)") }
                if result.left > 0 { left.append("\(item.title): \(result.left) could not be removed") }
            case .rows(let earlier):
                guard let now = rows(item)?.count else { left.append("\(item.title): unreadable"); continue }
                guard now > earlier else { continue }
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundle).first else { left.append("\(item.title): app gone"); continue }
                var done = 0
                while done < now - earlier, removeNote(item, pid: app.processIdentifier) { done += 1 }
                HarnessServer.auditDirectClose(tool: "SuiteOwnItems", processIdentifier: app.processIdentifier, windowNumber: nil,
                                               why: "run cleanup: \(done) of \(now - earlier) new notes titled \(item.title)", closed: done == now - earlier)
                if done == now - earlier { removed.append(item.title) } else { left.append("\(item.title): \(now - earlier - done) could not be removed") }
            case nil:
                left.append("\(item.title): nothing read before")
            }
        }
        return ["removed": removed, "left": left]
    }
}
