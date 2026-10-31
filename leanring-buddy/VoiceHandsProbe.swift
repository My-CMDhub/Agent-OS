//
//  VoiceHandsProbe.swift
//  leanring-buddy
//
//  `--voice-hands-probe --voice-hands-at=<x>,<y>` (2026-10-31, universal screen
//  hands slice B): one voice press_element by a SCREENSHOT POSITION (fractions of
//  the main display, as the voice model sends them), through the voice turn's own
//  path (`RealtimeVoiceConnection.runToolCall`: heard check, screen-target
//  resolution, the pointer route, tickets), then the same press again to close
//  what the first opened. Witness: the window server's list (a window appears, then
//  goes), never the verb's own verification. Cards are denied, never allowed.
//  Summary (0600) to ~/Library/Logs/Clicky/voice-hands-probe/<ts>/results.json, then quits.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
enum VoiceHandsProbe {
    static func run(harness: HarnessServer, confirmations: HarnessConfirmations) async {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = MeasurementLogFile.directoryURL.appendingPathComponent("voice-hands-probe/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var summary: [String: Any] = ["kind": "voiceHandsProbe", "timestamp": stamp]
        defer {
            let line = MeasurementLogFile.jsonLine(summary) ?? #"{"kind":"voiceHandsProbe","outcome":"summaryNotSerialisable"}"#
            _ = MeasurementLogFile.appendOwnerOnly(Data((line + "\n").utf8), to: folder.appendingPathComponent("results.json"))
            MeasurementLogFile.waitForPendingWrites()
            print("🖐 voice hands probe: \(summary["outcome"] ?? "?") -> \(folder.path)")
        }
        let parts = CommandLine.arguments.first { $0.hasPrefix("--voice-hands-at=") }?
            .dropFirst("--voice-hands-at=".count).split(separator: ",").compactMap { Double($0) } ?? []
        guard parts.count == 2, let display = NSScreen.screens.first?.frame else {
            summary["outcome"] = "refused"; summary["reason"] = "needs --voice-hands-at=<x>,<y> (fractions of the main display)"; return
        }
        if let refusal = ScenarioRunner.refusalToStart() { summary["outcome"] = "refused"; summary["reason"] = refusal; return }
        let answer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        // Deny any card this probe raises; never allow.
        let started = Date()
        let denier = Task { @MainActor in
            while !Task.isCancelled {
                for ticket in confirmations.tickets where ticket.createdAt >= started
                    && HarnessConfirmations.status(of: ticket, now: Date()) == .pending {
                    confirmations.answer(ticket.id, allow: false, scope: .once)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { denier.cancel() }

        func windows() -> Set<String> {
            let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            return Set(list.filter { ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 && ($0[kCGWindowLayer as String] as? Int ?? 0) < 1000 }
                .map { "\($0[kCGWindowNumber as String] ?? 0) \($0[kCGWindowOwnerName as String] ?? "?")" })
        }
        func press(_ id: String) async -> [String: Any] {
            let marks = RealtimeTurnMarks()
            let now = ProcessInfo.processInfo.systemUptime
            marks.heardText = "click the battery icon in the menu bar"
            marks.heardCompleteUptime = now
            marks.lastAudioSentUptime = now
            marks.screenshotDisplayFrame = display
            let call = await RealtimeOpenAppTool.withFrontmostApp(
                RealtimeToolCall(callID: id, name: RealtimeVoiceVerbs.pressElementName, appName: nil, x: parts[0], y: parts[1]))
            marks.toolCalls = [call]
            marks.decisions = [RealtimeToolDecision(call: call, callUptime: now)]
            let before = windows()
            let clock = ProcessInfo.processInfo.systemUptime
            let dispatch = await RealtimeVoiceConnection.runToolCall(call, decisionIndex: 0, in: marks, harnessAnswer: answer, isCurrent: { true })
            let milliseconds = Int(((ProcessInfo.processInfo.systemUptime - clock) * 1000).rounded())
            try? await Task.sleep(for: .milliseconds(500))
            let after = windows()
            return ["result": dispatch?.result ?? NSNull(), "snappedBy": marks.decisions[0].snappedBy ?? NSNull(),
                    "sentVerb": dispatch?.harnessResponse?["action"] ?? NSNull(), "ms": milliseconds,
                    "windowsAppeared": Array(after.subtracting(before)).sorted(), "windowsGone": Array(before.subtracting(after)).sorted()]
        }
        let open = await press("voice-hands-open")
        summary["open"] = open
        let opened = !((open["windowsAppeared"] as? [String]) ?? []).isEmpty
        let close = await press("voice-hands-close")
        summary["close"] = close
        let closed = !((close["windowsGone"] as? [String]) ?? []).isEmpty
        summary["outcome"] = opened && closed ? "passed" : "failed"
        summary["witness"] = ["openedAWindow": opened, "closedAWindow": closed]
    }
}
