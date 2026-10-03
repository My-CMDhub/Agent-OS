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

    /// Moved if the same elements moved the way asked (`change`) or the scroll
    /// bar's value went that way; else at the end if the bar sits at the end it
    /// was asked to go toward; else not observed. No bar (a web area): never "at the end".
    static func outcome(moved: Bool, barBefore: Double?, barAfter: Double?, direction: ScrollDirection) -> ScrollOutcome {
        if moved { return .moved }
        let towardTheEnd = direction == .down || direction == .right
        if let barBefore, let barAfter, (towardTheEnd ? barAfter - barBefore : barBefore - barAfter) > barEpsilon { return .moved }
        guard let bar = barAfter ?? barBefore else { return .notObserved }
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
            guard let name = element["name"] as? String, element["role"] is String,
                  let frame = RealtimeScreenVerbs.frame(element["frame"]), frame.intersects(bounds) else { return nil }
            guard !AccessibilityElementNode.withholdsName(entry: element),
                  name.count <= RealtimeScreenVerbs.documentLengthCharacters,
                  UntrustedText(name).isPlausibleControlLabel else { return nil }
            return (name, frame)
        }
    }

    /// Moved: elements in view before and after shifted the way the content goes
    /// for `direction` (AppKit, y up: down moves content UP), along that axis
    /// only — and they outnumber the elements that changed any other
    /// way. A clock ticking or an indicator appearing changes names, not
    /// positions (review 2026-10-01). Scenario A3 (run 2026-10-02T23-51-05Z)
    /// answered "confirmed" while the page's offset stayed 0, when "moved" was
    /// any frame change or NOTHING shared at all: a re-layout, a different
    /// window, two same-named elements read against each other's frame.
    /// Same-named elements are left out: nothing says which is which.
    /// ponytail: a scroll past everything the walk knew (it reads one screenful
    /// beyond the view) shares nothing and reads notObserved — honest, not proven.
    /// newlyVisible: names in view after that were not before, once each, capped.
    /// `before`: every element known before the scroll, in view or not (a heading
    /// that comes in from below was below); `inViewBefore`: the names that were in
    /// view (nil: all of `before`), for newlyVisible.
    static func change(before: [(name: String, frame: CGRect)], after: [(name: String, frame: CGRect)],
                       direction: ScrollDirection, inViewBefore: Set<String>? = nil) -> (moved: Bool, newlyVisible: [String]) {
        func unique(_ items: [(name: String, frame: CGRect)]) -> [String: CGRect] {
            Dictionary(grouping: items, by: \.name).compactMapValues { $0.count == 1 ? $0[0].frame : nil }
        }
        let beforeFrames = unique(before)
        var along = 0, otherwise = 0
        for (name, frame) in unique(after) {
            guard let old = beforeFrames[name], old != frame else { continue }
            // The midpoint along the axis, the other axis fixed. Size ALONG the axis may
            // change: Chromium clips an element leaving the view to the view's edge
            // (probe 2026-10-03, mimic article: a heading at AX y 243, h 38 read y 112,
            // h 1 once scrolled past), and that clipped row is still "in view".
            let shift: CGFloat
            switch direction {
            case .down, .up:
                let fixed = abs(frame.minX - old.minX) < 1 && abs(frame.width - old.width) < 1
                shift = fixed ? (direction == .down ? 1 : -1) * (frame.midY - old.midY) : 0
            case .right, .left:
                let fixed = abs(frame.minY - old.minY) < 1 && abs(frame.height - old.height) < 1
                shift = fixed ? (direction == .left ? 1 : -1) * (frame.midX - old.midX) : 0
            }
            if shift >= 1 { along += 1 } else { otherwise += 1 }
        }
        let beforeNames = inViewBefore ?? Set(before.map(\.name))
        var newlyVisible: [String] = []
        for item in after where !beforeNames.contains(item.name) && !newlyVisible.contains(item.name) {
            newlyVisible.append(item.name)
        }
        return (along > 0 && along > otherwise, Array(newlyVisible.prefix(maximumNewlyVisible)))
    }

    /// Wheel steps for `pages` of a container `extent` points long on the scroll axis.
    static func wheelSteps(pages: Double, extent: CGFloat) -> Int {
        let points = CGFloat(pages) * pageFraction * extent
        return min(maximumWheelSteps, max(1, Int((points / wheelStepPoints).rounded(.up))))
    }
}
