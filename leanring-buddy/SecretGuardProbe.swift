//
//  SecretGuardProbe.swift
//  leanring-buddy
//
//  `--secret-guard-probe`: runs the real `captureAllScreensAsJPEG` once - the
//  same credential guard every model-bound screenshot goes through - and writes
//  what came out: the redacted JPEG(s) and one JSON summary (outcome, reason,
//  walkMs, rects by kind and where they were drawn, excluded password-manager
//  windows, the secure-input flag and its holder), all 0600, into
//  ~/Library/Logs/Clicky/secret-guard-probe/, then quits. Counts and rects
//  only: never the text that matched.
//
//  Safety: needs --harness-dry-run like every probe. No owner-idle gate - owner
//  approved 2026-10-02 running it over non-sensitive windows. It opens, focuses
//  and presses nothing; it reads the frontmost window and photographs the screen.
//

import AppKit
import Foundation

@MainActor
enum SecretGuardProbe {
    static var directoryURL: URL {
        MeasurementLogFile.directoryURL.appendingPathComponent("secret-guard-probe", isDirectory: true)
    }

    static func run() async {
        defer { MeasurementLogFile.waitForPendingWrites() }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var summary: [String: Any] = [
            "kind": "secretGuardProbe", "timestamp": stamp,
            "walkDeadlineMs": Int(ScreenSecretGuard.walkDeadlineSeconds * 1000),
            "secureInput": SecureInputState.current().jsonObject
        ]
        // A run that reads nothing still writes why.
        defer { write(summary, named: "secret-guard-probe-\(stamp).json") }
        guard CommandLine.arguments.contains("--harness-dry-run") else {
            summary["outcome"] = "refused"
            summary["reason"] = "needs --harness-dry-run"
            return
        }
        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            summary["outcome"] = captures.first?.secretGuard?.outcome ?? "unguarded"
            summary["captures"] = captures.enumerated().map { index, capture -> [String: Any] in
                let imageName = "secret-guard-probe-\(stamp)-\(index).jpg"
                return captureEntry(capture, imageURL: write(capture.imageData, named: imageName)
                                        ? directoryURL.appendingPathComponent(imageName) : nil)
            }
        } catch let withheld as ScreenSecretGuard.Withheld {
            summary.merge(withheld.report.jsonObject) { _, new in new }
            summary["kind"] = "secretGuardProbe"
        } catch {
            summary["outcome"] = "captureFailed"
            summary["error"] = String(describing: error)
        }
        print("🧪 secret guard probe: \(summary["outcome"] ?? "?") -> \(directoryURL.path)")
    }

    /// One capture's summary entry. The path is `path(percentEncoded:)` on
    /// purpose: a bare `.path` in a `? : NSNull()` against `Any?` resolved to the
    /// METHOD, a `(Bool) -> String` closure, and every non-withheld summary
    /// failed to serialise and was silently never written (2026-10-02).
    static func captureEntry(_ capture: CompanionScreenCapture, imageURL: URL?) -> [String: Any] {
        var entry = capture.secretGuard?.jsonObject ?? [:]
        entry["image"] = imageURL.map { $0.path(percentEncoded: false) } ?? NSNull()
        entry["label"] = capture.label
        entry["imagePixels"] = [capture.screenshotWidthInPixels, capture.screenshotHeightInPixels]
        entry["displayFrame"] = rectArray(capture.displayFrame)
        entry["drawnRects"] = (capture.secretGuard?.drawn ?? []).map { ["kind": $0.kind, "rect": rectArray($0.rect)] }
        return entry
    }

    /// The summary's line, or - when it cannot be serialised - a line saying so
    /// and naming the keys at fault. Never nil: a run always leaves a file.
    nonisolated static func summaryLine(_ summary: [String: Any]) -> String {
        if let line = MeasurementLogFile.jsonLine(summary) { return line }
        let badKeys = summary.keys.filter { MeasurementLogFile.jsonLine(["value": summary[$0]!]) == nil }.sorted()
        return MeasurementLogFile.jsonLine([
            "kind": "secretGuardProbe", "outcome": "summaryNotSerialisable", "unserialisableKeys": badKeys,
            "probeOutcome": summary["outcome"] as? String ?? NSNull(), "timestamp": summary["timestamp"] as? String ?? NSNull()
        ]) ?? #"{"kind":"secretGuardProbe","outcome":"summaryNotSerialisable"}"#
    }

    nonisolated private static func rectArray(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }
    }

    /// Created 0600 by `open` itself (`appendOwnerOnly`); each name is new.
    @discardableResult
    private static func write(_ data: Data, named name: String) -> Bool {
        MeasurementLogFile.appendOwnerOnly(data, to: directoryURL.appendingPathComponent(name))
    }

    private static func write(_ summary: [String: Any], named name: String) {
        write(Data((summaryLine(summary) + "\n").utf8), named: name)
    }
}
