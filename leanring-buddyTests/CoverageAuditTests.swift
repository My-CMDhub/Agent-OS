//
//  CoverageAuditTests.swift
//  leanring-buddyTests
//
//  The coverage audit's pure half: which class an OCR text region falls in
//  against the AX frames around it. Whether those frames and words are real
//  is the live audit's question.
//

import CoreGraphics
import Testing
@testable import Clicky

struct CoverageAuditTests {
    let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let region = CGRect(x: 100, y: 100, width: 60, height: 16)

    @Test func namedActionableElementIsAddressable() {
        let nodes = [CoverageClassifier.Node(frame: CGRect(x: 90, y: 95, width: 100, height: 30), name: "Save As…", actionable: true)]
        #expect(CoverageClassifier.classify(text: "Save As", region: region, nodes: nodes, window: window) == .axActionable)
    }

    @Test func anonymousRowWithLabelChildIsAddressable() {
        // Finder's sidebar: AXRow is actionable and anonymous, its AXStaticText child carries the label.
        let nodes = [CoverageClassifier.Node(frame: CGRect(x: 80, y: 90, width: 200, height: 40), name: nil, actionable: true),
                     CoverageClassifier.Node(frame: CGRect(x: 95, y: 98, width: 80, height: 20), name: "Downloads", actionable: false)]
        #expect(CoverageClassifier.classify(text: "Downloads", region: region, nodes: nodes, window: window) == .axActionable)
    }

    @Test func wrongNameOrNoActionIsOnlyPresent() {
        let other = [CoverageClassifier.Node(frame: CGRect(x: 90, y: 95, width: 100, height: 30), name: "Cancel", actionable: true)]
        #expect(CoverageClassifier.classify(text: "Export", region: region, nodes: other, window: window) == .axPresent)
        let staticText = [CoverageClassifier.Node(frame: CGRect(x: 90, y: 95, width: 100, height: 30), name: "Export", actionable: false)]
        #expect(CoverageClassifier.classify(text: "Export", region: region, nodes: staticText, window: window) == .axPresent)
    }

    @Test func onlyContainersAroundIsOcrOnly() {
        // The window and a web area covering most of it locate nothing.
        let nodes = [CoverageClassifier.Node(frame: window, name: "Doc", actionable: true),
                     CoverageClassifier.Node(frame: CGRect(x: 0, y: 0, width: 900, height: 700), name: nil, actionable: false),
                     CoverageClassifier.Node(frame: CGRect(x: 400, y: 400, width: 50, height: 20), name: "Export", actionable: true)]
        #expect(CoverageClassifier.classify(text: "Export", region: region, nodes: nodes, window: window) == .ocrOnly)
    }

    @Test func zeroAreaFrameLocatesNothing() {
        // A scrolled-out row's (0,0,0,0) frame, CLAUDE.md's third failure category.
        let nodes = [CoverageClassifier.Node(frame: .zero, name: "Export", actionable: true)]
        #expect(CoverageClassifier.classify(text: "Export", region: CGRect(x: 0, y: 0, width: 2, height: 2), nodes: nodes, window: window) == .ocrOnly)
    }

    @Test func glyphIsNeither() {
        #expect(CoverageClassifier.classify(text: "›", region: region, nodes: [], window: window) == .neither)
        #expect(CoverageClassifier.classify(text: "• →", region: region, nodes: [], window: window) == .neither)
        // A one-digit key is a label (Calculator), named by its AX element.
        let key = [CoverageClassifier.Node(frame: CGRect(x: 90, y: 95, width: 100, height: 30), name: "7", actionable: true)]
        #expect(CoverageClassifier.classify(text: "7", region: region, nodes: key, window: window) == .axActionable)
    }

    @Test func longLinesNeedHalfTheirWords() {
        #expect(CoverageClassifier.names("Show View Options", ["show", "view", "options", "now"]))
        #expect(!CoverageClassifier.names("Show", ["show", "view", "options", "now"]))
        #expect(!CoverageClassifier.names("Show", ["show", "view"]))
    }

    @Test func iconsAreActionableElementsWithoutText() {
        let nodes = [CoverageClassifier.Node(frame: CGRect(x: 90, y: 95, width: 100, height: 30), name: "Back", actionable: true),
                     CoverageClassifier.Node(frame: CGRect(x: 500, y: 500, width: 20, height: 20), name: "Share", actionable: true),
                     CoverageClassifier.Node(frame: CGRect(x: 600, y: 500, width: 20, height: 20), name: "Label", actionable: false)]
        #expect(CoverageClassifier.iconCount(nodes: nodes, regions: [region]) == 1)
    }

