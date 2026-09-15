//
//  AccessibilityThreadProbe.swift
//  leanring-buddy
//
//  Measurement only, started by `--ax-thread-probe`; changes no product
//  behaviour. Harness requests run inside `DispatchQueue.main.sync` (owner's
//  ruling 2026-09-11), so a walk holds the thread the overlay and the
//  push-to-talk tap run on. Before that ruling is revisited this answers:
//  does the SAME walker (`AccessibilityTreeWalker.snapshotFocusedWindow`, the
//  one `snapshot` calls) return the same tree on a background serial queue,
//  at what cost, and does main stay free while it runs.
//
//  Per app: activate through `ApplicationLauncher.launchAndWait` (the `launch`
//  verb's wait), warm up until three walks in a row agree on node count (the
//  first probe after activation reads fewer), then 6 main + 6 background walks
//  in ABBA order so neither side pays the warm-up. A pinger thread measures
//  main's delay during every walk.
//
//  Two things the first run (2026-09-15) taught, both about the world moving,
//  not the thread: System Settings lost focus to Chrome during walk 0 and 11
//  walks read Chrome — so an off-target walk is re-activated before and
//  excluded after. And Finder's "Recent" differed walk to walk on the SAME
//  thread — so identity is judged by diffing consecutive walks, same-thread
//  pairs against cross-thread pairs, not by one fingerprint across 12.
//

import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import os

enum AccessibilityThreadProbe {
    static let logFileName = "ax-thread-probe.log"
    static let walksPerThread = 6

    enum WalkThread: String { case main, background }

    /// M,B,B,M repeated: each side goes first as often as the other.
    static func interleavedOrder(walksPerThread: Int) -> [WalkThread] {
        (0..<(walksPerThread * 2)).map { [WalkThread.main, .background, .background, .main][$0 % 4] }
    }

    /// Order-independent, and sensitive to role, name and exact frame.
    static func fingerprintLines(of nodes: [AccessibilityElementNode]) -> [String] {
        nodes.map { node in
            let frame = node.frameInAppKitCoordinates
            return "\(node.role)|\(node.displayName?.raw ?? "")|\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height)"
        }.sorted()
    }

    static func fingerprint(ofSortedLines lines: [String]) -> String {
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    private struct Target {
        let name: String
        let bundleIdentifier: String
        let onlyIfRunning: Bool
    }

    private static let targets = [
        Target(name: "Finder", bundleIdentifier: "com.apple.finder", onlyIfRunning: false),
        Target(name: "System Settings", bundleIdentifier: "com.apple.systempreferences", onlyIfRunning: false),
        Target(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", onlyIfRunning: true)
    ]

    private static let walkQueue = DispatchQueue(label: "Clicky.AccessibilityThreadProbe.walks", qos: .userInitiated)

    private final class WalkBox: @unchecked Sendable {
        var snapshot: AccessibilityWindowSnapshot?
        var error: Error?
        var ranOnMainThread = false
        var wallMilliseconds = 0.0
    }

    private static func walk(into box: WalkBox) {
        box.ranOnMainThread = Thread.isMainThread
        let startedAt = ProcessInfo.processInfo.systemUptime
        do { box.snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow() } catch { box.error = error }
        box.wallMilliseconds = MainThreadStallRecorder.milliseconds(ProcessInfo.processInfo.systemUptime - startedAt)
    }

    /// Posts to main every 16 ms from its own thread and records how late each
    /// block ran — `MainThreadStallRecorder`'s measurement, scoped to one walk.
    private final class MainPinger: @unchecked Sendable {
        private let shouldStop = OSAllocatedUnfairLock(initialState: false)
        private let finished = DispatchSemaphore(value: 0)
        private(set) var window = MainThreadStallRecorder.SummaryWindow(startedAtUptime: ProcessInfo.processInfo.systemUptime)

        func start() {
            Thread { [self] in
                while !shouldStop.withLock({ $0 }) {
                    let sentAt = ProcessInfo.processInfo.systemUptime
                    let servedAt = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
                    let served = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        servedAt.withLock { $0 = ProcessInfo.processInfo.systemUptime }
                        served.signal()
                    }
                    served.wait()
                    window.record(delaySeconds: servedAt.withLock { $0 } - sentAt)
                    Thread.sleep(forTimeInterval: MainThreadStallRecorder.pingIntervalSeconds)
                }
                finished.signal()
            }.start()
        }

        /// Awaited, never blocked on: the in-flight ping needs main to run.
        @MainActor
        func stop() async {
            shouldStop.withLock { $0 = true }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { [self] in
                    finished.wait()
                    continuation.resume()
                }
            }
        }
    }

