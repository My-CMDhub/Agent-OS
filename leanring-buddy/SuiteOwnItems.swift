//
//  SuiteOwnItems.swift
//  leanring-buddy
//
//  What a suite or a scenario made in the owner's Notes, Reminders and Calendar goes again (owner 2026-11-04: test items
//  were piling up there). Reminders and Calendar by identity: EventKit's identifiers before and after a task, so only what
//  that task made can go, whatever title it ended with. So they need the grant: without it nothing could be removed safely, and the
//  task is skipped (`needsGrant`). 2026-11-04, measured the hard way: Calendar's tile for a sixth event in a day has a (0,0) frame and takes no selection,
//  so window cleanup left six test events behind. Notes has no API, but its list has identity: each row's AXIdentifier holds the note's id, and the row's own
//  "bin" action sends exactly that note to Recently Deleted. 2026-11-04: Edit > Delete never ran, because the item is called "Delete Note" and the row was picked by title.
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

    /// Why the task may not run: what it makes could not be taken back. Notes can only say so once it reads (`before`).
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

    /// What the task started from: identifiers. nil: not readable, so what it makes could not be told from what was there.
    enum Before: Sendable { case identifiers(Set<String>) }

    static func before(_ item: Item) -> Before? {
        if item.bundle == notes { return noteRows(pid: NSRunningApplication.runningApplications(withBundleIdentifier: notes).first?.processIdentifier).map { .identifiers(Set($0.map(\.id))) } }
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

    struct NoteRow { let id: String; let title: String; let bin: (element: AXUIElement, action: String)? }

    /// "ICMNoteListCell, Note[id=2EEA29D8-…]" -> the id (read off Notes' list, 2026-11-04).
    static func noteID(fromIdentifier identifier: String) -> String? {
        guard let start = identifier.range(of: "Note[id="), let end = identifier[start.upperBound...].firstIndex(of: "]") else { return nil }
        let id = identifier[start.upperBound..<end]
        return id.isEmpty ? nil : String(id)
    }

    /// The row's action that sends the note to Recently Deleted: "Name:bin\nTarget:0x0\nSelector:(null)". ponytail: en-AU "bin" and en-US "trash", as a menu shows them.
    static func binAction(among actions: [String]) -> String? {
        actions.first { $0.hasPrefix("Name:bin\n") || $0.hasPrefix("Name:trash\n") || $0 == "Name:bin" || $0 == "Name:trash" }
    }

    /// "Notes – 21 notes" -> 21: how many the folder says it holds.
    static func noteCount(inWindowTitle title: String) -> Int? {
        let words = title.split(separator: " ")
        guard let index = words.lastIndex(where: { $0 == "notes" || $0 == "note" }), index > 0 else { return nil }
        return Int(words[index - 1])
    }

    /// Every note in the open folder with its identity, nil when that could not be read whole: no window, no table, fewer rows than
    /// the window says it holds (an older note read as new would go), or rows that publish no way to send them to Recently Deleted.
    static func noteRows(pid: pid_t?) -> [NoteRow]? {
        guard let pid else { return nil }
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            AXUIElementSetMessagingTimeout(element, 1)
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        func actions(_ element: AXUIElement) -> [String] {
            var names: CFArray?
            return AXUIElementCopyActionNames(element, &names) == .success ? (names as? [String]) ?? [] : []
        }
        func first(_ element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
            if matches(element) { return element }
            guard depth > 0 else { return nil }
            for child in children(element) { if let found = first(child, depth: depth - 1, where: matches) { return found } }
            return nil
        }
        let window = CoverageAudit.windows(of: pid).first
        guard let window, let table = first(window, depth: 8, where: { attribute($0, kAXRoleAttribute) as? String == "AXTable" }) else { return nil }
        var rows: [NoteRow] = []
        for row in children(table) where attribute(row, kAXRoleAttribute) as? String == "AXRow" {
            guard let cell = first(row, depth: 3, where: { (attribute($0, kAXIdentifierAttribute) as? String).flatMap(noteID) != nil }),
                  let id = (attribute(cell, kAXIdentifierAttribute) as? String).flatMap(noteID) else { continue }
            // The row's first text is its title: image, image, title, preview, time, as read.
            let title = children(cell).lazy.compactMap { attribute($0, kAXRoleAttribute) as? String == "AXStaticText" ? attribute($0, kAXValueAttribute) as? String : nil }.first ?? ""
            rows.append(NoteRow(id: id, title: title, bin: binAction(among: actions(row)).map { (row, $0) }))
        }
        if let said = (attribute(window, kAXTitleAttribute) as? String).flatMap(noteCount(inWindowTitle:)), rows.count < said { return nil }
        guard rows.allSatisfy({ $0.bin != nil }), !rows.isEmpty else { return nil }
        return rows
    }

    /// New since `before` and titled as the task's, or left blank by an abandoned edit (Notes lists one as "New Note"). Nothing else is this task's.
    static func notesMadeByTask(_ item: Item, before: Set<String>, rows: [(id: String, title: String)]) -> [String] {
        rows.filter { !before.contains($0.id) && (matches($0.title, item) || $0.title == "New Note") }.map(\.id)
    }

    /// By identity, through the row's own action, read back: that id gone, every other id still there.
    private static func removeNote(_ id: String, pid: pid_t) -> Bool {
        guard let rows = noteRows(pid: pid), let bin = rows.first(where: { $0.id == id })?.bin else { return false }
        let others = Set(rows.map(\.id)).subtracting([id])
        guard AXUIElementPerformAction(bin.element, bin.action as CFString) == .success else { return false }
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.2)
            guard let now = noteRows(pid: pid).map({ Set($0.map(\.id)) }), !now.contains(id) else { continue }
            return others.isSubset(of: now)
        }
        return false
    }

    /// Off the main actor. Evidence: what went, and what was left and why.
    static func remove(_ items: [Item], before: [Item: Before]) -> [String: Any] {
        var removed: [String] = [], left: [String] = []
        for item in items {
            switch before[item] {
            case .identifiers(let identifiers) where item.bundle == notes:
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundle).first else { left.append("\(item.title): app gone"); continue }
                guard let rows = noteRows(pid: app.processIdentifier) else { left.append("\(item.title): unreadable"); continue }
                let new = notesMadeByTask(item, before: identifiers, rows: rows.map { ($0.id, $0.title) })
                let done = new.filter { removeNote($0, pid: app.processIdentifier) }.count
                if !new.isEmpty {
                    HarnessServer.auditDirectClose(tool: "SuiteOwnItems", processIdentifier: app.processIdentifier, windowNumber: nil,
                                                   why: "run cleanup: \(done) of \(new.count) new notes titled \(item.title), by id, to Recently Deleted", closed: done == new.count)
                }
                if done > 0 { removed.append(item.title) }
                if done < new.count { left.append("\(item.title): \(new.count - done) could not be removed") }
            case .identifiers(let identifiers):
                let result = removeThroughEventKit(item, before: identifiers)
                if result.removed > 0 { removed.append("\(item.title) x\(result.removed)") }
                if result.left > 0 { left.append("\(item.title): \(result.left) could not be removed") }
            case nil:
                left.append("\(item.title): nothing read before")
            }
        }
        return ["removed": removed, "left": left]
    }
}
