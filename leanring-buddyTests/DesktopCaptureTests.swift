//
//  DesktopCaptureTests.swift
//  leanring-buddyTests
//
//  Owner's ruling 2026-10-30, "desktop screenshots: yes": `look` photographs the
//  whole display only with Finder in front and no app window on screen. The
//  decision, from plain window-server dictionaries; no capture here.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct DesktopCaptureTests {
    static let ownPID: pid_t = 100
    static let finder = "com.apple.finder"

    static func window(pid: pid_t, layer: Int = 0, alpha: Double = 1, width: Double = 800, height: Double = 600) -> [String: Any] {
        [kCGWindowOwnerPID as String: Int(pid), kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": width, "Height": height]]
    }

    static func bare(_ list: [[String: Any]], front: String? = finder) -> Bool {
        EscalationLadder.isBareDesktop(frontBundleIdentifier: front, windowList: list, ownPID: ownPID)
    }

    // Menu bar 24, Dock 20, a notification 23, a click-through overlay 1000.
    static let chrome: [[String: Any]] = [window(pid: 7, layer: 24), window(pid: 8, layer: 20),
                                           window(pid: 9, layer: 23), window(pid: 10, layer: 1000)]

    @Test func finderInFrontWithNoAppWindowIsTheDesktop() {
        #expect(Self.bare(Self.chrome))
        // Clicky's own windows, at any layer, never count.
        #expect(Self.bare(Self.chrome + [Self.window(pid: Self.ownPID), Self.window(pid: Self.ownPID, layer: 25)]))
        // Invisible or empty layer-0 windows draw nothing.
        #expect(Self.bare(Self.chrome + [Self.window(pid: 11, alpha: 0), Self.window(pid: 12, width: 0)]))
    }

    @Test func anyOrdinaryWindowOnScreenRefuses() {
        #expect(!Self.bare(Self.chrome + [Self.window(pid: 11)]), "another app's window")
        #expect(!Self.bare(Self.chrome + [Self.window(pid: 2)]), "Finder's own window")
    }

    @Test func onlyFinderInFrontTakesTheDesktop() {
        #expect(!Self.bare(Self.chrome, front: "com.apple.TextEdit"))
        #expect(!Self.bare(Self.chrome, front: nil))
    }

    @Test func aWindowThatDoesNotReadCounts() {
        #expect(!Self.bare(Self.chrome + [[kCGWindowLayer as String: 0]]), "no owner")
        #expect(!Self.bare(Self.chrome + [[kCGWindowOwnerPID as String: 11]]), "no layer, alpha or bounds")
    }

    // MARK: what a desktop capture draws (security review 2026-10-30)

    static let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    static func record(_ bundle: String?, _ layer: Int, _ frame: CGRect = display, pid: pid_t = 50,
                       onScreen: Bool = true) -> EscalationLadder.DesktopWindowRecord {
        .init(ownerBundle: bundle, ownerPID: pid, layer: layer, frame: frame, isOnScreen: onScreen)
    }

    static func drawn(_ windows: [EscalationLadder.DesktopWindowRecord], refused: Set<String> = []) -> [Int] {
        EscalationLadder.desktopWindowsToDraw(windows, displayBounds: display, ownPID: ownPID, isRefused: { refused.contains($0) })
    }

    static let menuStrip = CGRect(x: 0, y: 0, width: 1440, height: 30)
    static let statusItem = CGRect(x: 1200, y: 0, width: 30, height: 30)

    @Test func theDesktopItselfIsDrawn() {
        let windows = [Self.record("com.apple.wallpaper.agent", -2147483625),
                       Self.record("com.apple.dock", Int(CGWindowLevelForKey(.desktopWindow))),
                       Self.record(Self.finder, Int(CGWindowLevelForKey(.desktopIconWindow))),
                       Self.record("com.apple.dock", 20, CGRect(x: 300, y: 830, width: 840, height: 70)),
                       Self.record(nil, 24, Self.menuStrip, pid: 0),
                       Self.record("", 24, Self.menuStrip, pid: 0),
                       Self.record("com.apple.controlcenter", 25, Self.statusItem),
                       Self.record("com.apple.systemuiserver", 25, Self.statusItem),
                       Self.record("com.ameba.SwiftBar", 25, Self.statusItem)]
        #expect(Self.drawn(windows) == Array(windows.indices))
    }

    @Test func nothingElseIsDrawn() {
        let windows = [Self.record("com.apple.Stickies", 3, CGRect(x: 100, y: 100, width: 300, height: 300)),
                       Self.record("com.apple.Terminal", 0), Self.record("com.googlecode.iterm2", 3),
                       Self.record("com.google.Chrome", 8, CGRect(x: 900, y: 600, width: 400, height: 225)),
                       Self.record("com.electron.wispr-flow", 1000, CGRect(x: 464, y: 286, width: 512, height: 614)),
                       Self.record("com.apple.notificationcenterui", -2147483601, CGRect(x: 8, y: 38, width: 360, height: 180)),
                       Self.record("com.apple.notificationcenterui", 23),
                       Self.record("com.1password.1password", 25, Self.statusItem),
                       Self.record("com.1password.1password", 3), Self.record("com.apple.Passwords.MenuBarExtra", 101),
                       Self.record("com.dhruvpatel.jarvis.agent", 25, Self.statusItem, pid: Self.ownPID),
                       Self.record(nil, 24, Self.menuStrip, pid: Self.ownPID),
                       Self.record("com.refused.app", 25, Self.statusItem),
                       // A status item's panel is taller than the strip; a Finder window is layer 0.
                       Self.record("com.apple.controlcenter", 25, CGRect(x: 1000, y: 30, width: 300, height: 400)),
                       Self.record(Self.finder, 0, CGRect(x: 100, y: 100, width: 800, height: 500)),
                       Self.record("com.apple.wallpaper.agent", 0), Self.record("com.apple.wallpaper.agent", -2147483625, onScreen: false),
                       Self.record("com.apple.dock", 20, .zero)]
        #expect(Self.drawn(windows, refused: ["com.refused.app"]).isEmpty)
    }

    @MainActor @Test func theAgentIsToldItSeesTheDesktop() {
        var observation = AgentObservation()
        observation.jpeg = Data([0xFF])
        observation.look = "attached"
        observation.desktop = true
        let text = AgentLoop.observationBlocks(observation, step: 1).compactMap { $0["text"] as? String }.joined()
        #expect(text.contains("the desktop, with its Dock and menu bar") && text.contains("Aim by position"))
        observation.desktop = false
        #expect(AgentLoop.observationBlocks(observation, step: 1).compactMap { $0["text"] as? String }.joined()
            .contains("the window in front"))
    }
}
