//
//  OwnerFocusTests.swift
//  leanring-buddyTests
//
//  What "this" means in one push-to-talk turn (owner 2026-11-01): a selection
//  the pointer is on, else a circle drawn while holding, else where the pointer
//  rested, else what it hovered at the press. Pure halves: the loop and rest
//  detectors, the precedence, the privacy gate on a selection, the lines the
//  voice and the agent are told, the notch, and the selection read's deadline.
//  The monitors, the AX reads and the close-up are the live probe's (--focus-probe).
//

import AppKit
import Foundation
import Testing
@testable import Clicky

struct OwnerFocusTests {

    // MARK: Paths

    /// A circle drawn from angle 0 through `sweep` radians, `count` points.
    static func circle(centre: CGPoint, radius: CGFloat, sweep: CGFloat = 2 * .pi, count: Int = 48) -> [CGPoint] {
        (0...count).map { index in
            let angle = sweep * CGFloat(index) / CGFloat(count)
            return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
    }

    static func samples(_ points: [CGPoint], from start: TimeInterval = 0, every step: TimeInterval = 0.01) -> [OwnerFocusSample] {
        points.enumerated().map { OwnerFocusSample(point: $0.element, uptime: start + Double($0.offset) * step) }
    }

    // MARK: Loop

    @Test func aDrawnCircleIsALoopBoundedByItsBox() throws {
        let region = try #require(OwnerFocusGeometry.loop(Self.circle(centre: CGPoint(x: 300, y: 880), radius: 20)))
        #expect(abs(region.midX - 300) < 1 && abs(region.midY - 880) < 1)
        #expect(abs(region.width - 40) < 1 && abs(region.height - 40) < 1)
    }

    @Test func aHandDrawnCircleNeedNotCloseExactly() {
        // 330° of a circle: the ends are 13 pt apart on a 50 pt loop, inside the closure allowance (17.5).
        #expect(OwnerFocusGeometry.loop(Self.circle(centre: .zero, radius: 25, sweep: 2 * .pi * 330 / 360)) != nil)
        // A lead-in and a tail around a circle are still that circle.
        let path = [CGPoint(x: -200, y: 0), CGPoint(x: -100, y: 0)] + Self.circle(centre: .zero, radius: 30, sweep: 2.2 * .pi)
            + [CGPoint(x: 150, y: 150)]
        let region = OwnerFocusGeometry.loop(path)
        #expect(region.map { abs($0.midX) < 3 && abs($0.width - 60) < 3 } == true)
    }

    @Test func linesArcsAndTwitchesAreNotLoops() {
        let line = (0...50).map { CGPoint(x: CGFloat($0) * 6, y: 100) }
        #expect(OwnerFocusGeometry.loop(line) == nil)
        // There and back along the same line encloses nothing.
        #expect(OwnerFocusGeometry.loop(line + line.reversed()) == nil)
        // Half a circle never closes.
        #expect(OwnerFocusGeometry.loop(Self.circle(centre: .zero, radius: 40, sweep: .pi)) == nil)
        // A 4 pt wiggle is a hand at rest, not a circle.
        #expect(OwnerFocusGeometry.loop(Self.circle(centre: .zero, radius: 4)) == nil)
        // A zig-zag scribble never comes back to where it was.
        let zigzag = (0...40).map { CGPoint(x: CGFloat($0 % 2) * 120, y: CGFloat($0) * 1.5) }
        #expect(OwnerFocusGeometry.loop(zigzag) == nil)
    }

    @Test func shoelaceAreaOfASquare() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        #expect(OwnerFocusGeometry.shoelaceArea(square) == 100)
        #expect(OwnerFocusGeometry.shoelaceArea(square.reversed()) == 100)
    }

    @Test func aLongPathIsStridedNotDropped() {
        let long = Self.circle(centre: .zero, radius: 200, count: 2_000)
        #expect(OwnerFocusGeometry.thinned(long).count == OwnerFocusGeometry.maximumLoopPoints)
        #expect(OwnerFocusGeometry.loop(long) != nil)
    }

    // MARK: Dwell