    private struct Row {
        let thread: WalkThread
        let wallMilliseconds: Double
        let fingerprint: String?
        let nodes: Int?
        let maxMainDelayMilliseconds: Double
        let mainLateOver16: Int
        let ranOnMainThread: Bool
        let onTarget: Bool
    }

    private static func log(_ object: [String: Any]) {
        MeasurementLogFile.appendJSONLine(object, toFileNamed: logFileName)
    }

    @MainActor
    static func run() async {
        let runID = String(UUID().uuidString.prefix(8))
        log(["kind": "started", "run": runID, "pid": Int(ProcessInfo.processInfo.processIdentifier),
             "axTrusted": AXIsProcessTrusted(),
             "order": interleavedOrder(walksPerThread: walksPerThread).map { $0.rawValue }])
        guard AXIsProcessTrusted() else {
            log(["kind": "aborted", "run": runID, "reason": "AXIsProcessTrusted() is false"])
            MeasurementLogFile.waitForPendingWrites()
            return
        }
        for target in targets {
            await probe(target, runID: runID)
        }
        MeasurementLogFile.waitForPendingWrites()
    }

    @MainActor
    private static func activate(_ url: URL, base: [String: Any], reason: String) -> Bool {
        let launch = ApplicationLauncher.launchAndWait(url)
        log(base.merging(["kind": "activated", "reason": reason, "status": launch.status.rawValue,
                          "frontmostMs": orNull(launch.frontmostMilliseconds),
                          "windowMs": orNull(launch.windowMilliseconds),
                          "launchError": orNull(launch.launchError)]) { $1 })
        return launch.status == .ready
    }