    @Test func truncatedRowGetsTheFloorBanner() {
        let text = CoverageAudit.markdown(meta: ["timestamp": "t", "outcome": "ran"],
                                          rows: [["name": "Mail", "status": "ok", "stopReasons": ["ran out of time"], "menuStopReasons": [String]()]])
        #expect(text.contains("A FLOOR, NOT A MEASUREMENT for: Mail"))
        let clean = CoverageAudit.markdown(meta: ["timestamp": "t", "outcome": "ran"],
                                           rows: [["name": "Finder", "status": "ok", "stopReasons": [String](), "menuStopReasons": [String]()]])
        #expect(!clean.contains("FLOOR"))
    }
}

struct GeneralitySuiteAnswerTests {
    @Test @MainActor func numbersMustStandAlone() {
        #expect(GeneralitySuite.answer("The Helvetica family has 6 styles.", has: ["6"], truth: "6")["passed"] as? Bool == true)
        #expect(GeneralitySuite.answer("It is 16 degrees in 2026.", has: ["6"], truth: "6")["passed"] as? Bool == false)
        #expect(GeneralitySuite.answer("macOS 15.5 (24F74)", has: ["15.5"], truth: "15.5")["passed"] as? Bool == true)
        #expect(GeneralitySuite.answer("version 15.56", has: ["15.5"], truth: "15.5")["passed"] as? Bool == false)
        #expect(GeneralitySuite.answer("Created by Chris Lattner.", has: ["Lattner"], truth: "Chris Lattner")["passed"] as? Bool == true)
    }

    /// A creation passes only on MORE matching items than before. Run 2026-10-12T03-40-26Z:
    /// G05 created nothing (typing refused) and passed on an earlier run's leftover reminder.
    @Test @MainActor func aCreationPassesOnlyWhenTheCountGrew() {
        #expect(GeneralitySuite.createdVerdict(before: 2, after: 3)["passed"] as? Bool == true)
        #expect(GeneralitySuite.createdVerdict(before: 2, after: 2)["passed"] as? Bool == false)
        let unreadable = GeneralitySuite.createdVerdict(before: nil, after: 3)
        #expect(unreadable["passed"] as? Bool == false)
        #expect(unreadable["countBeforeUnreadable"] as? Bool == true)
        #expect(GeneralitySuite.createdVerdict(before: 0, after: 1)["passed"] as? Bool == true)
        #expect(GeneralitySuite.createdVerdict(before: 1, after: nil)["passed"] as? Bool == false)
    }
}

/// The suite's cleanup diff. G15, run 2026-10-10T23-34-53Z: the task saved and
/// closed TextEdit's existing Untitled window, then File > New opened a new one
/// in the same default frame; matched against the old windows' BOUNDS it read
/// as old, was neither closed nor counted, and two files it saved went unreported.
struct GeneralitySuiteCleanupTests {
    let frame = CGRect(x: 200, y: 100, width: 600, height: 500)

    @Test func aNewWindowInAnOldWindowsFrameIsStillNew() {
        let opened = GeneralitySuite.openedWindows(before: [(number: 11, bounds: frame)],
                                                   after: [WindowServerSurface(number: 12, bounds: frame, title: "Untitled")])
        #expect(opened.map(\.number) == [12])
    }

    @Test func aWindowThatExistedBeforeIsNeverOpenedEvenMoved() {
        let opened = GeneralitySuite.openedWindows(before: [(number: 11, bounds: frame)],
                                                   after: [WindowServerSurface(number: 11, bounds: frame.offsetBy(dx: 40, dy: 40), title: nil),
                                                           WindowServerSurface(number: 13, bounds: frame.offsetBy(dx: 40, dy: 40), title: nil)])
        #expect(opened.map(\.number) == [13])
    }

    @Test func newFilesAreTheNamesNotInTheSnapshot() {
        let before: Set = ["Desktop/notes.txt", "Documents/a"]
        #expect(GeneralitySuite.newEntries(before: before, after: before.union(["Desktop/UntitledJARVIS test 3.rtf", "Desktop/Untitled.rtf"]))
                == ["Desktop/Untitled.rtf", "Desktop/UntitledJARVIS test 3.rtf"])
        #expect(GeneralitySuite.newEntries(before: before, after: ["Desktop/notes.txt"]).isEmpty)
    }
}
