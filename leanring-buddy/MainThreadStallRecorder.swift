//
//  MainThreadStallRecorder.swift
//  leanring-buddy
//
//  Measurement only, started by `--main-thread-stall-log`. Harness requests ran
//  inside `DispatchQueue.main.sync` until 2026-09-15 (now their own queue), and
//  the main thread runs the push-to-talk CGEvent tap and the overlay's animation
//  timers. A request's latency is what a socket client feels; a main-thread
//  stall is what the hotkey and the cursor feel. This records the second.
//
//  How: a background thread posts a block to the main queue, waits until it
//  runs, and records the gap. Only one ping is in flight at a time, so a 500 ms
//  stall is one 500 ms line, not thirty overlapping ones.
//

import Foundation
import os

nonisolated enum MainThreadStallRecorder {
    static let logFileName = "main-thread-stalls.log"
    /// One 60 fps frame. A ping answered later than this has cost the overlay a frame.
    static let pingIntervalSeconds: TimeInterval = 0.016
    static let lateThresholdSeconds: TimeInterval = 0.016
    /// Only these reach the log as individual lines; the rest is counted in the summary.
    static let stallThresholdSeconds: TimeInterval = 0.050
    static let summaryIntervalSeconds: TimeInterval = 10

    /// The harness verb in flight on the request queue, or nil — a stall that
    /// names one happened during it, not necessarily because of it.
    /// Written by `HarnessServer.respond(toLine:)`; read by the pinging
    /// thread while main is not answering — the only moment the answer is
    /// interesting, and the one moment main cannot tell us itself.
    static let currentHarnessVerb = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The one call HarnessServer makes, so it needs no `import os` of its own
    /// (MemberImportVisibility hides `withLock` from files that do not import it).
    static func noteHarnessVerb(_ verb: String?) {
        currentHarnessVerb.withLock { $0 = verb }
    }

    private static let hasStarted = OSAllocatedUnfairLock(initialState: false)

    /// Counts for one summary window. Pure, so the bucketing is unit-tested.
    struct SummaryWindow: Equatable {
        let startedAtUptime: TimeInterval
        private(set) var pings = 0
        private(set) var lateOverSixteenMilliseconds = 0
        private(set) var stallsOverFiftyMilliseconds = 0
        private(set) var maximumDelaySeconds: TimeInterval = 0
        private(set) var blockedSecondsInStalls: TimeInterval = 0

        init(startedAtUptime: TimeInterval) {
            self.startedAtUptime = startedAtUptime
        }

        mutating func record(delaySeconds: TimeInterval) {
            pings += 1
            if delaySeconds > MainThreadStallRecorder.lateThresholdSeconds {
                lateOverSixteenMilliseconds += 1
            }
            if delaySeconds > MainThreadStallRecorder.stallThresholdSeconds {
                stallsOverFiftyMilliseconds += 1
                blockedSecondsInStalls += delaySeconds
            }
            maximumDelaySeconds = max(maximumDelaySeconds, delaySeconds)
        }

        func jsonObject(endedAtUptime: TimeInterval) -> [String: Any] {
            [
                "kind": "summary",
                "windowStartedAtUptime": MeasurementLogFile.roundedUptime(startedAtUptime),
                "windowEndedAtUptime": MeasurementLogFile.roundedUptime(endedAtUptime),
                "pings": pings,
                "lateOver16Ms": lateOverSixteenMilliseconds,
                "lateOver50Ms": stallsOverFiftyMilliseconds,
                "maxDelayMs": MainThreadStallRecorder.milliseconds(maximumDelaySeconds),
                "blockedMsInStalls": MainThreadStallRecorder.milliseconds(blockedSecondsInStalls)
            ]
        }
    }

    /// nil for a delay at or under the stall threshold.
    static func stallJSONObject(startedAtUptime: TimeInterval, delaySeconds: TimeInterval, harnessVerbs: [String]) -> [String: Any]? {
        guard delaySeconds > stallThresholdSeconds else { return nil }
        return [
            "kind": "stall",
            "startedAtUptime": MeasurementLogFile.roundedUptime(startedAtUptime),
            "durationMs": milliseconds(delaySeconds),
            // Normally one verb: `main.sync` requests queue FIFO with our ping,
            // so the ping runs between two of them.
            "harnessVerb": harnessVerbs.isEmpty ? NSNull() : harnessVerbs.joined(separator: ",")
        ]
    }

    static func milliseconds(_ seconds: TimeInterval) -> Double {
        (seconds * 10_000).rounded() / 10
    }

    static func start() {
        let isFirstStart = hasStarted.withLock { alreadyStarted -> Bool in
            defer { alreadyStarted = true }
            return !alreadyStarted
        }
        guard isFirstStart else { return }

        let pingThread = Thread { pingMainThreadForever() }
        pingThread.name = "Clicky.MainThreadStallRecorder"
        pingThread.qualityOfService = .userInteractive
        pingThread.start()
    }

    private static func pingMainThreadForever() {
        // Proof the recorder was running at all: a probe that finds no summary
        // lines in its window knows its "0 stalls" is not a measurement.
        MeasurementLogFile.appendJSONLine([
            "kind": "started",
            "atUptime": MeasurementLogFile.roundedUptime(ProcessInfo.processInfo.systemUptime),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "pingIntervalMs": milliseconds(pingIntervalSeconds),
            "stallThresholdMs": milliseconds(stallThresholdSeconds)
        ], toFileNamed: logFileName)

        var window = SummaryWindow(startedAtUptime: ProcessInfo.processInfo.systemUptime)
        while true {
            let sentAtUptime = ProcessInfo.processInfo.systemUptime
            let servedAtUptime = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
            let served = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                servedAtUptime.withLock { $0 = ProcessInfo.processInfo.systemUptime }
                served.signal()
            }

            var harnessVerbsSeenWhileWaiting: [String] = []
            while served.wait(timeout: .now() + stallThresholdSeconds) == .timedOut {
                if let verb = currentHarnessVerb.withLock({ $0 }), !harnessVerbsSeenWhileWaiting.contains(verb) {
                    harnessVerbsSeenWhileWaiting.append(verb)
                }
            }

            let delaySeconds = servedAtUptime.withLock { $0 } - sentAtUptime
            window.record(delaySeconds: delaySeconds)
            if let stall = stallJSONObject(startedAtUptime: sentAtUptime, delaySeconds: delaySeconds, harnessVerbs: harnessVerbsSeenWhileWaiting) {
                MeasurementLogFile.appendJSONLine(stall, toFileNamed: logFileName)
            }

            let nowUptime = ProcessInfo.processInfo.systemUptime
            if nowUptime - window.startedAtUptime >= summaryIntervalSeconds {
                MeasurementLogFile.appendJSONLine(window.jsonObject(endedAtUptime: nowUptime), toFileNamed: logFileName)
                window = SummaryWindow(startedAtUptime: nowUptime)
            }

            // A background thread with no run loop to serve, so sleeping is right here.
            Thread.sleep(forTimeInterval: pingIntervalSeconds)
        }
    }
}
