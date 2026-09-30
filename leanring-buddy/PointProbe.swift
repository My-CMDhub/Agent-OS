//
//  PointProbe.swift
//  leanring-buddy
//
//  `--point-probe`: find_on_screen + point_at run LOCALLY — no model, no audio —
//  through the same `RealtimeOpenAppTool.dispatch` and harness `answer(line:)`
//  the voice loop uses, on whatever app is in front, for up to eight of its
//  named VISIBLE elements spread across roles (text, rows, tabs, buttons...).
//  Per element it records, to ~/Library/Logs/Clicky/point-probe.log:
//
//    - whether find_on_screen offers it, by its own name, and at what rank;
//    - a hit test at its centre and at ±12 / ±24 pt: does a screenshot
//      position snap to THIS element — as point_at resolves it (walk first,
//      then AX) and by the AX hit test alone (`hits`, the summary's rates);
//    - the drawn frame (the element's live AXPosition/AXSize, converted)
//      against the element's frame — 0 pt, or the pointer aims elsewhere;
//    - the pointer window's frame as the WINDOW SERVER reports it
//      (`CGWindowListCopyWindowInfo`, like notch-drawn.log) against the frame it
//      must arrive at — a view's own idea of where it drew is no witness;
//    - request -> window first at the target, in ms, and its frame once the
//      flight is over (the curve overshoots, so it crosses before it rests);
//    - the app in front before and after — pointing must move nothing.
//
//  And once, press_element NEVER performed: its request line for one element,
//  and the kernel's pure verdict on that name and on "Delete" / "Empty Trash".
//
//  Safety: needs --harness-dry-run, runs only after 120 s with no keyboard or
//  mouse input and stops the moment either comes back. It opens, focuses and
//  moves no window but its own click-through overlay, and takes no screenshot.
//  A run that reads nothing still writes a line saying why.
//

import AppKit
import Foundation

@MainActor
enum PointProbe {
    static let logFileName = "point-probe.log"
    static let maximumPoints = 8

    /// Round-robin over role words, tree order within each: a mix, not a row of buttons.
    static func spreadAcrossRoles(_ pool: [RealtimeScreenVerbs.PoolElement], count: Int) -> [RealtimeScreenVerbs.PoolElement] {
        var byRole: [String: [RealtimeScreenVerbs.PoolElement]] = [:]
        var order: [String] = []
        for element in pool {
            let word = RealtimeScreenVerbs.roleWord(role: element.role, subrole: element.subrole)
            if byRole[word] == nil { order.append(word) }
            byRole[word, default: []].append(element)
        }
        var picked: [RealtimeScreenVerbs.PoolElement] = []
        var round = 0
        while picked.count < count, order.contains(where: { (byRole[$0]?.count ?? 0) > round }) {
            for word in order where picked.count < count {
                if let list = byRole[word], list.count > round { picked.append(list[round]) }
            }
            round += 1
        }
        return picked
    }

    /// "right/total" of the hit tests, inside the element's frame only or all.
    static func hitRate(_ results: [[String: Any]], inside: Bool?, key: String = "right") -> String {
        let hits = results.flatMap { ($0["hits"] as? [[String: Any]]) ?? [] }.filter { inside == nil || $0["inside"] as? Bool == inside }
        return "\(hits.filter { $0[key] as? Bool == true }.count)/\(hits.count)"
    }
    /// The window's flight is 0.4 s; this is 5x it.
    static let arrivalDeadlineSeconds: Double = 2
    /// Arrived means the window server's frame is the target's to within this.
    static let arrivalTolerancePoints: CGFloat = 0.5

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func appendLine(_ lineObject: [String: Any]) {
        MeasurementLogFile.appendJSONLine(lineObject, toFileNamed: logFileName)
    }

    private static func rect(_ frame: CGRect?) -> Any {
        frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull()
    }

    /// The largest distance between matching edges, in points.
    static func edgeDelta(_ first: CGRect, _ second: CGRect) -> CGFloat {
        max(abs(first.minX - second.minX), abs(first.minY - second.minY), abs(first.maxX - second.maxX), abs(first.maxY - second.maxY))
    }

