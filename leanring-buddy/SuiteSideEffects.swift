//
//  SuiteSideEffects.swift
//  leanring-buddy
//
//  What a suite task changed that it was not asked to change, reported as `sideEffects` beside the verdict and never
//  part of it. Measured 2026-11-03 (docs/ops/2026-11-03-verdict-audit.md): checkers read what a task should have done,
//  so a pass said nothing about the rest of the machine.
//
//  Before and after, around the whole task including its cleanup: regular apps running, window-server windows (numbers,
//  never titles), the front app, and a few values a task must leave alone. Reads only, and none can raise a TCC prompt:
//  no user folder is listed (~/JARVIS-sandbox is ours), and Reminders and Calendar are read only when full access is
//  already granted, as counts, or are named under `unread`. Not seen: a Finder folder's view options, drafts, notes.
//

import AppKit
import CoreGraphics
import EventKit
import Foundation

nonisolated enum SuiteSideEffects {
    struct Snapshot: Sendable, Equatable {
        var apps: Set<String> = []
        /// Window-server number -> the owning app.
        var windows: [Int: String] = [:]
        var front: String?
        /// A value absent here could not be read: compared with nothing, listed under `unread`.
        var values: [String: String] = [:]
    }

    static let valueNames = ["appearance", "outputVolume", "wifiPower", "sandbox", "reminders", "events"]

    /// What a task's own words ask it to change; everything else counts. ponytail: by task id, so a new task that
    /// makes a reminder reports one until it is listed here.
    static let mayChange: [String: Set<String>] = [
        "E03": ["events"], "E04": ["reminders"], "E11": ["outputVolume"], "E12": ["reminders"], "G05": ["reminders"],
        "M02": ["reminders"], "M04": ["reminders"]
    ]

    /// Blocks for a subprocess and for EventKit: call it off the main actor.
    static func snapshot() -> Snapshot {
        var state = Snapshot()
        let own = Bundle.main.bundleIdentifier
        state.apps = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
        if let own { state.apps.remove(own) }
        let listed = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in listed where window[kCGWindowLayer as String] as? Int == 0 {
            guard let number = window[kCGWindowNumber as String] as? Int, let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.width > 100, bounds.height > 60,
                  let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, bundle != own else { continue }
            state.windows[number] = bundle
        }
        state.front = AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier
        state.values["appearance"] = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "Light"
        state.values["outputVolume"] = GeneralitySuite.outputVolume().map(String.init)
        let wifi = GeneralitySuite.output("/usr/sbin/networksetup", ["-getairportpower", "en0"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !wifi.isEmpty { state.values["wifiPower"] = wifi }
        state.values["sandbox"] = GeneralitySuite.Sandbox.listing().map { $0.keys.sorted().joined(separator: ", ") }
        state.values["reminders"] = GeneralitySuite.eventKitIncompleteReminders().map { String($0.count) }
        state.values["events"] = eventsNextMonth().map(String.init)
        return state
    }

    /// Events from yesterday to 30 days on, in every calendar; nil without full access. A count: no title leaves here.
    private static func eventsNextMonth(now: Date = Date()) -> Int? {
        guard GeneralitySuite.eventKitReady(.event) else { return nil }
        let store = EKEventStore()
        let count = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-86_400),
                                                                    end: now.addingTimeInterval(30 * 86_400), calendars: nil)).count
        withExtendedLifetime(store) {}
        return count
    }

    /// `declaredApps`: the task's own apps, which it may leave running while cleanup finishes quitting them.
    static func report(before: Snapshot, after: Snapshot, declaredApps: Set<String>, mayChange: Set<String>) -> [String: Any] {
        func byApp(_ numbers: Set<Int>, in windows: [Int: String]) -> [String: Int] {
            numbers.reduce(into: [:]) { counts, number in counts[windows[number] ?? "?", default: 0] += 1 }
        }
        var report: [String: Any] = [:]
        let opened = after.apps.subtracting(before.apps).subtracting(declaredApps).sorted()
        let closed = before.apps.subtracting(after.apps).sorted()
        if !opened.isEmpty { report["appsLeftOpen"] = opened }
        if !closed.isEmpty { report["appsClosed"] = closed }
        let newWindows = Set(after.windows.keys).subtracting(before.windows.keys), goneWindows = Set(before.windows.keys).subtracting(after.windows.keys)
        if !newWindows.isEmpty { report["windowsLeft"] = byApp(newWindows, in: after.windows) }
        if !goneWindows.isEmpty { report["windowsGone"] = byApp(goneWindows, in: before.windows) }
        if let was = before.front, let now = after.front, was != now { report["frontmost"] = ["before": was, "after": now] }
        var changed: [String: [String: String]] = [:]
        for name in valueNames where !mayChange.contains(name) {
            if let was = before.values[name], let now = after.values[name], was != now {
                changed[name] = ["before": String(was.prefix(300)), "after": String(now.prefix(300))]
            }
        }
        if !changed.isEmpty { report["changed"] = changed }
        report["clean"] = report.isEmpty
        let unread = valueNames.filter { before.values[$0] == nil || after.values[$0] == nil }
        if !unread.isEmpty { report["unread"] = unread }
        return report
    }
}
