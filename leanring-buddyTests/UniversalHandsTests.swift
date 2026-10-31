//
//  UniversalHandsTests.swift
//  leanring-buddyTests
//
//  Slice A of the universal screen hands (owner's ruling 2026-10-31): `look` tier
//  `screen`, the `pointer` verb and the `key` verb. These prove the pure half — the
//  guard order, the surface a point is on, the AppKit -> CGEvent flip on a second
//  display, what the kernel judges, the ticket's shape, key parsing and menu
//  matching, the capture's exclusion list. Whether a click lands is the live run's
//  question, answered by the window list, never by the verb.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct UniversalHandsTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// CG top-left frame of the primary display.
    private let primaryTopLeft = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func window(layer: Int, bundle: String? = nil, _ bounds: CGRect) -> HarnessPointer.WindowAtPoint {
        HarnessPointer.WindowAtPoint(number: 1, ownerPID: 10, ownerBundle: bundle, ownerName: nil, layer: layer, bounds: bounds)
    }

    private func line(_ raw: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
    }

    // MARK: Where the point is

    @Test func theSurfaceComesFromTheWindowServersLayerAndOwner() {
        let statusItem = window(layer: 25, bundle: "com.apple.controlcenter", CGRect(x: 1300, y: 0, width: 30, height: 30))
        let menuBar = window(layer: 24, CGRect(x: 0, y: 0, width: 1440, height: 30))
        #expect(HarnessPointer.surface(statusItem, displayTopLeft: primaryTopLeft) == .menuBar)
        #expect(HarnessPointer.surface(menuBar, displayTopLeft: primaryTopLeft) == .menuBar)
        #expect(HarnessPointer.surface(window(layer: 20, bundle: "com.apple.dock", CGRect(x: 300, y: 830, width: 800, height: 70)),
                                       displayTopLeft: primaryTopLeft) == .dock)
        #expect(HarnessPointer.surface(window(layer: -2147483603, bundle: "com.apple.finder", primaryTopLeft), displayTopLeft: primaryTopLeft) == .desktop)
        #expect(HarnessPointer.surface(window(layer: -2147483625, bundle: "com.apple.wallpaper.agent", primaryTopLeft), displayTopLeft: primaryTopLeft) == .desktop)
        #expect(HarnessPointer.surface(window(layer: 0, bundle: "com.apple.finder", CGRect(x: 200, y: 200, width: 800, height: 500)),
                                       displayTopLeft: primaryTopLeft) == .window)
        // A status-level panel that hangs below the strip (an open Control Centre panel) is not the bar.
        #expect(HarnessPointer.surface(window(layer: 25, bundle: "com.apple.controlcenter", CGRect(x: 1100, y: 30, width: 330, height: 400)),
                                       displayTopLeft: primaryTopLeft) == .other)
        // A layer-20 window that is not the Dock's is not the Dock.
        #expect(HarnessPointer.surface(window(layer: 20, bundle: "com.example.app", CGRect(x: 0, y: 830, width: 10, height: 10)),
                                       displayTopLeft: primaryTopLeft) == .other)
        // The menu bar of a SECOND display above the primary: its strip is at negative CG y.
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(HarnessPointer.surface(window(layer: 25, CGRect(x: 1800, y: -1080, width: 30, height: 30)), displayTopLeft: above) == .menuBar)
        #expect(HarnessPointer.surface(window(layer: 25, CGRect(x: 1800, y: -1080, width: 30, height: 30)), displayTopLeft: primaryTopLeft) == .other)
    }

    /// The invariant that fails silently: AppKit is bottom-left, y up; CGEvent is top-left,
    /// y down — against the PRIMARY display's height, so a second display needs no other case.
    @Test func appKitPointsFlipToCGEventPointsOnEveryDisplay() {
        // Primary 1440x900: the menu bar's middle (y 885 in AppKit) is 15 pt from the top.
        #expect(HarnessPointer.topLeft(CGPoint(x: 1300, y: 885), primaryDisplayHeight: 900) == CGPoint(x: 1300, y: 15))
        // A 1920x1080 display ABOVE the primary is AppKit y 900...1980; its top edge is CG y -1080.
        #expect(HarnessPointer.topLeft(CGPoint(x: 100, y: 1980), primaryDisplayHeight: 900) == CGPoint(x: 100, y: -1080))
        #expect(HarnessPointer.topLeft(CGPoint(x: 100, y: 1500), primaryDisplayHeight: 900) == CGPoint(x: 100, y: -600))
        // A display to the LEFT, bottoms aligned: x goes negative and y flips as on the primary.
        #expect(HarnessPointer.topLeft(CGPoint(x: -500, y: 100), primaryDisplayHeight: 900) == CGPoint(x: -500, y: 800))
        // Which display: one that holds the point, or none — never the nearest.
        let displays = [screen, CGRect(x: 0, y: 900, width: 1920, height: 1080)]
        #expect(HarnessPointer.display(holding: CGPoint(x: 100, y: 1500), among: displays) == displays[1])
        #expect(HarnessPointer.display(holding: CGPoint(x: 1500, y: 100), among: displays) == nil)
    }

    // MARK: The guard order

    @Test func theRefusalsComeInOneOrderAndClickyIsNeverTheTarget() {
        let own: pid_t = 999
        let owner = HarnessPointer.Owner(pid: 10, bundle: "com.apple.finder")
        func refusal(locked: Bool = false, onDisplay: Bool = true, windowOwner: HarnessPointer.Owner? = owner,
                     hitApp: HarnessPointer.Owner? = nil, refused: Set<String> = [], hit: RealtimeScreenHit? = nil) -> String? {
            HarnessPointer.refusal(locked: locked, onDisplay: onDisplay, windowOwner: windowOwner, hitApp: hitApp, ownPID: own,
                                   ownBundle: "com.example.clicky", isRefused: { $0.map(refused.contains) ?? false }, hit: hit)?.code
        }
        #expect(refusal() == nil)
        // Locked beats everything, then off-screen, then an unreadable point.
        #expect(refusal(locked: true, onDisplay: false, windowOwner: nil) == "screenIsLocked")
        #expect(refusal(onDisplay: false, windowOwner: nil) == "pointNotOnScreen")
        #expect(refusal(windowOwner: nil) == "pointUnreadable")
        // Clicky by process or by bundle, as the window's owner or as the AX hit's app — before anything else.
        let clicky = HarnessPointer.Owner(pid: own, bundle: "1password")
        #expect(refusal(windowOwner: clicky) == "targetIsHarnessItself")
        #expect(refusal(windowOwner: HarnessPointer.Owner(pid: 5, bundle: "com.example.clicky")) == "targetIsHarnessItself")
        #expect(refusal(hitApp: HarnessPointer.Owner(pid: -1, bundle: "com.example.clicky")) == "targetIsHarnessItself")
        // A password manager, then a policy refusal — for either owner.
        #expect(refusal(windowOwner: HarnessPointer.Owner(pid: 5, bundle: "com.1password.1password")) == "passwordManager")
        #expect(refusal(hitApp: HarnessPointer.Owner(pid: -1, bundle: "com.apple.Passwords")) == "passwordManager")
        #expect(refusal(refused: ["com.apple.finder"]) == "policyRefused")
        // The menu bar's titles are the Window Server's windows but act in the front app: the hit's app counts too.
        #expect(refusal(windowOwner: HarnessPointer.Owner(pid: 669, bundle: nil), hitApp: HarnessPointer.Owner(pid: -1, bundle: "com.apple.mail"),
                        refused: ["com.apple.mail"]) == "policyRefused")
        // The AX hit's own refusal comes last: a password box.
        #expect(refusal(hit: .refused(error: "secureField")) == "secureField")
        #expect(refusal(refused: ["com.apple.finder"], hit: .refused(error: "secureField")) == "policyRefused")
        #expect(refusal(hit: .nothing) == nil)
    }

    // MARK: What the kernel judges

    private func decide(_ action: PointerAction = .click, names: [String], label: String? = nil, role: String? = nil,
                        bundle: String? = "com.apple.dock") -> SafetyDecision {
        HarnessPointer.decision(action: action, names: names, label: label, role: role, subrole: nil,
                                frame: CGRect(x: 600, y: 10, width: 40, height: 40), visibleBounds: screen,
                                ownerBundle: bundle, draftScope: false)
    }

    @Test func theWordsAtThePointAreJudgedAsAClickJudgesThem() {
        // A Dock icon or a status icon is judged by its words, never carded as an unknown role.
        #expect(decide(names: ["Safari"], role: "AXDockItem") == .allow)
        #expect(decide(names: [], role: nil) == .allow)
        // A drop on the Trash is destructive: asked, never "always".
        guard case .requireConfirmation(_, true) = decide(.drag, names: ["Trash"], role: "AXDockItem") else {
            Issue.record("a drop on the Trash did not ask"); return
        }
        // Irreversible words refuse, whoever wrote them — the model's label included.
        guard case .refuse = decide(names: ["Empty Trash"]) else { Issue.record("Empty Trash was not refused"); return }
        guard case .refuse = decide(names: ["Settings"], label: "Buy now") else { Issue.record("a label saying buy was not refused"); return }
        // No name at the point, the model's words alone still get the word lists.
        guard case .requireConfirmation = decide(names: [], label: "Delete") else { Issue.record("the label alone was not judged"); return }
        // A switch keeps its role, so the connectivity rule still asks.
        guard case .requireConfirmation = decide(names: ["Wi-Fi"], role: "AXCheckBox") else { Issue.record("a Wi-Fi switch did not ask"); return }
        // A hover and a wheel change nothing a card protects.
        #expect(decide(.move, names: ["Delete"]) == .allow)
        #expect(decide(.scroll, names: ["Delete"]) == .allow)
        // A double-click in Finder opens the item, and opening always asks.
        guard case .requireConfirmation = decide(.doubleClick, names: ["notes.txt"], bundle: "com.apple.finder") else {
            Issue.record("a Finder double-click did not ask"); return
        }
        #expect(decide(.doubleClick, names: ["notes.txt"], bundle: "com.apple.TextEdit") == .allow)
        // The strongest of several: refuse > destructive ask > ask > allow.
        let ask = SafetyDecision.requireConfirmation(reason: "a")
        let destructive = SafetyDecision.requireConfirmation(reason: "d", destructive: true)
        #expect(HarnessPointer.strongest([.allow, ask, destructive]) == destructive)
        #expect(HarnessPointer.strongest([destructive, .refuse(reason: "r"), .allow]) == .refuse(reason: "r"))
        #expect(HarnessPointer.strongest([]) == .allow)
    }

    @Test func aParagraphIsNotANameSoTheWordAloneIsJudged() {
        #expect(HarnessPointer.judgedOCRText(word: "Pay", line: "Pay now") == "Pay now")
        let paragraph = String(repeating: "lorem ipsum dolor sit amet ", count: 20)
        #expect(HarnessPointer.judgedOCRText(word: "dolor", line: paragraph) == "dolor")
        #expect(HarnessPointer.judgedOCRText(word: "Go", line: nil) == "Go")
    }

    @Test func aNamedControlIsAimedAtItsVisibleCentreAndAPaneIsNot() {
        let icon = CGRect(x: 1290, y: 872, width: 30, height: 24)
        #expect(HarnessPointer.aimPoint(requested: CGPoint(x: 1295, y: 880), elementFrame: icon, display: screen) == CGPoint(x: 1305, y: 884))
        // A whole pane: the requested point, not the pane's middle.
        let pane = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(HarnessPointer.aimPoint(requested: CGPoint(x: 50, y: 50), elementFrame: pane, display: screen) == CGPoint(x: 50, y: 50))
        // A point outside the frame keeps the point; no frame keeps the point.
        #expect(HarnessPointer.aimPoint(requested: CGPoint(x: 10, y: 10), elementFrame: icon, display: screen) == CGPoint(x: 10, y: 10))
        #expect(HarnessPointer.aimPoint(requested: CGPoint(x: 10, y: 10), elementFrame: nil, display: screen) == CGPoint(x: 10, y: 10))
        // Clipped to the display first: half off the right edge aims at the visible half.
        let clipped = CGRect(x: 1420, y: 100, width: 40, height: 20)
        #expect(HarnessPointer.aimPoint(requested: CGPoint(x: 1430, y: 110), elementFrame: clipped, display: screen) == CGPoint(x: 1430, y: 110))
    }

    // MARK: What a ticket binds

    @Test func aTicketBindsTheActionThePointsTheWordsAndTheLabel() throws {
        var request = try HarnessPolicy.decode(line: line(["verb": "pointer", "action": "drag", "nearPoint": ["x": 200.4, "y": 300.6],
                                                           "to": ["x": 700.2, "y": 850.7], "label": "the report"])).get()
        #expect(request.nearPoint == CGPoint(x: 200, y: 301))
        #expect(request.to == CGPoint(x: 700, y: 851))
        request.title = HarnessPointer.cardTarget(action: .drag, from: "report.txt", to: "Trash", toPoint: request.to, label: request.label)
        #expect(request.title == "\u{201C}report.txt\u{201D} onto \u{201C}Trash\u{201D} at (700, 851) (the model called it \u{201C}the report\u{201D})")
        let drag = HarnessServer.confirmationShape(for: request, bundleIdentifier: "com.apple.finder", verb: "pointer.drag")
        #expect(drag.nearPoint == CGPoint(x: 200, y: 301) && drag.rawTarget == request.title)
        // The same point, another action: a different question.
        let click = HarnessServer.confirmationShape(for: request, bundleIdentifier: "com.apple.finder", verb: "pointer.click")
        #expect(HarnessConfirmations.mismatchedField(approved: drag, click) == "verb")
        // Another drop point: a different target.
        var moved = request
        moved.title = HarnessPointer.cardTarget(action: .drag, from: "report.txt", to: "Trash", toPoint: CGPoint(x: 10, y: 10), label: request.label)
        let elsewhere = HarnessServer.confirmationShape(for: moved, bundleIdentifier: "com.apple.finder", verb: "pointer.drag")
        #expect(HarnessConfirmations.mismatchedField(approved: drag, elsewhere) == "target")
        // A click names nothing about a drop, and no label adds nothing.
        #expect(HarnessPointer.cardTarget(action: .click, from: "Battery", to: nil, toPoint: nil, label: nil) == "\u{201C}Battery\u{201D}")
        #expect(HarnessPointer.cardTarget(action: .click, from: nil, to: nil, toPoint: nil, label: "Battery") ==
                "what is drawn there (the model called it \u{201C}Battery\u{201D})")
        // The card says it in our words.
        let lines = HarnessConfirmations.displayLines(for: drag, appName: "Finder")
        #expect(lines.first == "Drag on the screen in \"Finder\"?")
        #expect(lines.contains { $0.hasPrefix("Drags ") && $0.contains("aimed by position") })
        let key = HarnessConfirmations.Shape(verb: "key", bundleIdentifier: "com.apple.finder", rawTarget: "\u{2318}K")
        #expect(HarnessConfirmations.displayLines(for: key, appName: "Finder").first?.hasPrefix("Press a keyboard shortcut in") == true)
    }

    // MARK: Decoding

    @Test func pointerAndKeyRequestsAreValidatedLikeEveryOtherVerb() {
        func code(_ raw: [String: Any]) -> String? {
            if case .failure(let error) = HarnessPolicy.decode(line: line(raw)) { return error.code }
            return nil
        }
        let point: [String: Any] = ["x": 10, "y": 20]
        #expect(code(["verb": "pointer", "action": "click", "nearPoint": point]) == nil)
        #expect(code(["verb": "pointer", "nearPoint": point]) == "missingField")
        #expect(code(["verb": "pointer", "action": "click"]) == "missingField")
        #expect(code(["verb": "pointer", "action": "tap", "nearPoint": point]) == "invalidField")
        #expect(code(["verb": "pointer", "action": "drag", "nearPoint": point]) == "missingField")
        #expect(code(["verb": "pointer", "action": "click", "nearPoint": point, "to": point]) == "invalidField")
        #expect(code(["verb": "pointer", "action": "scroll", "nearPoint": point]) == "missingField")
        #expect(code(["verb": "pointer", "action": "scroll", "nearPoint": point, "direction": "down", "amount": 2]) == nil)
        #expect(code(["verb": "pointer", "action": "click", "nearPoint": point, "direction": "down"]) == "invalidField")
        #expect(code(["verb": "pointer", "action": "click", "nearPoint": point, "label": "line one\nline two"]) == "invalidField")
        #expect(code(["verb": "click", "title": "OK", "action": "click"]) == "invalidField")
        // The whole display is a `look` of its own.
        #expect(code(["verb": "look", "tier": "screen"]) == nil)
        #expect(code(["verb": "press", "title": "OK", "tier": "screen"]) == "invalidField")
        // key
        #expect(code(["verb": "key", "keys": "cmd+shift+d"]) == nil)
        #expect(code(["verb": "key"]) == "missingField")
        #expect(code(["verb": "key", "keys": "hyper+x"]) == "invalidField")
        #expect(code(["verb": "press", "title": "OK", "keys": "escape"]) == "invalidField")
        // Both act, so the kill switch stops them, and both can carry an unnamed-app card.
        #expect(HarnessVerb.pointer.isMutating && HarnessVerb.key.isMutating)
        #expect(HarnessVerb.gatedForUnnamedApp.isSuperset(of: [.pointer, .key]))
        // A key never goes into a password being typed.
        let typing = SecureInputState(isOn: true, holderPID: 1, holderName: "Safari", holderIsFrontmost: true)
        #expect(HarnessPolicy.handOverRefusal(verb: .key, secureInput: typing) != nil)
        #expect(HarnessPolicy.handOverRefusal(verb: .pointer, secureInput: typing) == nil)
    }

    // MARK: Keys

    @Test func keysParseToTheShortcutAMenuShows() {
        #expect(HarnessKeys.parse("cmd+shift+d")?.display == "\u{21E7}\u{2318}D")
        #expect(HarnessKeys.parse("Command + Q")?.display == "\u{2318}Q")
        #expect(HarnessKeys.parse("ctrl+opt+cmd+t")?.display == "\u{2303}\u{2325}\u{2318}T")
        #expect(HarnessKeys.parse("esc")?.key == "escape")
        #expect(HarnessKeys.parse("page down")?.key == "pagedown")
        #expect(HarnessKeys.parse("shift+tab") == KeyChord(shift: true, key: "tab"))
        #expect(HarnessKeys.parse("return")?.isPlain == true)
        for bad in ["", "cmd+", "hyper+x", "cmd+shift", "ctrlx", "cmd+ab"] { #expect(HarnessKeys.parse(bad) == nil, "\(bad)") }
        // Every parsed key has a code to post.
        for key in HarnessKeys.namedKeys.keys { #expect(HarnessKeys.keyCode(for: KeyChord(key: key)) != nil) }
        // An arrow shortcut is compared in the menu's own private-use character, as `menus` lists it.
        #expect(HarnessKeys.parse("cmd+up")?.display == AccessibilityMenu.describeShortcut(character: "\u{F700}", modifiers: 0))
        #expect(HarnessKeys.parse("cmd+backspace")?.display == "\u{2318}\u{232B}")
    }

    private func item(_ path: [String], _ shortcut: String?, enabled: Bool = true, submenu: Bool = false) -> AccessibilityMenu.ListedItem {
        AccessibilityMenu.ListedItem(path: path, role: "AXMenuItem", isEnabled: enabled, shortcut: shortcut, hasSubmenu: submenu, isMarked: false)
    }

    @Test func aShortcutIsTheMenuItemThatOwnsItAndNeverACoinFlip() throws {
        let chord = try #require(HarnessKeys.parse("cmd+shift+n"))
        let items = [item(["File", "New Window"], "\u{2318}N"), item(["File", "New Folder"], "\u{21E7}\u{2318}N"),
                     item(["Go", "Recents"], nil), item(["File", "Open With"], "\u{21E7}\u{2318}N", submenu: true)]
        #expect(HarnessKeys.menuMatch(chord, in: items) == .one(["File", "New Folder"]))
        // Two items, one enabled: the enabled one.
        let twice = items + [item(["Edit", "Alt New"], "\u{21E7}\u{2318}N", enabled: false)]
        #expect(HarnessKeys.menuMatch(chord, in: twice) == .one(["File", "New Folder"]))
        // Two enabled: never chosen between.
        let both = items + [item(["Edit", "Other"], "\u{21E7}\u{2318}N")]
        #expect(HarnessKeys.menuMatch(chord, in: both) == .ambiguous(["File > New Folder", "Edit > Other"]))
        #expect(HarnessKeys.menuMatch(try #require(HarnessKeys.parse("cmd+k")), in: items) == .none)
        // Menus own shortcuts, not bare navigation keys.
        #expect(!HarnessKeys.asksMenus(try #require(HarnessKeys.parse("escape"))))
        #expect(!HarnessKeys.asksMenus(try #require(HarnessKeys.parse("shift+tab"))))
        #expect(HarnessKeys.asksMenus(try #require(HarnessKeys.parse("cmd+down"))))
        #expect(HarnessKeys.asksMenus(try #require(HarnessKeys.parse("shift+a"))))
    }

    @Test func aKeyNoMenuOwnsIsPostedOnlyWhenItCannotDoHarm() throws {
        func route(_ keys: String) throws -> HarnessKeys.Unmatched { HarnessKeys.unmatched(try #require(HarnessKeys.parse(keys))) }
        #expect(try route("escape") == .post)
        #expect(try route("down") == .post)
        #expect(try route("shift+tab") == .post)
        #expect(try route("space") == .space)
        #expect(try route("return") == .returnKey)
        #expect(try route("enter") == .returnKey)
        guard case .ask = try route("cmd+k") else { Issue.record("an unknown shortcut did not ask"); return }
        guard case .ask = try route("ctrl+down") else { Issue.record("a modified arrow did not ask"); return }
        guard case .ask = try route("x") else { Issue.record("a bare letter did not ask"); return }
        guard case .ask = try route("delete") else { Issue.record("delete did not ask"); return }

        // Return is judged by what it presses.
        func returning(_ button: String?, text: Bool = false, app: String = "com.apple.TextEdit") -> SafetyDecision {
            HarnessKeys.returnDecision(defaultButtonTitle: button, focusIsTextInput: text, bundleIdentifier: app,
                                       visibleBounds: screen, draftScope: false)
        }
        #expect(returning("OK") == .allow)
        #expect(returning(nil) == .allow)
        guard case .requireConfirmation(_, true) = returning("Delete") else { Issue.record("Return on a Delete button did not ask"); return }
        guard case .refuse = returning("Erase") else { Issue.record("Return on Erase was not refused"); return }
        // From a text field Return submits: a sending app asks, once.
        guard case .requireConfirmation(_, true) = returning(nil, text: true, app: "net.whatsapp.WhatsApp") else {
            Issue.record("Return in a chat composer did not ask"); return
        }
        #expect(returning(nil, text: true, app: "com.apple.Notes") == .allow)
    }

    // MARK: Evidence

    @Test func theWindowListSaysWhatAppearedAndWhatWent() {
        let before = [1: "Finder (layer 0)", 2: "Dock (layer 20)"]
        let after = [2: "Dock (layer 20)", 7: "Control Centre (layer 25)"]
        let change = HarnessPointer.windowListChange(before: before, after: after)
        #expect(change.appeared == ["Control Centre (layer 25)"])
        #expect(change.disappeared == ["Finder (layer 0)"])
        #expect(HarnessPointer.windowListChange(before: before, after: before).appeared.isEmpty)
        // The pixel crop stays on its display at the corner.
        let corner = HarnessPointer.evidenceRegion(around: CGPoint(x: 1435, y: 895), display: screen)
        #expect(corner == CGRect(x: 1200, y: 660, width: 240, height: 240))
        #expect(HarnessPointer.evidenceRegion(around: CGPoint(x: 700, y: 400), display: screen) == CGRect(x: 580, y: 280, width: 240, height: 240))
    }

    // MARK: The whole-display capture

    @Test func theScreenLeavesOutClickyPasswordManagersAndRefusedAppsByApplication() {
        let apps: [(bundleIdentifier: String?, processID: pid_t)] = [
            ("com.apple.finder", 10), ("com.example.clicky", 20), ("com.1password.1password", 30), ("com.apple.mail", 40),
            ("", 50), ("com.apple.dock", 60), ("com.example.renamed", 999)
        ]
        let left = CompanionScreenCaptureUtility.applicationsLeftOut(apps, ownPID: 999, ownBundleIdentifier: "com.example.clicky",
                                                                     isRefused: { $0 == "com.apple.mail" })
        #expect(left == [1, 2, 3, 6])
        // A policy whose default is refuse leaves out what has no bundle identifier too (Window Server).
        let strict = CompanionScreenCaptureUtility.applicationsLeftOut(apps, ownPID: 999, ownBundleIdentifier: "com.example.clicky",
                                                                       isRefused: { $0 != "com.apple.finder" })
        #expect(strict == [1, 2, 3, 4, 5, 6])
        // The display: the one holding the focused window, else the main one.
        let displays = [screen, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(CompanionScreenCaptureUtility.harnessDisplayIndex(focusedWindowFrame: CGRect(x: 1600, y: 100, width: 800, height: 600),
                                                                  displays: displays, mainIndex: 0) == 1)
        #expect(CompanionScreenCaptureUtility.harnessDisplayIndex(focusedWindowFrame: nil, displays: displays, mainIndex: 0) == 0)
        #expect(CompanionScreenCaptureUtility.harnessDisplayIndex(focusedWindowFrame: nil, displays: [], mainIndex: nil) == nil)
    }

    /// A policy-`refuse` app in front is left out of the picture, so the guard checks the window behind it.
    @Test func aRefusedAppInFrontIsCheckedBehindLikeAPasswordManager() {
        func window(_ pid: Int32, _ layer: Int) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer)]
        }
        let bundles: [pid_t: String] = [300: "com.example.bank", 400: "com.apple.TextEdit"]
        let choice = ScreenSecretGuard.appToCheck(frontmost: (pid: 300, bundleIdentifier: "com.example.bank"),
                                                  windowList: [window(300, 0), window(400, 0)], ownPID: 100,
                                                  bundleForPID: { bundles[$0] }, isRefused: { $0 == "com.example.bank" })
        #expect(choice?.pid == 400 && choice?.source == "behindRefusedApp")
    }
}
