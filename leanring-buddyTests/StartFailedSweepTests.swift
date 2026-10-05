//
//  StartFailedSweepTests.swift
//  leanring-buddyTests
//
//  A start that gave up may still have opened its window. 2026-10-05 09-09-44Z:
//  the agent-loop probe's `commit/screen` start ended `startFailed`, Chrome's
//  window 1982 opened late, nothing closed it, and it became the owner's main
//  window for the evening (docs/superpowers/specs/2026-10-06-chrome-window-investigation.md).
//

import Foundation
import Testing
@testable import Clicky

struct StartFailedSweepTests {

    @Test func aWindowThatOpensAfterTheStartGaveUpIsClosedByItsIdentity() {
        var polls = 0
        var closed: [String] = []
        let report = ScenarioRunnerAX.sweepLateWindows(waitSeconds: 2, find: { () -> [String] in
            polls += 1
            return polls < 3 ? [] : ["n=AB12"]
        }, close: { window in
            closed.append(window)
            return ["closed": true]
        })
        #expect(closed == ["n=AB12"])
        #expect(report["nonceWindowAppearedLater"] as? Bool == true)
        #expect((report["closed"] as? [[String: Any]])?.count == 1)
    }

    @Test func whenNothingAppearsNothingIsClosedAndTheReportSaysSo() {
        var closed = 0
        let report = ScenarioRunnerAX.sweepLateWindows(waitSeconds: 0.2, find: { [String]() }, close: { _ in
            closed += 1
            return [:]
        })
        #expect(closed == 0)
        #expect(report["nonceWindowAppearedLater"] as? Bool == false)
        #expect((report["closed"] as? [[String: Any]])?.isEmpty == true)
    }
}
