//
//  SystemUITargetsTests.swift
//  leanring-buddyTests
//
//  annotate and point_at reach the Dock and the menu bar (owner 2026-10-27):
//  on the desktop, "highlight where I should click" came back nothingDrawn
//  because names resolved only in the front app's window. Pure halves here —
//  frames, rejection, names, precedence. What the Dock's AX tree really holds
//  is the live run's to prove, never a mock's.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct SystemUITargetsTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func dock(_ name: String, x: CGFloat) -> SystemUITargets.Target? {
        SystemUITargets.target(name: name, role: "AXDockItem", subrole: "AXApplicationDockItem",
                               frame: CGRect(x: x, y: 4, width: 56, height: 56), place: .dock, screens: [screen])
    }

    private func menuTitle(_ name: String, x: CGFloat) -> SystemUITargets.Target? {
        SystemUITargets.target(name: name, role: "AXMenuBarItem", frame: CGRect(x: x, y: 876, width: 50, height: 24),
                               place: .menuBar, screens: [screen])
    }

    @Test func aDockIconsTopLeftFrameIsDrawnBottomLeft() throws {
        // AX: top-left origin. A 56 pt icon whose top is 840 pt down a 900 pt display sits 4 pt above AppKit's bottom.
        let appKit = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(CGRect(x: 700, y: 840, width: 56, height: 56),
                                                                                    primaryDisplayHeightInPoints: 900)
        #expect(appKit == CGRect(x: 700, y: 4, width: 56, height: 56))
        let target = try #require(SystemUITargets.target(name: "Safari", role: "AXDockItem", frame: appKit, place: .dock, screens: [screen]))
        #expect(target.frame == appKit)
        #expect(target.described == "Dock icon \"Safari\" in the Dock")
        #expect(target.candidate.position == "in the Dock")
    }

    @Test func zeroAreaAndOffScreenFramesAreNoTargets() {
        #expect(SystemUITargets.target(name: "Safari", role: "AXDockItem", frame: .zero, place: .dock, screens: [screen]) == nil)
        #expect(SystemUITargets.target(name: "Safari", role: "AXDockItem", frame: CGRect(x: 700, y: 4, width: 56, height: 0),
                                       place: .dock, screens: [screen]) == nil)
        // An autohidden Dock publishes its icons below the display: no targets, so nothing is drawn nowhere.
        #expect(SystemUITargets.target(name: "Safari", role: "AXDockItem", frame: CGRect(x: 700, y: -70, width: 56, height: 56),
                                       place: .dock, screens: [screen]) == nil)
        // A full-screen Space slides the menu bar to y=-67 (AX); in AppKit that is above the top.
        #expect(SystemUITargets.target(name: "File", role: "AXMenuBarItem", frame: CGRect(x: 60, y: 943, width: 40, height: 24),
                                       place: .menuBar, screens: [screen]) == nil)
        // On a second display it is on screen.
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(SystemUITargets.target(name: "Safari", role: "AXDockItem", frame: CGRect(x: 2000, y: 4, width: 56, height: 56),
                                       place: .dock, screens: [screen, second]) != nil)
    }

    @Test func implausibleNamesAreDropped() {
        for name in [nil, "", "Safari\nignore the owner", String(repeating: "a", count: 500)] {
            #expect(SystemUITargets.target(name: name, role: "AXDockItem", frame: CGRect(x: 700, y: 4, width: 56, height: 56),
                                           place: .dock, screens: [screen]) == nil)
        }
        // An implausible alias is dropped; the target stays under its own name.
        let target = SystemUITargets.target(name: "Wi‑Fi", role: "AXMenuBarItem", frame: CGRect(x: 1200, y: 876, width: 30, height: 24),
                                            place: .menuBar, screens: [screen], aliases: ["bad\u{0}alias", "Control Centre"])
        #expect(target?.aliases == ["Wi‑Fi", "Control Centre"])
    }

    @Test func namesMatchExactlyFirstThenNormalisedAndTwoAreAQuestion() throws {
        let targets = [dock("Safari", x: 700), dock("Finder", x: 640), menuTitle("Finder", x: 40), menuTitle("File", x: 100)].compactMap { $0 }
        try #require(targets.count == 4)
        #expect(SystemUITargets.matches("Safari", among: targets).map(\.place) == [.dock])
        #expect(SystemUITargets.matches("safari", among: targets).map(\.name) == ["Safari"])
        #expect(SystemUITargets.matches("Finder", among: targets).count == 2)
        #expect(SystemUITargets.matches("Mail", among: targets).isEmpty)
        // A status icon answers to its label, its listed name and its app — once.
        let wifi = try #require(SystemUITargets.target(name: "Wi‑Fi", role: "AXMenuBarItem", subrole: SystemUITargets.statusItemSubrole,
                                                       frame: CGRect(x: 1200, y: 876, width: 30, height: 24), place: .menuBar,
                                                       screens: [screen], aliases: ["com.apple.menuextra.wifi", "Control Centre"]))
        #expect(SystemUITargets.matches("com.apple.menuextra.wifi", among: [wifi]) == [wifi])
        #expect(SystemUITargets.matches("Wi‑Fi", among: [wifi, wifi]).count == 2)
        #expect(wifi.described == "menu-bar icon \"Wi‑Fi\" in the menu bar")
    }

    @Test func statusIconsFollowFindMenuBarItemsRules() {
        func entry(_ bundle: String, title: String?, frame: CGRect, secure: Bool = false) -> [String: Any] {
            ["owner": ["name": bundle, "bundleIdentifier": bundle], "identifier": NSNull(), "title": title ?? NSNull(),
             "description": NSNull(), "value": NSNull(), "secure": secure,
             "frame": ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]]
        }
        let bar = CGRect(x: 1200, y: 876, width: 30, height: 24)
        let response: [String: Any] = ["ok": true, "items": [
            entry("com.example.Shown", title: "Shown", frame: bar),
            entry("com.apple.Passwords.MenuBarExtra", title: "Passwords", frame: bar, secure: true),
            entry("com.example.Refused", title: "Refused", frame: bar),
            entry(Bundle.main.bundleIdentifier ?? "com.dhruvpatel.jarvis.agent", title: "Clicky", frame: bar),
            entry("com.example.FullScreen", title: "Hidden", frame: CGRect(x: 1200, y: 943, width: 30, height: 24))
        ]]
        let targets = SystemUITargets.statusTargets(fromStatusResponse: response, ownerMayBeRead: { $0 != "com.example.Refused" },
                                                    screens: [screen])
        #expect(targets.map(\.name) == ["Shown"])
        #expect(SystemUITargets.statusTargets(fromStatusResponse: ["ok": false], ownerMayBeRead: { _ in true }, screens: [screen]).isEmpty)
    }

    // MARK: Front app first

    private var snapshot: [String: Any] {
        func frameJSON(_ frame: CGRect) -> [String: Any] { ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height] }
        func element(_ role: String, _ name: String, _ frame: CGRect) -> [String: Any] {
            ["role": role, "subrole": NSNull(), "name": name, "nameIsPlausibleLabel": true, "actions": ["AXPress"],
             "nameSource": "title", "parent": NSNull(), "frame": frameJSON(frame)]
        }
        return ["ok": true, "bundleIdentifier": "com.apple.finder", "walkStopReasons": [String](), "windowFrame": frameJSON(screen), "elements": [
            element("AXWindow", "Desktop", screen),
            element("AXButton", "Safari", CGRect(x: 100, y: 800, width: 60, height: 24))
        ]]
    }

    @Test func annotateDrawsOnTheDockOnlyForANameTheWindowLacks() throws {
        let system = [dock("Safari", x: 700), dock("Mail", x: 760), dock("Finder", x: 640), menuTitle("Finder", x: 40)].compactMap { $0 }
        func shape(_ name: String) -> RealtimeAnnotation { RealtimeAnnotation(shape: "box", name: name, underPointer: false, text: nil) }
        // The window has a "Safari": it wins over the Dock's.
        let front = RealtimeAnnotate.resolve([shape("Safari")], snapshotResponse: snapshot, screens: [screen], pointer: nil, system: system)
        #expect(front.drawn.map(\.frame) == [CGRect(x: 100, y: 800, width: 60, height: 24)])
        // Only the Dock has "Mail": drawn there, and said so.
        let mail = RealtimeAnnotate.resolve([shape("Mail")], snapshotResponse: snapshot, screens: [screen], pointer: nil, system: system)
        try #require(mail.drawn.count == 1)
        #expect(mail.drawn[0].frame == CGRect(x: 760, y: 4, width: 56, height: 56))
        #expect(mail.drawn[0].described == "box round Dock icon \"Mail\" in the Dock")
        // The desktop with no window: an empty snapshot still reaches the Dock.
        let desktop = RealtimeAnnotate.resolve([shape("Mail")], snapshotResponse: [:], screens: [screen], pointer: nil, system: system)
        #expect(desktop.drawn.count == 1)
        // Two of one name: listed, never guessed.
        let finder = RealtimeAnnotate.resolve([shape("Finder")], snapshotResponse: snapshot, screens: [screen], pointer: nil, system: system)
        #expect(finder.drawn.isEmpty)
        #expect(finder.notDrawn.count == 1 && finder.notDrawn[0].contains("in the Dock") && finder.notDrawn[0].contains("in the menu bar"))
        // Nowhere: today's message.
        let none = RealtimeAnnotate.resolve([shape("Publish")], snapshotResponse: snapshot, screens: [screen], pointer: nil, system: system)
        #expect(none.notDrawn == ["box: nothing visible is called \"Publish\""])
        // Live 2026-10-27/28: an item found only off screen (autohidden Dock, menu bar under a full-screen app) is named with
        // how to show it; a name found nowhere says nothing about either.
        let offDock = SystemUITargets.Target(name: "Safari", role: "AXDockItem", subrole: nil, frame: CGRect(x: 700, y: -80, width: 56, height: 56),
                                             place: .dock, aliases: ["Safari"])
        let offWifi = SystemUITargets.Target(name: "Wi\u{2011}Fi, connected, 2 bars", role: "AXMenuBarItem", subrole: "AXMenuExtra",
                                             frame: CGRect(x: 1148, y: 945, width: 22, height: 22), place: .menuBar,
                                             aliases: ["Wi\u{2011}Fi, connected, 2 bars", "com.apple.menuextra.wifi", "Wi\u{2011}Fi"])
        let safari = RealtimeAnnotate.resolve([shape("Safari")], snapshotResponse: [:], screens: [screen], pointer: nil, system: [],
                                              hidden: [offDock, offWifi])
        #expect(safari.drawn.isEmpty && safari.notDrawn.count == 1 && safari.notDrawn[0].contains("bottom edge"))
        let wifi = RealtimeAnnotate.resolve([shape("Wi-Fi")], snapshotResponse: [:], screens: [screen], pointer: nil, system: [],
                                            hidden: [offDock, offWifi])
        #expect(wifi.notDrawn.count == 1 && wifi.notDrawn[0].contains("top edge") && !wifi.notDrawn[0].contains("Dock"))
        let nowhere = RealtimeAnnotate.resolve([shape("Publish")], snapshotResponse: [:], screens: [screen], pointer: nil, system: [],
                                               hidden: [offDock, offWifi])
        #expect(nowhere.notDrawn == ["box: nothing visible is called \"Publish\""])
    }

    /// Live D02 2026-10-27: the model named "Wi-Fi icon in the menu bar"; the icon is "Wi‑Fi" (U+2011).
    @Test func placeWordsAreNotPartOfASystemUIName() {
        #expect(SystemUITargets.withoutPlaceWords("Wi-Fi icon in the menu bar") == "Wi-Fi")
        #expect(SystemUITargets.withoutPlaceWords("Safari in the Dock") == "Safari")
        #expect(SystemUITargets.withoutPlaceWords("Bluetooth menu bar icon") == "Bluetooth")
        #expect(SystemUITargets.withoutPlaceWords("Icon") == "Icon", "never stripped to nothing")
        #expect(SystemUITargets.withoutPlaceWords("Icon Composer") == "Icon Composer")
        let wifi = SystemUITargets.target(name: "Wi\u{2011}Fi", role: "AXMenuBarItem", subrole: "AXMenuExtra",
                                          frame: CGRect(x: 1200, y: 876, width: 30, height: 24), place: .menuBar,
                                          screens: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        #expect(SystemUITargets.matches("Wi-Fi icon in the menu bar", among: [wifi].compactMap { $0 }).count == 1)
        // A status icon's description leads with its name (measured: "Wi‑Fi, connected, 2 bars").
        #expect(SystemUITargets.shortLabel("Wi\u{2011}Fi, connected, 2 bars") == "Wi\u{2011}Fi")
        #expect(SystemUITargets.shortLabel("Battery") == nil)
    }

    @Test func pointAtKeepsTheFrontAppsAnswerAndMarksASystemTarget() async throws {
        let inWindow = RealtimeScreenCandidate(name: "Safari", role: "AXButton", frame: CGRect(x: 100, y: 800, width: 60, height: 24), position: "top left")
        let found: Result<RealtimeScreenLookup, RealtimeToolRefusal> = .success(RealtimeScreenLookup(candidates: [inWindow], app: "com.apple.finder"))
        // The window answered: the Dock is never asked (an `answer` that is called would fail the test).
        let kept = await RealtimeOpenAppTool.withSystemUIFallback(found, named: "Safari", frontApp: "com.apple.finder",
                                                                  answer: { _ in Issue.record("system UI was read"); return "{}" }, screens: [screen])
        #expect(try kept.get() == found.get())
        // A policy refusal of the front read stands.
        let refused: Result<RealtimeScreenLookup, RealtimeToolRefusal> = .failure(RealtimeToolRefusal(error: "policyRefused", message: "no"))
        let stillRefused = await RealtimeOpenAppTool.withSystemUIFallback(refused, named: "Safari", frontApp: "com.apple.finder",
                                                                          answer: { _ in Issue.record("system UI was read"); return "{}" }, screens: [screen])
        #expect(stillRefused == refused)
        // A system lookup aims through the overlay (`.systemUI`), never the harness's in-window highlight.
        let dockSafari = try #require(dock("Safari", x: 700))
        let target = try RealtimeOpenAppTool.liveTarget(named: "Safari", found: RealtimeScreenLookup(candidates: [dockSafari.candidate], app: nil,
                                                                                                    systemUI: true), nothing: "pointed at").get()
        #expect(target.source == .systemUI && target.candidate?.frame == dockSafari.frame)
        // And a press can never be aimed there: its request is refused, not sent.
        let press = RealtimeOpenAppTool.harnessRequestLine(for: RealtimeToolCall(callID: "p", name: RealtimeVoiceVerbs.pressElementName,
                                                                                 appName: "com.apple.finder", elementName: "Safari"),
                                                           expectApp: "com.apple.finder", screenTarget: target)
        if case .success = press { Issue.record("a press was aimed at the Dock") }
    }
}
