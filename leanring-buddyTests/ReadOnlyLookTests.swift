//
//  ReadOnlyLookTests.swift
//  leanring-buddyTests
//
//  A read-only task's click, judged by what is at the point (2026-11-04: launch L03, unseen F12). Pure: what the
//  harness reads there is given; that the read is right is proven live, by running the tasks.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct ReadOnlyLookTests {
    private func look(_ names: [String], role: String?, subrole: String? = nil, surface: HarnessPointer.Surface = .window,
                      owner: String? = "com.apple.systempreferences", marksRead: Bool = false) -> String? {
        HarnessPointer.lookRefusal(names: names, role: role, subrole: subrole, surface: surface, owner: owner, marksRead: { marksRead })
    }

    @Test func whatOnlyOpensOrShowsIsALook() {
        #expect(look(["General"], role: "AXStaticText") == nil, "a Settings row, F12")
        #expect(look(["Wi‑Fi, connected, 2 bars"], role: "AXMenuBarItem", surface: .menuBar, owner: "com.apple.MenuBarAgent") == nil, "L03")
        #expect(look(["Active Scheme"], role: "AXPopUpButton") == nil, "a pop-up opens")
        #expect(look(["Bin"], role: "AXDockItem", surface: .dock, owner: "com.apple.dock") == nil)
        #expect(look(["Tab two"], role: "AXRadioButton", subrole: "AXTabButton") == nil, "a tab only shows")
        #expect(look(["Show Sidebar"], role: "AXMenuItem") == nil)
    }

    @Test func anUnnamedPointActsOnlyInTheMenuBar() {
        #expect(look([], role: nil, surface: .menuBar, owner: "com.apple.controlcenter") != nil, "Control Centre's own window never")
        #expect(look([], role: nil, surface: .menuBar, owner: "com.apple.MenuBarAgent") == nil, "macOS 27: an icon may publish no name")
        #expect(look(["9:15 pm"], role: nil, surface: .menuBar, owner: "com.apple.finder") == nil, "words only, on the menu bar")
        #expect(look(["Send"], role: nil, surface: .menuBar, owner: "com.apple.finder") != nil)
        #expect(look([], role: nil) != nil, "in a window, nothing to judge by")
        #expect(look(["Bluetooth"], role: nil) != nil, "words alone cannot tell a switch from its label")
        #expect(look([], role: nil, surface: .other) != nil)
    }

    @Test func nothingThatChangesSomethingBecomesALook() {
        for name in ["Send", "Post", "Save", "Delete", "Buy", "Purchase", "Pay", "Empty Bin", "Connect", "Share"] {
            #expect(look([name], role: "AXButton") != nil, "\(name)")
        }
        for (role, subrole) in [("AXCheckBox", nil), ("AXCheckBox", "AXSwitch"), ("AXSwitch", nil), ("AXRadioButton", nil), ("AXSlider", nil), ("AXIncrementor", nil)] as [(String, String?)] {
            #expect(look(["Dark"], role: role, subrole: subrole) != nil, "\(role)")
        }
        #expect(look(["Pratik_Janki_5G"], role: "AXButton", owner: "com.apple.controlcenter") != nil, "inside a panel a row joins a network")
        #expect(look(["Wi‑Fi"], role: "AXStaticText", owner: "com.apple.controlcenter") != nil)
        #expect(look(["leanring-buddyTests"], role: "AXMenuItem") != nil, "picking in a pop-up changes it")
        #expect(look(["Move to Bin"], role: "AXMenuItem") != nil)
        #expect(look(["Sam: lunch?"], role: "AXStaticText", marksRead: true) != nil, "owner's ruling R2")
        #expect(look(["Inbox"], role: "AXButton", marksRead: true) == nil)
        #expect(look(["Nice"], role: "AXButton", owner: "com.apple.finder") == nil && look(["Nice", "Send it"], role: "AXButton") != nil,
                "the model's own label counts against it, never for it")
    }

    @Test func theGuardNarrowsEveryPressAndOnlyAPress() {
        final class Seen: @unchecked Sendable { var lines: [String] = [] }
        let seen = Seen()
        let guarded = AgentLoop.readOnlyGuardedAnswer({ seen.lines.append($0); return "{\"ok\":true}" }, readFocusedField: { nil })
        func sent(_ request: [String: Any]) -> [String: Any]? {
            let before = seen.lines.count
            _ = guarded(MeasurementLogFile.jsonLine(request) ?? "")
            guard seen.lines.count > before else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(seen.lines.last!.utf8)) as? [String: Any]
        }
        #expect(sent(["verb": "pointer", "action": "click", "nearPoint": ["x": 1, "y": 2]])?["onlyLooking"] as? Bool == true)
        #expect(sent(["verb": "click", "title": "General", "role": "AXButton"])?["onlyLooking"] as? Bool == true)
        #expect(sent(["verb": "select", "title": "General", "role": "AXRow"])?["onlyLooking"] as? Bool == true)
        #expect(sent(["verb": "pointer", "action": "scroll"])?["onlyLooking"] == nil)
        #expect(sent(["verb": "scroll", "direction": "down"])?["onlyLooking"] == nil)
        #expect(sent(["verb": "pointer", "action": "drag"]) == nil)
        #expect(sent(["verb": "pointer", "action": "doubleClick"]) == nil)
        #expect(sent(["verb": "click", "title": "Send", "role": "AXButton"]) == nil, "refused before the harness, by the request's own name")
        #expect(sent(["verb": "key", "keys": "return"]) == nil)
        #expect(sent(["verb": "key", "keys": "escape"]) != nil, "closing what it opened")
    }

    /// Generality G11 2026-11-04: Xcode's scheme is a pop-up's AXValue, under the name "Active Scheme".
    @Test func aPopUpSaysWhatItShows() {
        let element: [String: Any] = ["role": "AXPopUpButton", "name": "Active Scheme", "shows": "leanring-buddy"]
        #expect(AgentLoop.pageText(fromSnapshotResponse: ["elements": [element]]).text == "Active Scheme: leanring-buddy")
        var candidate = RealtimeScreenCandidate(name: "Active Scheme", role: "AXPopUpButton", frame: .zero, position: "")
        candidate.shows = "leanring-buddy"
        #expect(candidate.jsonObject["shows"] as? String == "leanring-buddy")
    }

    /// Unseen F07 2026-11-04: Go to Folder ~/.Trash landed in a child, and the answer read as "could not confirm".
    @Test func goToFolderSaysWhereFinderWentInstead() throws {
        #expect(HarnessGoToFolder.isHidden("~/.Trash", home: "/Users/a") && HarnessGoToFolder.isHidden("/tmp/.x/y", home: "/Users/a"))
        #expect(!HarnessGoToFolder.isHidden("~/JARVIS-sandbox", home: "/Users/a") && !HarnessGoToFolder.isHidden("/", home: "/Users/a"))
        typealias Window = HarnessGoToFolder.WindowReading
        let elsewhere = try #require(HarnessGoToFolder.arrivedElsewhere(before: Window(title: "Recent"), after: Window(title: ".trae-aicc")))
        #expect(elsewhere.contains(".trae-aicc") && elsewhere.contains("not the one asked for"))
        #expect(HarnessGoToFolder.arrivedElsewhere(before: Window(title: "Recent"), after: Window(title: "Recent")) == nil, "it may be an alert")
        #expect(HarnessGoToFolder.arrivedElsewhere(before: nil, after: nil) == nil)
    }
}

