//
//  FirstSightWakeTests.swift
//  leanring-buddyTests
//
//  Generality suite 2026-10-06: Electron apps start blind (Cursor 8 nodes).
//  The wake itself is cross-process and proven live (first-sight-wake.log);
//  here, that it is paid once per process and that a thin tree tells the model
//  the vision click is the route.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct FirstSightWakeTests {
    @Test func aProcessIsWokenOnceOnly() {
        let pid: pid_t = 999_000 + pid_t.random(in: 0..<999)
        #expect(FirstSightWake.claim(pid))
        #expect(!FirstSightWake.claim(pid))
    }

    /// Live 2026-10-06: Reminders and TextEdit (native, small windows) refused the
    /// switch and paid 3.2 s of polling each. Only an app that took it waits.
    @Test func onlyAnAppThatTookTheSwitchIsWaitedFor() {
        #expect(!FirstSightWake.acceptedTheSwitch(.attributeUnsupported))
        #expect(FirstSightWake.acceptedTheSwitch(.success))
    }

    /// Review of 349bd49: Clicky itself is never woken, and only a thin tree is.
    @Test func onlyAThinOtherAppIsWoken() {
        #expect(FirstSightWake.shouldWake(nodeCount: 8, bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
        #expect(!FirstSightWake.shouldWake(nodeCount: 8, bundleIdentifier: Bundle.main.bundleIdentifier))
        #expect(!FirstSightWake.shouldWake(nodeCount: 20, bundleIdentifier: "com.microsoft.VSCode"))
    }

    @Test func aThinTreeTellsTheModelToAimBySight() async {
        func dispatch(thin: Bool) async -> [String: Any] {
            let snapshot: [String: Any] = ["ok": true, "application": "Cursor", "bundleIdentifier": "com.todesktop.230313mzl4w4u92",
                                           "nodeCount": thin ? 8 : 233, "elements": [[String: Any]](), "thinTree": thin,
                                           "windowFrame": ["x": 0, "y": 0, "width": 1440, "height": 900]]
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
            let call = RealtimeToolCall(callID: "c", name: "find_on_screen", appName: "Cursor", words: "agent")
            return await RealtimeOpenAppTool.dispatch(call, screens: [CGRect(x: 0, y: 0, width: 1440, height: 900)], answer: { _ in line }).result
        }
        #expect((await dispatch(thin: true))["note"] as? String == FirstSightWake.thinTreeNote)
        #expect((await dispatch(thin: false))["note"] == nil)
    }
}
