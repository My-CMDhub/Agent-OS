//
//  WatchProbe.swift
//  leanring-buddy
//
//  Safety: reads only (snapshot and windows), opens, focuses and moves nothing,
//  stops the moment keyboard or mouse input comes back. Counts only: no element
//  name or window title reaches the log.
//

import AppKit
import Foundation

/// `--watch-probe`: the session WATCH loop's cost, measured before the loop exists.
/// For the app in front: 60 s of one forModel snapshot every 0.5 s, then 60 s of
/// one targeted read (the window title) every 0.5 s. Records each read's ms, the
/// app's CPU % (`ps -o %cpu`) before and during, and the main-thread stall
/// recorder's worst stall. Needs --harness-dry-run and 120 s of owner idle.
@MainActor
enum WatchProbe {
    static let logFileName = "watch-probe.log"

    static let phaseSeconds: Double = 60
    static let intervalSeconds: Double = 0.5
    static let cpuSampleSeconds: Double = 5

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func appendLine(_ lineObject: [String: Any]) {
        MeasurementLogFile.appendJSONLine(lineObject, toFileNamed: logFileName)
    }

    /// The app's CPU %, as `ps` reports it; nil if unreadable.
    nonisolated static func cpuPercent(pid: pid_t) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "%cpu=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Double(output.trimmingCharacters(in: .whitespacesAndNewlines))
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
            print("🧪 watch probe: refused, needs --harness-dry-run -> \(logPath)")
            return
        }
        let startUptime = uptime
        let idle = await Task.detached { NotchProbe.hidIdleSeconds() }.value
        guard let idle, idle >= NotchProbe.requiredIdleSeconds else {
            appendLine(["kind": "ownerActive", "probeId": probeID, "hidIdleSeconds": idle ?? NSNull()])
            print("🧪 watch probe: owner active, not running -> \(logPath)")
            return
        }
        /// The probe posts no input, so idle shorter than the run means the owner is back.
        func ownerIsBack() async -> Bool {
            let now = uptime
            guard let idle = await Task.detached(operation: { NotchProbe.hidIdleSeconds() }).value else { return true }
            return idle < now - startUptime - 1
        }
        guard let bundle = await frontmostBundle(), !HarnessServer.isHarnessItself(bundleIdentifier: bundle),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else {
            appendLine(["kind": "noFrontmostApp", "probeId": probeID])
            print("🧪 watch probe: no app in front to read -> \(logPath)")
            return
        }
        let cpuBefore = await Task.detached { cpuPercent(pid: pid) }.value
        appendLine(["kind": "start", "probeId": probeID, "app": bundle, "hidIdleSeconds": idle, "cpuBefore": cpuBefore ?? NSNull(),
                    "phaseSeconds": phaseSeconds, "intervalSeconds": intervalSeconds])

        let phases: [(name: String, request: [String: Any])] = [
            ("snapshotForModel", ["verb": "snapshot", "forModel": true, "expectApp": bundle]),
            ("windowTitle", ["verb": "windows", "app": bundle, "expectApp": bundle])
        ]
        for phase in phases {
            guard let data = try? JSONSerialization.data(withJSONObject: phase.request),
                  let line = String(data: data, encoding: .utf8) else { continue }
            var readMs: [Double] = []
            var failures: [String: Int] = [:]
            var cpuDuring: [Double] = []
            var ownerReturned = false
            let pinger = AccessibilityThreadProbe.MainPinger()
            pinger.start()
            let clock = ContinuousClock()
            let phaseStart = clock.now
            var lastCPUSample = uptime
            for index in 0..<Int(phaseSeconds / intervalSeconds) {
                try? await clock.sleep(until: phaseStart + .milliseconds(Int(intervalSeconds * 1000) * index), tolerance: nil)
                let started = uptime
                let response = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(line) }.value)
                readMs.append((uptime - started) * 1000)
                if response["ok"] as? Bool == false { failures[(response["error"] as? String) ?? "unknown", default: 0] += 1 }
                if uptime - lastCPUSample >= cpuSampleSeconds {
                    lastCPUSample = uptime
                    if let cpu = await Task.detached(operation: { cpuPercent(pid: pid) }).value { cpuDuring.append(cpu) }
                    if await ownerIsBack() { ownerReturned = true; break }
                }
            }
            await pinger.stop()
            let frontAfter = await frontmostBundle()
            func rounded(_ value: Double?) -> Any { value.map { ($0 * 10).rounded() / 10 } ?? NSNull() }
            appendLine(["kind": "summary", "probeId": probeID, "app": bundle, "phase": phase.name, "n": readMs.count,
                        "failures": failures, "p50Ms": rounded(percentile(readMs, 0.5)), "p95Ms": rounded(percentile(readMs, 0.95)),
                        "maxMs": rounded(readMs.max()), "cpuBefore": cpuBefore ?? NSNull(), "cpuDuringMedian": rounded(percentile(cpuDuring, 0.5)),
                        "cpuDuringMax": rounded(cpuDuring.max()), "cpuSamples": cpuDuring.count,
                        "worstMainStallMs": MainThreadStallRecorder.milliseconds(pinger.window.maximumDelaySeconds),
                        "mainPings": pinger.window.pings, "mainLateOver50Ms": pinger.window.stallsOverFiftyMilliseconds,
                        "frontmostUnchanged": frontAfter == bundle, "ownerReturned": ownerReturned])
            if ownerReturned { break }
        }
        print("🧪 watch probe: finished -> \(logPath)")
    }

    nonisolated static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)
        return sorted[min(rank, sorted.count - 1)]
    }
}
