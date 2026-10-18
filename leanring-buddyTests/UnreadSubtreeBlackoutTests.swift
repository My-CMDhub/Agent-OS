//
//  UnreadSubtreeBlackoutTests.swift
//  leanring-buddyTests
//
//  Reminders' look was refused on every step: two sidebar section headers fail their
//  children read (-25200). A lost subtree with a real frame is blacked out of the
//  photograph instead. Pure; SYNTHETIC nodes - the live half is a look of Reminders.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct UnreadSubtreeBlackoutTests {

    func node(_ role: String, frame: CGRect = CGRect(x: 0, y: 0, width: 250, height: 18),
              value: String? = nil, frameReadFailed: Bool = false, childrenReadFailed: Bool = false) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: nil, value: value, frameInAppKitCoordinates: frame,
                                 depth: 0, children: [], frameReadFailed: frameReadFailed, childrenReadFailed: childrenReadFailed)
    }

    @Test func aLostSubtreeWithARealFrameIsBlackedOutNotRefused() throws {
        // Live 2026-10-19: Reminders' section header, AXUnknown valued "iCloud", 250x18.
        let headerFrame = CGRect(x: 185, y: 420, width: 250, height: 18)
        let header = node("AXUnknown", frame: headerFrame, value: "iCloud", childrenReadFailed: true)
        let window = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let covered = CaptureInspection(windows: [.init(title: UntrustedText("Reminders"), role: "AXWindow",
                                                        nodes: [window, header], subtreesLostToFailedReads: 1)])
        #expect(covered.incompleteReason == nil)
        #expect(ActionSafetyKernel.evaluateCapture(covered) == .allow)
        let shutter = ScreenSecretGuard.secretsBeforeShutter(in: covered, primaryDisplayHeight: 900)
        #expect(shutter.refusal == nil)
        #expect(shutter.redactions == [.init(kind: "unreadSubtree", appKitRect: headerFrame, source: "frame")])

        func refuses(_ nodes: [AccessibilityElementNode], lost: Int = 1) -> Bool {
            CaptureInspection(windows: [.init(role: "AXWindow", nodes: nodes, subtreesLostToFailedReads: lost)])
                .incompleteReason?.contains("failed children reads") == true
        }
        // Each shape that could still show what nobody read refuses as before.
        #expect(refuses([window, header, node("AXWebArea")]))
        #expect(refuses([window, node("AXUnknown", frame: .zero, childrenReadFailed: true)]))
        #expect(refuses([window, node("AXUnknown", frameReadFailed: true, childrenReadFailed: true)]))
        #expect(refuses([window, node("AXTextField", childrenReadFailed: true)]))
        #expect(refuses([window, node("AXUnknown")]))
        // Two lost, one coverable: the other still refuses, and is counted.
        let partly = CaptureInspection(windows: [.init(role: "AXWindow", nodes: [window, header], subtreesLostToFailedReads: 2)])
        #expect(try #require(partly.incompleteReason).contains("lost 1 subtree"))
    }
}
