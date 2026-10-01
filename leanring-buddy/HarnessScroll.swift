//
//  HarnessScroll.swift
//  leanring-buddy
//
//  The harness's `scroll` verb, pure half: which container, how far, and what
//  came into view. The AX and wheel half lives in `HarnessServer.scrollResponse`.
//
//  Owner's target level 2026-10-01: "its hands on my keyboard and trackpad,
//  with guardrails". Live 2026-09-30 12:55-12:56Z the model could see the
//  LinkedIn page and could not scroll it ("you have harness, so you should
//  scroll"). A scroll changes what is on screen and no data, so the kernel
//  allows it; the app policy, kill switch and `expectApp` still apply.
//
//  The aim is structural even when the verb is not: AX names the container and
//  its rectangle; the action is the container's own `AXScroll*ByPage` when it
//  works and a wheel event at that rectangle when it does not (CLAUDE.md: the
//  About pane advertised all four page verbs and every one failed -25204).
//

import AppKit
import ApplicationServices
import Foundation

enum ScrollDirection: String, CaseIterable {
    case up, down, left, right

    var pageDirection: ScrollPageDirection {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }

    var isHorizontal: Bool { self == .left || self == .right }
}

/// What a scroll did: moved, was already at the end (the scroll bar says so —
/// an answer, not an anomaly), or nothing could be seen to move.
enum ScrollOutcome: String { case moved, atEnd, notObserved }

enum HarnessScroll {
    static let barEpsilon = 0.0005

    /// Moved if the same elements moved (`change`) or the scroll bar's value
    /// did; else at the end if the bar sits at the end it was asked to go
    /// toward; else not observed. No bar (a web area): never "at the end".
    static func outcome(moved: Bool, barBefore: Double?, barAfter: Double?, direction: ScrollDirection) -> ScrollOutcome {
        if moved { return .moved }
        if let barBefore, let barAfter, abs(barAfter - barBefore) > barEpsilon { return .moved }
        guard let bar = barAfter ?? barBefore else { return .notObserved }
        let towardTheEnd = direction == .down || direction == .right
        return (towardTheEnd ? bar >= 1 - barEpsilon : bar <= barEpsilon) ? .atEnd : .notObserved
    }

    /// The container's scroll bar value, 0 (top / left) to 1 (bottom / right),
    /// or nil when it publishes none. One element, two reads.
    static func scrollBarValue(of container: AXUIElement?, horizontal: Bool) -> Double? {
        guard let container else { return nil }
        var bar: AnyObject?
        let attribute = horizontal ? kAXHorizontalScrollBarAttribute : kAXVerticalScrollBarAttribute
        guard AXUIElementCopyAttributeValue(container, attribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    /// Containers a scroll moves. A web page's root publishes AXWebArea and,
    /// in Chromium, often no AXScrollArea around it.
    static let containerRoles: Set<String> = ["AXScrollArea", "AXWebArea"]
    /// A request's pages, clamped by `decode` to (0, maximumPages].
    static let maximumPages = 10.0
    /// One wheel step, in pixels — `SyntheticScroller`'s measured 40.
    static let wheelStepPoints: CGFloat = 40
    /// ~80% of the container per page, as a trackpad page-flick leaves context.
    static let pageFraction: CGFloat = 0.8
    /// 60 steps x 20 ms is a 1.2 s gesture, the longest one a human would make.
    static let maximumWheelSteps = 60
    /// newlyVisible's cap: enough to say what came into view, short enough to read aloud.
    static let maximumNewlyVisible = 10

    /// Aimed at an element: its nearest container, itself included. Aimed at a
    /// point: the innermost container holding it. Not aimed: the largest by
    /// area, outermost first. nil: nothing scrollable, and the verb uses the
    /// window's own rectangle.
    static func container(in root: AccessibilityElementNode, targetChain: [AccessibilityElementNode]?,
                          point: CGPoint?) -> AccessibilityElementNode? {
        if let targetChain {
            return targetChain.last { containerRoles.contains($0.role) && hasArea($0) }
        }
        var all: [AccessibilityElementNode] = []
        func visit(_ node: AccessibilityElementNode) {
            if containerRoles.contains(node.role), hasArea(node) { all.append(node) }
            node.children.forEach(visit)
        }
        visit(root)
        func area(_ node: AccessibilityElementNode) -> CGFloat {
            node.frameInAppKitCoordinates.width * node.frameInAppKitCoordinates.height
        }
        if let point {
            // Pre-order, so on a tie the later one is the deeper one.
            return all.filter { $0.frameInAppKitCoordinates.contains(point) }.reversed().min { area($0) < area($1) }
        }
        return all.max { area($0) < area($1) }
    }

    private static func hasArea(_ node: AccessibilityElementNode) -> Bool {
        node.frameInAppKitCoordinates.width > 0 && node.frameInAppKitCoordinates.height > 0
    }

    /// The names the owner can see inside `bounds`, in tree order, from
    /// `HarnessServer.namedElements` — the same filter `find_on_screen` offers
    /// by (`RealtimeScreenVerbs.visiblePool`): never a secure field, a text
    /// input's typed value, a document-length or implausible name.
    static func visibleNames(fromNamedElements elements: [[String: Any]], within bounds: CGRect) -> [(name: String, frame: CGRect)] {
        elements.compactMap { element in
            guard let name = element["name"] as? String, let role = element["role"] as? String,
                  let frame = RealtimeScreenVerbs.frame(element["frame"]), frame.intersects(bounds) else { return nil }
            let subrole = element["subrole"] as? String
            let typedValue = RealtimeScreenVerbs.textInputRoles.contains(role)
                && (element["nameSource"] as? String == "value" || element["subroleReadFailed"] as? Bool == true)
            guard subrole != ActionSafetyKernel.secureFieldSubrole, !typedValue,
                  name.count <= RealtimeScreenVerbs.documentLengthCharacters,
                  UntrustedText(name).isPlausibleControlLabel else { return nil }
            return (name, frame)
        }
    }

    /// Moved: an element in view before and after changed PLACE — a clock
    /// ticking or a typing indicator appearing changes names, not positions
    /// (review 2026-10-01) — or nothing in view is shared at all (two pages on).
    /// newlyVisible: names in view after that were not before, once each, capped.
    static func change(before: [(name: String, frame: CGRect)], after: [(name: String, frame: CGRect)]) -> (moved: Bool, newlyVisible: [String]) {
        let beforeFrames = Dictionary(before.map { ($0.name, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let shared = after.filter { beforeFrames[$0.name] != nil }
        let moved = shared.contains { beforeFrames[$0.name] != $0.frame } || (shared.isEmpty && !before.isEmpty && !after.isEmpty)
        var newlyVisible: [String] = []
        for item in after where beforeFrames[item.name] == nil && !newlyVisible.contains(item.name) {
            newlyVisible.append(item.name)
        }
        return (moved, Array(newlyVisible.prefix(maximumNewlyVisible)))
    }

    /// Wheel steps for `pages` of a container `extent` points long on the scroll axis.
    static func wheelSteps(pages: Double, extent: CGFloat) -> Int {
        let points = CGFloat(pages) * pageFraction * extent
        return min(maximumWheelSteps, max(1, Int((points / wheelStepPoints).rounded(.up))))
    }
}
