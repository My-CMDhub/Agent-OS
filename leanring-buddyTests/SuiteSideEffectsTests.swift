//
//  SuiteSideEffectsTests.swift
//  leanring-buddyTests
//
//  The diff only. That the reads see the real machine is proven by a live suite run's `sideEffects`.
//

import Foundation
import Testing
@testable import Clicky

struct SuiteSideEffectsTests {
    private typealias Snapshot = SuiteSideEffects.Snapshot

    private let quiet = Snapshot(apps: ["com.apple.finder", "com.google.Chrome"], windows: [1: "com.google.Chrome", 2: "com.apple.finder"],
                                 front: "com.apple.finder", values: ["appearance": "Dark", "outputVolume": "40", "wifiPower": "On"])

    @Test func anUnchangedMachineIsClean() {
        let report = SuiteSideEffects.report(before: quiet, after: quiet, declaredApps: [], mayChange: [])
        #expect(report["clean"] as? Bool == true)
        #expect(report.keys.sorted() == ["clean", "unread"], "only clean and what could not be read")
    }

    /// The failures this exists for: an owner's app closed and an owner's window gone, while the verdict said passed.
    @Test func whatTheTaskClosedIsNamed() {
        var after = quiet
        after.apps.remove("com.google.Chrome")
        after.windows[1] = nil
        let report = SuiteSideEffects.report(before: quiet, after: after, declaredApps: [], mayChange: [])
        #expect(report["clean"] as? Bool == false)
        #expect(report["appsClosed"] as? [String] == ["com.google.Chrome"])
        #expect(report["windowsGone"] as? [String: Int] == ["com.google.Chrome": 1])
    }

    @Test func aDeclaredAppStillQuittingIsNotAnAppLeftOpenButItsWindowIsSaid() {
        var after = quiet
        after.apps.insert("com.apple.Notes")
        after.windows[9] = "com.apple.Notes"
        let declared = SuiteSideEffects.report(before: quiet, after: after, declaredApps: ["com.apple.Notes"], mayChange: [])
        #expect(declared["appsLeftOpen"] == nil)
        #expect(declared["windowsLeft"] as? [String: Int] == ["com.apple.Notes": 1])
        let undeclared = SuiteSideEffects.report(before: quiet, after: after, declaredApps: [], mayChange: [])
        #expect(undeclared["appsLeftOpen"] as? [String] == ["com.apple.Notes"])
    }

    /// E11 is asked to move the volume, so only IT may; the same move in any other task is a side effect.
    @Test func aValueCountsUnlessTheTaskWasAskedToChangeIt() {
        var after = quiet
        after.values["outputVolume"] = "30"
        let e11 = SuiteSideEffects.report(before: quiet, after: after, declaredApps: [],
                                          mayChange: SuiteSideEffects.mayChange["E11"] ?? [])
        #expect(e11["clean"] as? Bool == true)
        let other = SuiteSideEffects.report(before: quiet, after: after, declaredApps: [], mayChange: [])
        #expect(other["changed"] as? [String: [String: String]] == ["outputVolume": ["before": "40", "after": "30"]])
    }

    /// No read is not no change: a missing grant is named, and never reported as a diff.
    @Test func anUnreadValueIsNamedAndNeverADiff() {
        var after = quiet
        after.values["wifiPower"] = nil
        let report = SuiteSideEffects.report(before: quiet, after: after, declaredApps: [], mayChange: [])
        #expect(report["clean"] as? Bool == true)
        #expect((report["unread"] as? [String])?.contains("wifiPower") == true)
        #expect((report["unread"] as? [String])?.contains("reminders") == true)
    }

    @Test func aFrontAppThatDidNotComeBackIsSaid() {
        var after = quiet
        after.front = "com.google.Chrome"
        #expect(SuiteSideEffects.report(before: quiet, after: after, declaredApps: [], mayChange: [])["frontmost"] as? [String: String]
                == ["before": "com.apple.finder", "after": "com.google.Chrome"])
        after.front = nil
        #expect(SuiteSideEffects.report(before: quiet, after: after, declaredApps: [], mayChange: [])["clean"] as? Bool == true)
    }
}