    @Test func restsAreFoundInOrderAndAMovePastIsNot() {
        let path = [
            OwnerFocusSample(point: CGPoint(x: 0, y: 0), uptime: 0),        // the press, left after 0.1 s
            OwnerFocusSample(point: CGPoint(x: 200, y: 0), uptime: 0.1),    // rests 0.5 s (a 3 pt jitter stays in)
            OwnerFocusSample(point: CGPoint(x: 203, y: 1), uptime: 0.3),
            OwnerFocusSample(point: CGPoint(x: 400, y: 50), uptime: 0.6),   // rests until the release at 1.2
        ]
        let rests = OwnerFocusGeometry.dwells(path, endUptime: 1.2)
        #expect(rests.count == 2)
        #expect(rests.first.map { abs($0.center.x - 201.5) < 0.01 && abs($0.seconds - 0.5) < 1e-9 } == true)
        #expect(rests.last.map { $0.center == CGPoint(x: 400, y: 50) && abs($0.seconds - 0.6) < 1e-9 } == true)
    }

    @Test func moreRestsThanThreeKeepTheLongestThreeInOrder() {
        // Rests of 0.4, 0.9, 0.35, 0.8, 0.5 s at x = 0, 100, 200, 300, 400.
        let lengths = [0.4, 0.9, 0.35, 0.8, 0.5]
        var path: [OwnerFocusSample] = []
        var clock = 0.0
        for (index, length) in lengths.enumerated() {
            path.append(OwnerFocusSample(point: CGPoint(x: CGFloat(index) * 100, y: 0), uptime: clock))
            clock += length
        }
        let rests = OwnerFocusGeometry.dwells(path, endUptime: clock)
        #expect(rests.map(\.center.x) == [100, 300, 400])
    }

    @Test func aRestIsNamedOnceItHasLastedNotBefore() {
        let path = [OwnerFocusSample(point: .zero, uptime: 0), OwnerFocusSample(point: CGPoint(x: 100, y: 0), uptime: 1),
                    OwnerFocusSample(point: CGPoint(x: 104, y: 2), uptime: 1.1)]
        #expect(OwnerFocusGeometry.restAnchor(path, now: 1.2) == nil)
        // The jitter at 1.1 s belongs to the rest that began at 1.0 s.
        #expect(OwnerFocusGeometry.restAnchor(path, now: 1.35) == 1)
    }

    // MARK: Precedence

    static let textSelection = OwnerFocusSelection(content: .text("hello"), appName: "TextEdit", bundleIdentifier: "com.apple.TextEdit",
                                                    frame: CGRect(x: 0, y: 0, width: 500, height: 400))

    @Test func aSelectionThePointerIsOnWinsOverACircle() {
        let circling = Self.samples([CGPoint(x: 100, y: 100)] + Self.circle(centre: CGPoint(x: 100, y: 200), radius: 30))
        let decided = OwnerFocusGeometry.decide(selection: Self.textSelection, keyDownMouse: CGPoint(x: 100, y: 100),
                                                samples: circling, endUptime: 2)
        #expect(decided.rung == .selection)
    }

    @Test func aSelectionElsewhereDoesNotHijackTheTurn() {
        let circling = Self.samples([CGPoint(x: 900, y: 800)] + Self.circle(centre: CGPoint(x: 900, y: 860), radius: 30))
        let decided = OwnerFocusGeometry.decide(selection: Self.textSelection, keyDownMouse: CGPoint(x: 900, y: 800),
                                                samples: circling, endUptime: 2)
        #expect(decided.rung == .circle)
    }

    @Test func aStillPointerIsHoverEvenThoughItRested() {
        let still = [OwnerFocusSample(point: CGPoint(x: 10, y: 10), uptime: 0)]
        #expect(OwnerFocusGeometry.decide(selection: nil, keyDownMouse: CGPoint(x: 10, y: 10), samples: still, endUptime: 3) == .hover)
        // A 5 pt drift is still.
        let drift = still + [OwnerFocusSample(point: CGPoint(x: 15, y: 10), uptime: 1)]
        #expect(OwnerFocusGeometry.decide(selection: nil, keyDownMouse: CGPoint(x: 10, y: 10), samples: drift, endUptime: 3) == .hover)
    }

