//
//  VoiceToolProbeCleanupTests.swift
//  leanring-buddyTests
//
//  The menu probe's undo, pure half: which presses buy a close, which window
//  may be closed, and when the probe must stop because an owner's window is
//  gone. 9BC0CACB closed the owner's four Chrome windows; these are the rules
//  that make that impossible. Whether the window server and the harness agree
//  on a live window is the probe's own question.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

@MainActor
struct VoiceToolProbeCleanupTests {

    @Test func onlyTheFixturesPathOrANewItemBuysAClose() {
        let expected = ["File", "New Window"]
        #expect(VoiceToolProbe.pressCountsTowardCloseBudget(path: expected, expectedPath: expected))
        #expect(VoiceToolProbe.pressCountsTowardCloseBudget(path: ["File", "New window"], expectedPath: nil))
        #expect(VoiceToolProbe.pressCountsTowardCloseBudget(path: ["File", "New Finder Window"], expectedPath: expected))
        #expect(!VoiceToolProbe.pressCountsTowardCloseBudget(path: ["View", "as List"], expectedPath: expected))
        #expect(!VoiceToolProbe.pressCountsTowardCloseBudget(path: ["File", "Renew"], expectedPath: expected), "a word, not a prefix")
        #expect(!VoiceToolProbe.pressCountsTowardCloseBudget(path: nil, expectedPath: expected))
    }

    @Test func aWindowIsClosedOnlyIfItIsTheHarnessesMainWindowAndNew() {
        // Window server top-left; harness AppKit on a 900 pt display. Probe 44322BA6's full-screen Chrome:
        // a new window's toolbar surface (1440x166) in FRONT of its content (0,122,1440,778), which is main.
        let toolbar = (number: 4919, bounds: CGRect(x: 0, y: 0, width: 1440, height: 166))
        let content = (number: 4914, bounds: CGRect(x: 0, y: 122, width: 1440, height: 778))
        let main = CGRect(x: 0, y: 0, width: 1440, height: 778)
        func step(_ onScreen: [(number: Int, bounds: CGRect)], main: CGRect?, before: Set<Int> = [4133, 4142], closed: Int = 0, atMost: Int = 1)
            -> VoiceToolProbe.CleanupStep {
            VoiceToolProbe.nextCleanupStep(onScreen: onScreen, harnessMainFrame: main, primaryDisplayHeight: 900, before: before, closed: closed, atMost: atMost)
        }
        #expect(step([toolbar, content], main: main) == .close(window: 4914))
        // The owner's window is main: stop, never close it.
        let owner = (number: 4133, bounds: CGRect(x: 0, y: 88, width: 1440, height: 812))
        #expect(step([owner], main: CGRect(x: 0, y: 0, width: 1440, height: 812)) == .done)
        // Unread main, or a frame two windows share: refuse.
        #expect(step([toolbar, content], main: nil) == .refuse("harnessMainWindowUnread"))
        #expect(step([content, (number: 5000, bounds: content.bounds)], main: main) == .refuse("mainWindowNotOneOnScreenWindow:2"))
        #expect(step([toolbar], main: main) == .refuse("mainWindowNotOneOnScreenWindow:0"))
        // The budget: presses that could have made a window, and never more than three.
        #expect(step([content], main: main, closed: 1, atMost: 1) == .done)
        #expect(step([content], main: main, atMost: 0) == .done)
        #expect(step([content], main: main, closed: 3, atMost: 9) == .done)
    }

    @Test func anyPreexistingWindowGoneIsAnAbort() {
        #expect(VoiceToolProbe.preexistingWindowsMissing(before: [10, 11], after: [10, 11, 99]).isEmpty)
        #expect(VoiceToolProbe.preexistingWindowsMissing(before: [10, 11], after: [10]) == [11])
        // Unreadable, or the app quit: every one of them is gone.
        #expect(VoiceToolProbe.preexistingWindowsMissing(before: [10, 11], after: nil) == [10, 11])
    }

    @Test func theMainFrameIsReadFromTheHarnessesOwnWireShape() throws {
        // Built by the harness's own encoder, so a renamed key fails here, not live.
        var main: [String: Any] = ["main": true, "minimized": false]
        HarnessServer.attachFrame(CGRect(x: 289, y: 0, width: 920, height: 875), to: &main)
        let other: [String: Any] = ["main": false, "frame": ["x": 0, "y": 0, "w": 1440, "h": 900]]
        let response = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: ["windows": [other, main]])) as? [String: Any] ?? [:]
        #expect(VoiceToolProbe.harnessMainFrame(fromWindowsResponse: response) == CGRect(x: 289, y: 0, width: 920, height: 875))
        #expect(VoiceToolProbe.harnessMainFrame(fromWindowsResponse: ["windows": [other]]) == nil)
        // Live pair (2026-09-25): Finder's window server bounds and the harness's frame are one window.
        #expect(VoiceToolProbe.sameWindow(harnessMainFrame: CGRect(x: 289, y: 0, width: 920, height: 875),
                                          windowServerBounds: CGRect(x: 289, y: 25, width: 920, height: 875), primaryDisplayHeight: 900))
    }

    @Test func theHarnessesMainWindowMatchesTheWindowServersFrontAcrossTheFlip() {
        // Window server: top-left origin. Harness: AppKit, bottom-left, primary display 900 pt tall.
        let windowServer = CGRect(x: 100, y: 50, width: 800, height: 600)
        let appKit = CGRect(x: 100, y: 900 - 50 - 600, width: 800, height: 600)
        #expect(VoiceToolProbe.sameWindow(harnessMainFrame: appKit, windowServerBounds: windowServer, primaryDisplayHeight: 900))
        #expect(VoiceToolProbe.sameWindow(harnessMainFrame: appKit.offsetBy(dx: 1.5, dy: -1), windowServerBounds: windowServer, primaryDisplayHeight: 900))
        #expect(!VoiceToolProbe.sameWindow(harnessMainFrame: appKit.offsetBy(dx: 30, dy: 0), windowServerBounds: windowServer, primaryDisplayHeight: 900))
        // Unflipped, a window not at the vertical centre does not match: the conversion is load-bearing.
        #expect(!VoiceToolProbe.sameWindow(harnessMainFrame: windowServer, windowServerBounds: windowServer, primaryDisplayHeight: 900))
    }
}