    /// The window server's bounds for our pointer window, top-left origin.
    private static func windowServerBounds(windowNumber: Int) -> (bounds: CGRect?, onscreen: Bool) {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first
        let bounds = (info?[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        return (bounds, info?[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    private static func frontmostBundle() async -> String? {
        await Task.detached { AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier }.value
    }

    static func run(harness: HarnessServer) async {
        defer { MeasurementLogFile.waitForPendingWrites() }
        let probeID = UUID().uuidString
        let logPath = MeasurementLogFile.directoryURL.appendingPathComponent(logFileName).path
        let answer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        guard CommandLine.arguments.contains("--harness-dry-run") else {
            appendLine(["kind": "refused", "probeId": probeID, "reason": "needs --harness-dry-run"])
            print("🧪 point probe: refused, needs --harness-dry-run -> \(logPath)")
            return
        }
        let startUptime = uptime
        let idle = await Task.detached { NotchProbe.hidIdleSeconds() }.value
        guard let idle, idle >= NotchProbe.requiredIdleSeconds else {
            appendLine(["kind": "ownerActive", "probeId": probeID, "hidIdleSeconds": idle ?? NSNull()])
            print("🧪 point probe: owner active, not running -> \(logPath)")
            return
        }
        /// The probe posts no input, so idle shorter than the run means the owner is back.
        func ownerIsBack() async -> Bool {
            let now = uptime
            guard let idle = await Task.detached(operation: { NotchProbe.hidIdleSeconds() }).value else { return true }
            return idle < now - startUptime - 1
        }
        guard let bundle = await frontmostBundle(), !HarnessServer.isHarnessItself(bundleIdentifier: bundle) else {
            appendLine(["kind": "noFrontmostApp", "probeId": probeID])
            print("🧪 point probe: no app in front to read -> \(logPath)")
            return
        }

        // The pool the offer is cut from: every named VISIBLE element, and the
        // points spread across ROLES (text, rows, tabs, buttons...), not five neighbours.
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let snapshotLine = (try? RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "probe-pool", name: RealtimeVoiceVerbs.findOnScreenName, appName: bundle, words: "pool")).get()) ?? ""
        let snapshot = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(snapshotLine) }.value)
        let pool = RealtimeScreenVerbs.visiblePool(fromSnapshotResponse: snapshot, screens: screens).pool
        let chosen = Self.spreadAcrossRoles(pool, count: maximumPoints)
        appendLine(["kind": "start", "probeId": probeID, "app": bundle, "hidIdleSeconds": idle, "snapshotOk": snapshot["ok"] as? Bool ?? false,
                    "snapshotError": snapshot["error"] ?? NSNull(), "visibleNamed": pool.count, "chosen": chosen.count,
                    "roles": Dictionary(grouping: pool, by: { RealtimeScreenVerbs.roleWord(role: $0.role, subrole: $0.subrole) }).mapValues(\.count),
                    "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion])
        guard !chosen.isEmpty else {
            print("🧪 point probe: no named visible element in \(bundle) -> \(logPath)")
            return
        }

        var results: [[String: Any]] = []
        for (index, element) in chosen.enumerated() {
            let name = element.name
            guard !(await ownerIsBack()) else {
                appendLine(["kind": "ownerReturned", "probeId": probeID, "atPoint": index])
                break
            }
            let roleWord = RealtimeScreenVerbs.roleWord(role: element.role, subrole: element.subrole)
            let find = await RealtimeOpenAppTool.dispatch(
                RealtimeToolCall(callID: "probe-find-\(index)", name: RealtimeVoiceVerbs.findOnScreenName, appName: bundle, words: name),
                screens: screens, answer: answer)
            let offered = find.screenOffer?.candidates ?? []
            let offeredRank = offered.firstIndex { $0.name == name }

            // Hit test at the centre and jittered: does a position snap to THIS element?
            var hits: [[String: Any]] = []
            for (dx, dy) in [(0, 0), (12, 0), (-12, 0), (0, 12), (0, -12), (24, 0), (-24, 0), (0, 24), (0, -24)] as [(CGFloat, CGFloat)] {
                let point = CGPoint(x: element.frame.midX + dx, y: element.frame.midY + dy)
                // What point_at uses (walk first, then AX), and the AX hit test alone.
                let used = await RealtimeOpenAppTool.screenHit(at: point, app: bundle, answer: answer, screens: screens,
                                                               primaryDisplayHeight: primaryHeight, deadlineSeconds: 1).hit
                let axOnly = await RealtimeVoiceSession.value(within: 1) {
                    RealtimeScreenHitTest.hit(atAppKitPoint: point, primaryDisplayHeight: primaryHeight, screens: screens)
                } ?? .nothing
                func landed(_ hit: RealtimeScreenHit) -> (Any, Bool) {
                    switch hit {
                    case .element(let candidate, _): return (candidate.name, candidate.name == name)
                    case .refused(let error): return ("refused:" + error, false)
                    case .nothing: return (NSNull(), false)
                    }
                }
                let (usedName, right) = landed(used)
                let (axName, axRight) = landed(axOnly)
                hits.append(["dx": Double(dx), "dy": Double(dy), "inside": element.frame.contains(point), "landed": usedName, "right": right,
                             "axLanded": axName, "axRight": axRight])
            }

            guard let target = offered.first(where: { $0.name == name }) else {
                results.append(["kind": "point", "probeId": probeID, "index": index, "name": name, "role": roleWord, "offered": false,
                                "findError": find.result["error"] ?? NSNull(), "hits": hits])
                appendLine(results[results.count - 1])
                continue
            }
            let frontBefore = await frontmostBundle()
            let requested = uptime
            let screenTarget = RealtimeScreenTarget(candidate: target, point: CGPoint(x: target.frame.midX, y: target.frame.midY),
                                                    app: bundle, source: .thisTurn)
            let point = await RealtimeOpenAppTool.dispatch(
                RealtimeToolCall(callID: "probe-point-\(index)", name: RealtimeVoiceVerbs.pointAtName, appName: bundle, elementName: name),
                screenTarget: screenTarget, screens: screens, answer: answer)
            let answeredMs = Int(((uptime - requested) * 1000).rounded())
            let drawn = RealtimeScreenVerbs.frame(point.harnessResponse?["drawnRect"])

            // The flight is animated on main; wait for the window server to agree.
            var serverBounds: CGRect?
            var onscreen = false
            var arrivedMs: Int?
            let expected = drawn.map { ElementPointer.arrivedFrame(for: $0) }
            // AppKit -> window-server (top-left) is the same flip as AX -> AppKit.
            let expectedServer = expected.map { AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame($0, primaryDisplayHeightInPoints: primaryHeight) }
            let deadline = uptime + arrivalDeadlineSeconds
            while point.harnessConfirmed, let expectedServer, uptime < deadline {
                try? await Task.sleep(for: .milliseconds(10))
                guard let current = ElementPointer.current else { continue }
                (serverBounds, onscreen) = windowServerBounds(windowNumber: current.windowNumber)
                if let serverBounds, edgeDelta(serverBounds, expectedServer) <= arrivalTolerancePoints {
                    arrivedMs = Int(((uptime - requested) * 1000).rounded())
                    break
                }
            }
            // The flight's curve overshoots, so it CROSSES the target before it
            // rests there: read the window server again once the flight is over.
            var settledBounds: CGRect?
            if point.harnessConfirmed {
                let settleAt = requested + (Double(answeredMs) / 1000) + ElementPointer.flightSeconds + 0.15
                if uptime < settleAt { try? await Task.sleep(for: .seconds(settleAt - uptime)) }
                settledBounds = ElementPointer.current.flatMap { windowServerBounds(windowNumber: $0.windowNumber).bounds }
            }
            let frontAfter = await frontmostBundle()
            let line: [String: Any] = [
                "kind": "point", "probeId": probeID, "index": index, "name": name, "role": roleWord, "offered": true,
                "offeredRank": offeredRank ?? NSNull(), "where": target.position, "pointedAt": point.result["pointedAt"] ?? NSNull(),
                "ok": point.harnessConfirmed, "error": point.result["error"] ?? NSNull(),
                "elementFrame": rect(element.frame), "drawnFrame": rect(drawn),
                "drawnVsElementPt": drawn.map { Double(edgeDelta($0, element.frame)) } ?? NSNull(),
                "windowServerBounds": rect(serverBounds), "expectedWindowServerBounds": rect(expectedServer), "windowOnscreen": onscreen,
                "windowVsExpectedPt": serverBounds.flatMap { bounds in expectedServer.map { Double(edgeDelta(bounds, $0)) } } ?? NSNull(),
                "settledWindowServerBounds": rect(settledBounds),
                "settledVsExpectedPt": settledBounds.flatMap { bounds in expectedServer.map { Double(edgeDelta(bounds, $0)) } } ?? NSNull(),
                "harnessAnsweredMs": answeredMs, "timeToPointMs": arrivedMs ?? NSNull(), "hits": hits,
                "frontmostBefore": frontBefore ?? NSNull(), "frontmostAfter": frontAfter ?? NSNull(),
                "frontmostUnchanged": frontBefore != nil && frontBefore == frontAfter
            ]
            results.append(line)
            appendLine(line)
            // Let this pointer hold and fade before the next replaces it.
            try? await Task.sleep(for: .seconds(RealtimeScreenVerbs.pointHoldSeconds + ElementPointer.fadeSeconds + 0.2))
        }

        // press_element, never performed: the request line for the first offered
        // element, and the KERNEL's word on it and on a destructive-named twin.
        // Pure evaluation — a dry-run press of a destructive name would still
        // open a card on the owner's screen.
        if let benign = chosen.first {
            let candidate = RealtimeScreenCandidate(name: benign.name, role: benign.role, frame: benign.frame, position: "", subrole: benign.subrole)
            let pressLine = (try? RealtimeOpenAppTool.harnessRequestLine(
                for: RealtimeToolCall(callID: "probe-press", name: RealtimeVoiceVerbs.pressElementName, appName: bundle, elementName: benign.name),
                expectApp: bundle,
                screenTarget: RealtimeScreenTarget(candidate: candidate, point: CGPoint(x: benign.frame.midX, y: benign.frame.midY),
                                                   app: bundle, source: .thisTurn)).get())
            func kernel(_ name: String) -> String {
                let node = AccessibilityElementNode(role: benign.role, subrole: nil, title: name, value: nil, frameInAppKitCoordinates: benign.frame,
                                                    depth: 3, children: [], publishedActionNames: ["AXPress"])
                let decision = ActionSafetyKernel.evaluate(
                    intent: ElementActionIntent(role: benign.role, title: name, action: .press, nearPoint: nil, withinNamed: nil),
                    resolvedNode: node, matchCount: 1, visibleBounds: screens.first ?? .zero)
                return HarnessPolicy.describe(decision).decision
            }
            appendLine(["kind": "press", "probeId": probeID, "requestLine": pressLine ?? NSNull(),
                        "benignName": benign.name, "benignKernel": kernel(benign.name),
                        "destructiveName": "Delete", "destructiveKernel": kernel("Delete"),
                        "irreversibleName": "Empty Trash", "irreversibleKernel": kernel("Empty Trash")])
        }

        let pointed = results.filter { $0["ok"] as? Bool == true }
        appendLine(["kind": "summary", "probeId": probeID, "app": bundle, "points": results.count, "pointed": pointed.count,
                    "arrived": pointed.filter { $0["timeToPointMs"] is Int }.count,
                    "drawnVsElementMaxPt": pointed.compactMap { $0["drawnVsElementPt"] as? Double }.max() ?? NSNull(),
                    "offered": results.filter { $0["offered"] as? Bool == true }.count,
                    "hitRightInside": Self.hitRate(results, inside: true), "hitRightAll": Self.hitRate(results, inside: nil),
                    "axHitRightInside": Self.hitRate(results, inside: true, key: "axRight"),
                    "windowVsExpectedMaxPt": pointed.compactMap { $0["windowVsExpectedPt"] as? Double }.max() ?? NSNull(),
                    "settledVsExpectedMaxPt": pointed.compactMap { $0["settledVsExpectedPt"] as? Double }.max() ?? NSNull(),
                    "timeToPointMs": pointed.compactMap { $0["timeToPointMs"] as? Int },
                    "frontmostUnchanged": results.allSatisfy { $0["offered"] as? Bool == false || $0["frontmostUnchanged"] as? Bool == true }])
        print("🧪 point probe: \(pointed.count)/\(results.count) pointed -> \(logPath)")
    }
}