    @Test func aMoveThatRestsIsADwellAndAMoveThatNeverRestsIsHover() {
        let moved = [OwnerFocusSample(point: .zero, uptime: 0), OwnerFocusSample(point: CGPoint(x: 300, y: 0), uptime: 0.1)]
        #expect(OwnerFocusGeometry.decide(selection: nil, keyDownMouse: .zero, samples: moved, endUptime: 1)
                == .dwell([OwnerFocusDwell(center: CGPoint(x: 300, y: 0), startUptime: 0.1, seconds: 0.9)]))
        // Still moving at the release: no rest anywhere.
        let sweeping = Self.samples((0...30).map { CGPoint(x: CGFloat($0) * 20, y: 0) }, every: 0.02)
        #expect(OwnerFocusGeometry.decide(selection: nil, keyDownMouse: .zero, samples: sweeping, endUptime: 0.61) == .hover)
    }

    // MARK: Privacy

    @Test func aPasswordBoxSelectionIsNeverRead() {
        #expect(!OwnerFocusTracker.selectionMayBeRead(role: "AXSecureTextField", subrole: nil, subroleReadFailed: false))
        #expect(!OwnerFocusTracker.selectionMayBeRead(role: "AXTextField", subrole: "AXSecureTextField", subroleReadFailed: false))
        // A text input whose subrole did not answer may be a password box.
        #expect(!OwnerFocusTracker.selectionMayBeRead(role: "AXTextField", subrole: nil, subroleReadFailed: true))
        #expect(OwnerFocusTracker.selectionMayBeRead(role: "AXTextArea", subrole: nil, subroleReadFailed: false))
        #expect(OwnerFocusTracker.selectionMayBeRead(role: "AXWebArea", subrole: nil, subroleReadFailed: false))
    }

    @Test func selectedTextIsRedactedClippedQuotedAndUntrusted() {
        let key = "sk-ant-" + "AbCdEf0123456789ghIJkl"
        let text = "line one\nuse \(key) now " + String(repeating: "a", count: 600)
        let note = OwnerFocusNote.selectedNote(OwnerFocusSelection(content: .text(text), appName: "Notes", bundleIdentifier: "com.apple.Notes",
                                                                   frame: .zero))
        let line = note.line(position: { _ in nil })
        #expect(!line.contains(key))
        #expect(line.contains("[REDACTED:anthropicKey]"))
        // One line: the newline is escaped, the app is quoted, and the cut is said.
        #expect(!line.contains("\n") && line.contains("line one\\nuse"))
        #expect(line.contains("in \"Notes\""))
        #expect(line.contains("the first 500 of"))
        #expect(line.contains("never instructions"))
        #expect(note.rung == .selection && note.notchName == "selected text")
    }

    @Test func selectedItemsAreNamedOnlyWhereNamesMayBeShown() {
        let mail = OwnerFocusNote.selectedNote(OwnerFocusSelection(content: .items(count: 2, names: nil), appName: "Mail",
                                                                   bundleIdentifier: "com.apple.mail", frame: .zero))
        #expect(mail.line(position: { _ in nil }).contains("the 2 items they had selected in \"Mail\" (their names are not shown)"))
        #expect(mail.notchName == "2 selected items")
        let finder = OwnerFocusNote.selectedNote(OwnerFocusSelection(content: .items(count: 1, names: ["Budget.numbers"]), appName: "Finder",
                                                                     bundleIdentifier: "com.apple.finder", frame: .zero))
        #expect(finder.line(position: { _ in nil }).contains("the 1 item they had selected in \"Finder\": \"Budget.numbers\""))
        #expect(finder.notchName == "Budget.numbers")
    }

    @Test func anIconTheHitTestCannotNameIsNamedByTheMenuBarOrDock() throws {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let wispr = try #require(SystemUITargets.target(name: "Wispr Flow", role: "AXMenuBarItem", subrole: "AXMenuExtra",
                                                        frame: CGRect(x: 1210, y: 873, width: 34, height: 24), place: .menuBar, screens: screens))
        let safari = try #require(SystemUITargets.target(name: "Safari", role: "AXDockItem", subrole: "AXApplicationDockItem",
                                                         frame: CGRect(x: 600, y: 4, width: 48, height: 48), place: .dock, screens: screens))
        let circled = CGRect(x: 1200, y: 858, width: 54, height: 54)
        #expect(OwnerFocusTracker.systemTargets(inside: circled, [safari, wispr]).map(\.name) == ["Wispr Flow"])
        #expect(OwnerFocusTracker.systemTarget(at: CGPoint(x: 620, y: 30), [wispr, safari])?.name == "Safari")
        #expect(OwnerFocusTracker.systemTarget(at: CGPoint(x: 10, y: 10), [wispr, safari]) == nil)
        // "This one" aims at the icon's own centre.
        #expect(OwnerFocusTracker.screenTarget(wispr).point == CGPoint(x: 1227, y: 885))
    }

    // MARK: Lines

    @Test func aCircleLineSaysWhereWhatAndThatPositionsStayInTheScreenshot() {
        let note = OwnerFocusNote(kind: .circle(region: CGRect(x: 1180, y: 876, width: 40, height: 22), inside: ["menu-bar icon \"Wi‑Fi\""]),
                                  crop: Data([1]), notchName: "Wi‑Fi")
        let line = note.line(position: { "x \(Int($0.x)), y \(Int($0.y))" }, closeUpWasSentAtPress: true)
        #expect(line.hasPrefix("system context, not the owner's words: "))
        #expect(line.contains("the region they circled with the pointer while speaking, centred at x 1200, y 887 in the screenshot"))
        #expect(line.contains("it holds menu-bar icon \"Wi‑Fi\""))
        #expect(line.contains("positions are in the full screenshot, never the close-up"))
        #expect(line.contains("crosshair close-up sent earlier shows only the pointer at the press"))
    }

    @Test func restsAreListedInTheOrderTheyHappened() {
        let note = OwnerFocusNote(kind: .dwell([.init(described: "Dock icon \"Safari\"", point: CGPoint(x: 1, y: 1)),
                                                .init(described: nil, point: CGPoint(x: 2, y: 2))]), crop: nil, notchName: "Safari +1")
        let line = note.line(position: { "(\(Int($0.x)))" })
        let first = line.range(of: "first Dock icon \"Safari\" at (1)"), second = line.range(of: "then a spot nothing names at (2)")
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
    }

    @Test func theAgentIsToldPositionsInItsOwnScreenshotThenTheCloseUpBeforeTheScreenshot() throws {
        var observation = AgentObservation()
        observation.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        observation.imagePixels = CGSize(width: 1920, height: 1200)
        let note = OwnerFocusNote(kind: .circle(region: CGRect(x: 700, y: 860, width: 40, height: 40), inside: []), crop: Data([7]),
                                  notchName: "circled area")
        let blocks = AgentLoop.focusBlocks(note, observation: observation)
        #expect(blocks.map { $0["type"] as? String } == ["text", "image"])
        let text = try #require(blocks.first?["text"] as? String)
        // Centre (720, 880) AppKit -> x 960, y (900 - 880) / 900 * 1200 = 26.7 -> 27 pixels.
        #expect(text.contains("centred at x 960, y 27 pixels in the screenshot"))
        #expect(text.hasPrefix("When the owner asked, "))
        // Off its screenshot, a position is left out rather than invented.
        #expect(OwnerFocusNote.agentPosition(CGPoint(x: 2000, y: 10), frame: observation.frame, pixels: observation.imagePixels) == nil)
    }

    @Test func aLongNameIsCutForTheNotch() {
        #expect(OwnerFocusNote.notchName("Wi‑Fi") == "Wi‑Fi")
        let long = OwnerFocusNote.notchName(String(repeating: "x", count: 60))
        #expect(long.count == OwnerFocusNote.maximumNotchNameLength && long.hasSuffix("\u{2026}"))
    }

    // MARK: Notch

    @MainActor @Test func theFocusLineShowsOverThinkingAndGivesWayToTheReply() {
        let focus = JarvisNotchState.focus(name: "Wi‑Fi")
        #expect(JarvisNotchState.thinking.next(on: .focusShown(name: "Wi‑Fi")) == focus)
        #expect(focus.title == "Focus: Wi‑Fi" && focus.shape == .expanded)
        #expect(focus.next(on: .firstAudioWithoutTool) == .speaking)
        #expect(focus.next(on: .toolCall(title: "Opening Wi‑Fi…")) == .intent(title: "Opening Wi‑Fi…"))
        // Its hold returns to thinking: the turn is still being answered.
        #expect(focus.next(on: .holdElapsed) == .thinking)
        #expect(focus.next(on: .turnEnded) == .idle)
        // Never over a press, a reply or an intent.
        for state: JarvisNotchState in [.listening, .speaking, .intent(title: "x"), .idle] {
            #expect(state.next(on: .focusShown(name: "x")) == nil)
        }
        #expect(CompanionPanelView.stateLine(focus, pendingApprovals: 0).text == "Focus: Wi‑Fi")
    }

    // MARK: The agent's first step

    @MainActor @Test func aTaskStartedFromAFocusedTurnIsToldItInItsFirstRequestOnly() async throws {
        var bodies: [[String: Any]] = []
        var replies: [[String: Any]] = [
            ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": "scroll", "input": ["direction": "down"]]]],
            ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t2", "name": "done", "input": ["summary": "Done.", "evidence": [1]]]]]
        ]
        var now: TimeInterval = 1000
        let loop = AgentLoop(dependencies: AgentLoop.Dependencies(
            model: { body, _ in
                bodies.append(body)
                now += 1
                return AgentModelReply(json: replies.count > 1 ? replies.removeFirst() : replies[0], model: "fake", milliseconds: 7)
            },
            observe: { AgentObservation(jpeg: Data([9]), frame: CGRect(x: 0, y: 0, width: 1440, height: 900), imagePixels: CGSize(width: 1440, height: 900),
                                        look: "attached", lines: [], bundleIdentifier: nil) },
            execute: { _, _, _, _ in RealtimeToolDispatch(result: ["ok": true, "message": "done"], harnessMilliseconds: 5,
                                                          waitedForConfirmation: false, harnessResponse: ["ok": true]) },
            readPage: { ["ok": true, "text": "page"] },
            trace: { _ in },
            uptime: { now }
        ))
        loop.ownerFocus = OwnerFocusNote(kind: .dwell([.init(described: "Dock icon \"Safari\"", point: CGPoint(x: 720, y: 30))]),
                                         crop: Data([7]), notchName: "Safari")
        _ = await loop.run(goal: "open this", heard: "open this")
        func content(_ body: [String: Any]?) -> [[String: Any]] {
            ((body?["messages"] as? [[String: Any]])?.filter { $0["role"] as? String == "user" }.first?["content"] as? [[String: Any]]) ?? []
        }
        let first = content(bodies.first)
        let focusIndex = try #require(first.firstIndex { ($0["text"] as? String)?.contains("Dock icon \"Safari\" at x 720, y 870 pixels") == true })
        let images = first.indices.filter { first[$0]["type"] as? String == "image" }
        // The close-up straight after its line; the step's screenshot last.
        #expect(images.count == 2 && images.first == focusIndex + 1)
        #expect((images.last.map { first[$0]["source"] as? [String: Any] }??["data"] as? String) == Data([9]).base64EncodedString())
        // The second request adds a step; the focus is not said again.
        let messages = try #require(bodies.last?["messages"] as? [[String: Any]])
        let laterUser = messages.filter { $0["role"] as? String == "user" }.dropFirst()
        #expect(!laterUser.contains { String(describing: $0).contains("Dock icon") })
    }

    // MARK: Deadline

    @MainActor @Test func aSlowSelectionReadFallsBackToNoSelection() async {
        // 0.25 s deadline against a 4 s read; the bound leaves room for a loaded test run (1.1 s seen).
        let tracker = OwnerFocusTracker(mouse: CGPoint(x: 10, y: 10), readSelection: {
            Thread.sleep(forTimeInterval: 4)
            return Self.textSelection
        })
        let started = ProcessInfo.processInfo.systemUptime
        let resolved = await tracker.resolve(harnessAnswer: { _ in "{}" })
        let seconds = ProcessInfo.processInfo.systemUptime - started
        #expect(resolved.note == nil && resolved.measured.rung == .hover)
        #expect(seconds < 2.5)
        #expect(resolved.measured.selectionReadMilliseconds < 2_500)
    }

    @MainActor @Test func aSelectionInTimeIsTheFocus() async {
        let tracker = OwnerFocusTracker(mouse: CGPoint(x: 10, y: 10), readSelection: { Self.textSelection })
        let resolved = await tracker.resolve(harnessAnswer: { _ in "{}" })
        #expect(resolved.measured.rung == .selection)
        #expect(resolved.note?.kind == .selectedText(app: "TextEdit", text: "hello", totalCharacters: 5))
    }
}