/// What a look opened, and what stands in the way of a step in another app.
struct OpenSurfaceTests {
    /// Generality G15 2026-11-04: ⇧⌘G in a Save sheet was refused as TextEdit's disabled Find Previous.
    @Test func aDisabledMenuItemOwnsNoKey() throws {
        func item(_ path: [String], enabled: Bool) -> AccessibilityMenu.ListedItem {
            AccessibilityMenu.ListedItem(path: path, role: "AXMenuItem", isEnabled: enabled, shortcut: "\u{21E7}\u{2318}G", hasSubmenu: false, isMarked: false)
        }
        let chord = try #require(HarnessKeys.parse("cmd+shift+g"))
        #expect(chord.display == HarnessPanels.goToFolderShortcut)
        #expect(HarnessKeys.menuMatch(chord, in: [item(["Edit", "Find Previous"], enabled: false)]) == .none)
        #expect(HarnessKeys.menuMatch(chord, in: [item(["Edit", "Find Previous"], enabled: true)]) == .one(["Edit", "Find Previous"]))
    }

    /// Live 2026-11-04, the same day: a model pressed "Allow" on a TCC prompt by position and was stopped only by this.
    @Test func aSystemPromptIsTheOwnersAlone() {
        for bundle in ["com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.coreservices.uiagent"] {
            let refusal = HarnessPointer.refusal(locked: false, onDisplay: true, windowOwner: .init(pid: 9, bundle: bundle), hitApp: nil, ownPID: 1,
                                                 ownBundle: "me", isRefused: { _ in false })
            #expect(refusal?.code == "systemPrompt", "\(bundle)")
        }
        #expect(HarnessPointer.refusal(locked: false, onDisplay: true, windowOwner: .init(pid: 9, bundle: "com.apple.finder"), hitApp: nil, ownPID: 1,
                                       ownBundle: "me", isRefused: { _ in false }) == nil)
    }

    @Test func insideAPanelOnlyADisclosureIsALook() {
        #expect(HarnessPointer.lookRefusal(names: ["Other Networks"], role: "AXDisclosureTriangle", subrole: nil, surface: .other,
                                           owner: AgentLoop.controlCentreBundleIdentifier, marksRead: { false }) == nil)
        #expect(HarnessPointer.lookRefusal(names: ["Wi‑Fi"], role: "AXCheckBox", subrole: "AXToggle", surface: .other,
                                           owner: AgentLoop.controlCentreBundleIdentifier, marksRead: { false }) != nil)
    }
}
