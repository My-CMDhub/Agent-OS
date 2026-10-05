//
//  ProbeLoggingTests.swift
//  leanring-buddyTests
//
//  What the 2026-10-06 Chrome window investigation had to reconstruct by hand:
//  wall-clock time in the uptime-only logs (it mapped wall = uptime - 2970.6 s),
//  and a witness for every accessibility close that does not go through the harness.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct ProbeLoggingTests {

    @Test func everyMeasurementLineCarriesWallClockTimeNextToUptime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("probe-logging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in [AgentLoop.traceFileName, RealtimeDecisionTrace.fileName, GlobalPushToTalkShortcutMonitor.hotkeyEventLogFileName] {
            MeasurementLogFile.appendJSONLine(["kind": "step", "uptime": 12.5], toFileNamed: name, in: directory)
        }
        MeasurementLogFile.waitForPendingWrites()
        for name in [AgentLoop.traceFileName, RealtimeDecisionTrace.fileName, GlobalPushToTalkShortcutMonitor.hotkeyEventLogFileName] {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(object["uptime"] as? Double == 12.5)
            let wall = try #require(object["wall"] as? String, "\(name)")
            let date = try #require(HarnessPolicy.auditTimestampFormatter.date(from: wall), "\(name): \(wall)")
            #expect(abs(date.timeIntervalSinceNow) < 60)
        }
    }

    @Test func aCloseOutsideTheHarnessIsAnAuditLineNamingToolWindowAndWhy() throws {
        let line = HarnessServer.directCloseAuditLine(tool: "ScenarioRunnerAX.close", app: "com.google.Chrome", windowNumber: 1982,
                                                      why: "startFailed: a late window carrying n=AB12", closed: true,
                                                      at: Date(timeIntervalSince1970: 0))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["verb"] as? String == "axClose")
        #expect(object["kernel"] as? String == "bypassesHarness")
        #expect(object["tool"] as? String == "ScenarioRunnerAX.close")
        #expect(object["windowNumber"] as? Int == 1982)
        #expect(object["app"] as? String == "com.google.Chrome")
        #expect(object["why"] as? String == "startFailed: a late window carrying n=AB12")
        #expect(object["outcome"] as? String == "closed")
        #expect(object["timestamp"] as? String == "1970-01-01T00:00:00.000Z")
        #expect(object["session"] as? String == HarnessServer.sessionIdentifier)
        let tab = try #require(try JSONSerialization.jsonObject(with: Data(HarnessServer.directCloseAuditLine(
            tool: "AgentLoopProbe.closeTab", app: "com.google.Chrome", windowNumber: nil, why: "a tab the task opened", closed: false).utf8)) as? [String: Any])
        #expect(tab["windowNumber"] is NSNull)
        #expect(tab["outcome"] as? String == "notClosed")
    }

    /// The AX window's frame (top-left) is matched to exactly one window-server surface, or to none.
    @Test func anAccessibilityWindowIsNamedByItsWindowServerNumberOnlyWhenOneSurfaceMatches() {
        let surfaces = [WindowServerSurface(number: 1982, bounds: CGRect(x: 0, y: 25, width: 1440, height: 875), title: nil),
                        WindowServerSurface(number: 2001, bounds: CGRect(x: 900, y: 80, width: 300, height: 120), title: nil)]
        #expect(ScenarioRunnerAX.windowNumber(matching: CGRect(x: 0.5, y: 25, width: 1440, height: 874), in: surfaces) == 1982)
        #expect(ScenarioRunnerAX.windowNumber(matching: CGRect(x: 10, y: 25, width: 1440, height: 875), in: surfaces) == nil)
        #expect(ScenarioRunnerAX.windowNumber(matching: CGRect(x: 0, y: 25, width: 1440, height: 875),
                                              in: surfaces + [WindowServerSurface(number: 7, bounds: surfaces[0].bounds, title: nil)]) == nil)
    }
}