    @MainActor
    private static func probe(_ target: Target, runID: String) async {
        var base: [String: Any] = ["run": runID, "app": target.name]
        func skip(_ reason: String) { log(base.merging(["kind": "skipped", "reason": reason]) { $1 }) }

        if target.onlyIfRunning,
           !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == target.bundleIdentifier }) {
            return skip("not running")
        }
        guard case .resolved(let url, _) = ApplicationLauncher.resolve(target.bundleIdentifier) else {
            return skip("ApplicationLauncher.resolve did not resolve \(target.bundleIdentifier)")
        }
        guard activate(url, base: base, reason: "start") else { return skip("not ready after activation") }

        // Until three walks in a row agree on node count, 500 ms apart, at most 10.
        var warmUpCounts: [Int] = []
        for _ in 0..<10 {
            let box = WalkBox()
            walk(into: box)
            warmUpCounts.append(box.snapshot?.bundleIdentifier == target.bundleIdentifier ? (box.snapshot?.nodeCount ?? -1) : -1)
            if warmUpCounts.count >= 3, let last = warmUpCounts.last, last > 0,
               warmUpCounts.suffix(3).allSatisfy({ $0 == last }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        base["warmUpNodeCounts"] = warmUpCounts

        var rows: [Row] = []
        var previous: (lines: Set<String>, thread: WalkThread)?
        var sameThreadPairDiffs: [Int] = []
        var crossThreadPairDiffs: [Int] = []
        var reactivations = 0

        for (index, thread) in interleavedOrder(walksPerThread: walksPerThread).enumerated() {
            let frontmostBundle = AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier
            if frontmostBundle != target.bundleIdentifier {
                reactivations += 1
                _ = activate(url, base: base, reason: "frontmost was \(frontmostBundle ?? "nil") before walk \(index)")
            }

            let pinger = MainPinger()
            pinger.start()
            try? await Task.sleep(nanoseconds: 50_000_000)   // pings in flight before the walk starts

            let box = WalkBox()
            switch thread {
            case .main:
                walk(into: box)
            case .background:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    walkQueue.async {
                        walk(into: box)
                        continuation.resume()
                    }
                }
            }
            await pinger.stop()

            let maxDelay = MainThreadStallRecorder.milliseconds(pinger.window.maximumDelaySeconds)
            let onTarget = box.snapshot?.bundleIdentifier == target.bundleIdentifier
            var line: [String: Any] = base.merging([
                "kind": "walk", "index": index, "thread": thread.rawValue, "onTarget": onTarget,
                "ranOnMainThread": box.ranOnMainThread, "wallMs": box.wallMilliseconds,
                "mainPings": pinger.window.pings, "mainMaxDelayMs": maxDelay,
                "mainLateOver16Ms": pinger.window.lateOverSixteenMilliseconds
            ]) { $1 }
            var walkFingerprint: String?
            if let snapshot = box.snapshot, let root = snapshot.rootNode {
                let nodes = root.flattenedDescendants()
                let lines = fingerprintLines(of: nodes)
                walkFingerprint = fingerprint(ofSortedLines: lines)
                line["bundle"] = snapshot.bundleIdentifier
                line["rootTitle"] = orNull(root.displayName?.forDisplay)
                line["walkMs"] = MainThreadStallRecorder.milliseconds(snapshot.walkDurationInSeconds)
                line["nodes"] = snapshot.nodeCount
                line["actionable"] = nodes.filter { $0.isActionable }.count
                line["pressable"] = nodes.filter { $0.publishedActionNames.contains(kAXPressAction) }.count
                line["fingerprint"] = walkFingerprint ?? ""
                line["stopReasons"] = snapshot.walkStopReasons.map { $0.rawValue }.sorted()
                line["timedOutNodes"] = snapshot.timedOutNodePaths.count
                line["nodesWithoutReadableFrame"] = snapshot.nodesWithoutReadableFrame
                line["subtreesLostToFailedReads"] = snapshot.subtreesLostToFailedReads
                line["focusChangedDuringWalk"] = snapshot.focusChangedDuringWalk
                line["frontmostSource"] = orNull(snapshot.frontmostSource?.rawValue)
                if onTarget {
                    let lineSet = Set(lines)
                    if let previous {
                        let differing = lineSet.symmetricDifference(previous.lines)
                        line["previousThread"] = previous.thread.rawValue
                        line["linesDifferingFromPrevious"] = differing.count
                        line["differingSample"] = Array(differing.sorted().prefix(6)).map { String($0.prefix(160)) }
                        if previous.thread == thread {
                            sameThreadPairDiffs.append(differing.count)
                        } else {
                            crossThreadPairDiffs.append(differing.count)
                        }
                    }
                    previous = (lineSet, thread)
                }
            } else {
                line["error"] = box.error.map { String(describing: $0) } ?? "snapshot had no root node"
            }
            log(line)
            rows.append(Row(thread: thread, wallMilliseconds: box.wallMilliseconds, fingerprint: walkFingerprint,
                            nodes: box.snapshot?.nodeCount, maxMainDelayMilliseconds: maxDelay,
                            mainLateOver16: pinger.window.lateOverSixteenMilliseconds,
                            ranOnMainThread: box.ranOnMainThread, onTarget: onTarget))
        }

        func side(_ thread: WalkThread) -> [String: Any] {
            let all = rows.filter { $0.thread == thread }
            let mine = all.filter { $0.onTarget }
            return [
                "walks": mine.count,
                "offTargetWalks": all.count - mine.count,
                "medianWallMs": orNull(median(mine.map { $0.wallMilliseconds })),
                "distinctFingerprints": Set(mine.compactMap { $0.fingerprint }).count,
                "nodeCounts": mine.compactMap { $0.nodes },
                "maxMainDelayMs": orNull(mine.map { $0.maxMainDelayMilliseconds }.max()),
                "mainLateOver16Ms": mine.map { $0.mainLateOver16 }.reduce(0, +),
                // Impossible-if-broken: every main walk true, every background walk false.
                "ranOnMainThread": all.filter { $0.ranOnMainThread }.count
            ]
        }
        let onTargetRows = rows.filter { $0.onTarget }
        let fingerprints = onTargetRows.compactMap { $0.fingerprint }
        let modal = Dictionary(grouping: fingerprints, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        log(base.merging([
            "kind": "summary", "main": side(.main), "background": side(.background),
            "reactivations": reactivations,
            "identicalAcrossAll": !fingerprints.isEmpty && fingerprints.count == rows.count && Set(fingerprints).count == 1,
            "mainMatchingModal": onTargetRows.filter { $0.thread == .main && $0.fingerprint == modal }.count,
            "backgroundMatchingModal": onTargetRows.filter { $0.thread == .background && $0.fingerprint == modal }.count,
            "sameThreadPairDiffs": sameThreadPairDiffs,
            "crossThreadPairDiffs": crossThreadPairDiffs
        ]) { $1 })
    }
}
