//
//  DoublePathMenuItemTests.swift
//  L01 2026-10-18: Finder's Action pop-up published one open menu item under two
//  paths, and every press of it came back ambiguous.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct DoublePathMenuItemTests {

    private func node(_ role: String, _ title: String?, _ frame: CGRect, _ children: [AccessibilityElementNode] = []) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: title, value: nil, frameInAppKitCoordinates: frame, depth: 0, children: children)
    }

    private func resolve(_ title: String, _ root: AccessibilityElementNode) -> IntentResolution {
        ElementActionIntentResolver.resolve(ElementActionIntent(role: nil, title: title, action: .click), inTreeRootedAt: root)
    }

    @Test func oneOpenMenuItemReachedTwiceResolves() {
        let rect = CGRect(x: 1055, y: 570, width: 216, height: 22)
        let window = node("AXWindow", "Receipts", CGRect(x: 0, y: 0, width: 1400, height: 900), [
            node("AXMenuButton", "Action", CGRect(x: 900, y: 860, width: 40, height: 24), [node("AXMenu", nil, rect, [node("AXMenuItem", "Compress “Receipts”", rect)])]),
            node("AXMenu", nil, rect, [node("AXMenuItem", "Compress “Receipts”", rect)]),
        ])
        guard case .resolved(let found) = resolve("Compress “Receipts”", window) else {
            Issue.record("one on-screen menu item read as ambiguous"); return
        }
        #expect(found.role == "AXMenuItem")
    }

    @Test func distinctOrClosedOrNonMenuTwinsStayAmbiguous() {
        let rect = CGRect(x: 10, y: 10, width: 100, height: 22)
        // Two items at different places are two things.
        let apart = node("AXWindow", "W", .zero, [node("AXMenuItem", "Copy", rect), node("AXMenuItem", "Copy", rect.offsetBy(dx: 0, dy: 30))])
        // Closed menu items all read (0,0,0,0): sharing it proves nothing.
        let closed = node("AXWindow", "W", .zero, [node("AXMenuItem", "Copy", .zero), node("AXMenuItem", "Copy", .zero)])
        // Buttons are left to identity.
        let buttons = node("AXWindow", "W", .zero, [node("AXButton", "OK", rect), node("AXButton", "OK", rect)])
        for root in [apart, closed, buttons] {
            guard case .ambiguous = resolve(root.children[0].title?.raw ?? "", root) else {
                Issue.record("twins that are not one open menu item were merged"); continue
            }
        }
    }
}
