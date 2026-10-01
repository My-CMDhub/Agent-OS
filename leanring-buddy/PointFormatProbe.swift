//
//  PointFormatProbe.swift
//  leanring-buddy
//
//  `--point-format-probe`: which way of asking a realtime model for a position
//  aims better — F1, x and y as 0-1 fractions (live since 2026-09-30), or F2,
//  each model's trained format (Gemini a [y, x] point normalised to 0-1000;
//  OpenAI pixels of the screenshot)? See `RealtimePointFormat`.
//
//  For up to N named visible elements of the frontmost window (Cursor, Finder,
//  System Settings or Chrome only), a `say` fixture "point at the <label>" is
//  streamed with the key-down screenshot into a FRESH connection per turn, per
//  stack, per format — ABBA, so neither format always goes first. The model's
//  RAW aim (its first point_at / press_element position, before any snap) is
//  scored against the element's AX frame: inside it or not, points to its
//  centre and to its edge; and whether the local snap (walk, then AX) names it.
//  A call aimed by name only is counted, not scored.
//
//  Safety: needs --harness-dry-run (a press is never performed) and 120 s of
//  owner idle, and stops when either input comes back. It opens, focuses and
//  closes nothing; the pointer may show on screen. Owner-approved 2026-10-01:
//  the models see the screen. Spends OpenAI credit (capped) and Gemini credit.
//  One JSON line per turn and a summary per stack x format to
//  ~/Library/Logs/Clicky/point-format-probe.log; a run that reads nothing
//  still writes why. `--point-format-probe-n=8`; `--voice-tool-probe-stacks=`.
//

import AppKit
import Foundation

@MainActor
enum PointFormatProbe {
    static let logFileName = "point-format-probe.log"
    static let defaultTargets = 8
    static let openAICostCapUSD = 0.60
    static let turnTimeoutSeconds: Double = 45
    /// Owner's ruling 2026-10-01: native apps and Chrome on a public page.
    static let allowedBundleIdentifiers: Set<String> = [
        "com.todesktop.230313mzl4w4u92", "com.apple.finder", "com.apple.systempreferences", "com.google.Chrome"
    ]
    /// A label a person would say: a few plain words.
    static let maximumLabelWords = 4
    static let maximumLabelCharacters = 30
    /// One control, not a pane: at most this share of the window.
    static let maximumWindowShare: CGFloat = 1.0 / 20

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Pure

    /// The raw aim against the element: inside its frame, and how far (pt) from
    /// its centre and from its nearest edge (0 inside).
    nonisolated static func aim(_ point: CGPoint, at frame: CGRect) -> (inside: Bool, toCentrePt: Double, toFramePt: Double) {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return (frame.contains(point), Double(hypot(point.x - frame.midX, point.y - frame.midY)), Double(hypot(dx, dy)))
    }

    /// Targets with one right answer: a short plain label no other visible
    /// element shares, small enough to be one control, spread across roles.
    static func targets(from pool: [RealtimeScreenVerbs.PoolElement], window: CGRect, count: Int) -> [RealtimeScreenVerbs.PoolElement] {
        let counts = Dictionary(pool.map { ($0.name, 1) }, uniquingKeysWith: +)
        let candidates = pool.filter { element in
            counts[element.name] == 1 && element.name.count <= maximumLabelCharacters
                && (1...maximumLabelWords).contains(element.name.split(whereSeparator: \.isWhitespace).count)
                && element.frame.width * element.frame.height <= window.width * window.height * maximumWindowShare
        }
        return PointProbe.spreadAcrossRoles(candidates, count: count)
    }

    /// ABBA: element 0 asks F1 first, element 1 F2 first, and so on.
    nonisolated static func order(forElement index: Int) -> [RealtimePointFormat] {
        index % 2 == 0 ? [.fractions, .native] : [.native, .fractions]
    }

    // MARK: Run

    private static func appendLine(_ line: [String: Any]) {
        MeasurementLogFile.appendJSONLine(line, toFileNamed: logFileName)
    }

    static func run(harness: HarnessServer) async {
        defer { MeasurementLogFile.waitForPendingWrites() }
        let probeID = UUID().uuidString
        let logPath = MeasurementLogFile.directoryURL.appendingPathComponent(logFileName).path
        func stop(_ kind: String, _ extra: [String: Any] = [:]) {
            appendLine(["kind": kind, "probeId": probeID].merging(extra) { _, new in new })
            print("🧪 point format probe: \(kind) -> \(logPath)")
        }
        guard WorkerConfiguration.isConfigured else { return stop("notConfigured") }
        guard CommandLine.arguments.contains("--harness-dry-run") else { return stop("refused", ["reason": "needs --harness-dry-run"]) }
        let idle = await Task.detached { NotchProbe.hidIdleSeconds() }.value
        guard let idle, idle >= NotchProbe.requiredIdleSeconds else { return stop("ownerActive", ["hidIdleSeconds": idle ?? NSNull()]) }
        let startUptime = uptime
        func ownerIsBack() async -> Bool {
            let now = uptime
            guard let idle = await Task.detached(operation: { NotchProbe.hidIdleSeconds() }).value else { return true }
            return idle < now - startUptime - 1
        }
        let front = await Task.detached { () -> (bundle: String?, name: String?) in
            let application = AccessibilityTreeWalker.focusedApplication()
            return (application?.bundleIdentifier, application?.localizedName)
        }.value
        guard let bundle = front.bundle, allowedBundleIdentifiers.contains(bundle) else {
            return stop("appNotAllowed", ["app": front.bundle ?? NSNull(), "allowed": allowedBundleIdentifiers.sorted()])
        }
        guard let shot = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen) else {
            return stop("captureFailed")
        }
        let answer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let snapshotLine = (try? RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "format-pool", name: RealtimeVoiceVerbs.findOnScreenName, appName: bundle, words: "pool")).get()) ?? ""
        let snapshot = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(snapshotLine) }.value)
        let pool = RealtimeScreenVerbs.visiblePool(fromSnapshotResponse: snapshot, screens: screens, screenshotDisplay: shot.displayFrame).pool
        let window = RealtimeScreenVerbs.frame(snapshot["windowFrame"]) ?? shot.displayFrame
        let count = CommandLine.arguments.first { $0.hasPrefix("--point-format-probe-n=") }
            .flatMap { Int($0.dropFirst("--point-format-probe-n=".count)) }.map { min(max($0, 1), 20) } ?? defaultTargets
        let chosen = targets(from: pool, window: window, count: count)
        let stacks = VoiceToolProbe.selectedStacksArgument()
        let pixels = CGSize(width: shot.screenshotWidthInPixels, height: shot.screenshotHeightInPixels)
        appendLine(["kind": "start", "probeId": probeID, "app": bundle, "hidIdleSeconds": idle, "snapshotOk": snapshot["ok"] as? Bool ?? false,
                    "visibleNamed": pool.count, "chosen": chosen.count, "stacks": stacks.map(\.rawValue),
                    "screenshotPixels": [shot.screenshotWidthInPixels, shot.screenshotHeightInPixels],
                    "display": [shot.displayFrame.minX, shot.displayFrame.minY, shot.displayFrame.width, shot.displayFrame.height],
                    "openAICostCapUSD": openAICostCapUSD])
        guard !chosen.isEmpty else { return stop("noTargets", ["app": bundle]) }

        var rows: [[String: Any]] = []
        var openAISpentUSD = 0.0
        targetLoop: for (index, element) in chosen.enumerated() {
            guard !(await ownerIsBack()) else {
                stop("ownerReturned", ["atTarget": index])
                break targetLoop
            }
            guard let (clip16k, clip24k) = await fixture(saying: "point at the \(element.name)") else {
                appendLine(["kind": "fixtureFailed", "probeId": probeID, "index": index])
                continue
            }
            for stack in stacks {
                for format in order(forElement: index) {
                    if stack == .openAIRealtime, openAISpentUSD > openAICostCapUSD { continue }
                    var row = await measure(stack: stack, format: format, element: element, clip: stack == .openAIRealtime ? clip24k : clip16k,
                                            shot: shot, pixels: pixels, appName: front.name, bundle: bundle, answer: answer,
                                            screens: screens, primaryHeight: primaryHeight)
                    if stack == .openAIRealtime, let spent = row["estimatedCostUSD"] as? Double { openAISpentUSD += spent }
                    row["probeId"] = probeID
                    row["index"] = index
                    rows.append(row)
                    appendLine(row)
                    print("🧪 point format probe: #\(index) \(stack.rawValue) \(format.rawValue) inside=\(row["inside"] ?? "-") snap=\(row["snapCorrect"] ?? "-")")
                }
            }
        }
        for stack in stacks {
            for format in RealtimePointFormat.allCases {
                appendLine(summary(rows.filter { $0["stack"] as? String == stack.rawValue && $0["format"] as? String == format.rawValue },
                                   stack: stack, format: format, probeID: probeID))
            }
        }
        print("🧪 point format probe: finished, \(rows.count) turns (OpenAI estimated US$\(openAISpentUSD)) -> \(logPath)")
    }

    /// One turn on a fresh connection: the model hears "point at the <label>"
    /// with the screenshot, and its first positional aim is scored.
    private static func measure(stack: VoiceStackChoice, format: RealtimePointFormat, element: RealtimeScreenVerbs.PoolElement,
                                clip: VoiceBenchPCMClip, shot: CompanionScreenCapture, pixels: CGSize, appName: String?, bundle: String,
                                answer: @escaping @Sendable (String) -> String, screens: [CGRect], primaryHeight: CGFloat) async -> [String: Any] {
        var row: [String: Any] = ["kind": "turn", "stack": stack.rawValue, "format": format.rawValue, "name": element.name,
                                  "role": RealtimeScreenVerbs.roleWord(role: element.role, subrole: element.subrole),
                                  "frame": [element.frame.minX, element.frame.minY, element.frame.width, element.frame.height]]
        let connection = RealtimeVoiceConnection(stack: stack, harnessAnswer: answer)
        connection.pointFormat = format
        connection.sendsFreshLook = false
        defer { connection.close() }
        do {
            try await connection.connect()
            try await connection.sendScreenshot(shot.imageData)
            try await connection.beginTurn()
            connection.turn.screenshotDisplayFrame = shot.displayFrame
            connection.turn.screenshotPixelSize = pixels
            if let line = RealtimeOpenAppTool.frontmostAppContextLine(appName: appName) { try await connection.sendContextText(line) }
            if format == .native, stack == .openAIRealtime {
                try await connection.sendContextText(RealtimeOpenAppTool.screenshotSizeContextLine(pixels: pixels))
            }
            let clock = ContinuousClock()
            let streamStart = clock.now
            for (chunkIndex, chunk) in clip.chunks(milliseconds: VoiceStackBenchmark.audioChunkMilliseconds).enumerated() {
                try await clock.sleep(until: streamStart + .milliseconds(VoiceStackBenchmark.audioChunkMilliseconds * chunkIndex), tolerance: nil)
                try await connection.appendAudio(chunk)
            }
            try await connection.endTurn()
            _ = try await connection.turn.finished.value(timeoutSeconds: turnTimeoutSeconds, timeoutKind: "turnTimeout")
        } catch {
            row["errorKind"] = (error as? VoiceBenchFailure)?.kind ?? VoiceBenchRun.errorKind(for: error, stage: stack.rawValue)
        }
        let turn = connection.turn
        row["tools"] = turn.toolCalls.map(\.name)
        let aiming = turn.toolCalls.filter { RealtimeVoiceVerbs.isScreenTargetTool($0.name) }
        let positional = aiming.first { $0.x != nil && $0.y != nil }
        row["aimedByPosition"] = positional != nil
        row["aimedByNameOnly"] = positional == nil && aiming.contains { $0.elementName != nil }
        row["aimedUnderPointer"] = positional == nil && aiming.contains { $0.underPointer }
        if let positional, let x = positional.x, let y = positional.y {
            row["fraction"] = [x, y]
            if let point = positional.point { row["rawPoint"] = point }
            if let point = RealtimeScreenVerbs.screenshotPoint(x: x, y: y, display: shot.displayFrame) {
                let scored = aim(point, at: element.frame)
                row["inside"] = scored.inside
                row["toCentrePt"] = (scored.toCentrePt * 10).rounded() / 10
                row["toFramePt"] = (scored.toFramePt * 10).rounded() / 10
                let hit = await RealtimeOpenAppTool.screenHit(at: point, app: bundle, answer: answer, screens: screens,
                                                              primaryDisplayHeight: primaryHeight, deadlineSeconds: 1).hit
                row["snapCorrect"] = hit.name == element.name
            } else {
                row["outOfRange"] = true
            }
        }
        if stack == .openAIRealtime { row["estimatedCostUSD"] = connection.estimatedOpenAIUSD }
        // Let a pointer from this turn fade before the next turn's screenshot-free aim.
        try? await Task.sleep(for: .seconds(1))
        return row
    }

    static func summary(_ rows: [[String: Any]], stack: VoiceStackChoice, format: RealtimePointFormat, probeID: String) -> [String: Any] {
        func count(_ key: String) -> Int { rows.filter { $0[key] as? Bool == true }.count }
        let scored = rows.filter { $0["inside"] != nil }
        func median(_ key: String) -> Any {
            let values = scored.compactMap { $0[key] as? Double }.sorted()
            return values.isEmpty ? NSNull() : values[values.count / 2]
        }
        return ["kind": "summary", "probeId": probeID, "stack": stack.rawValue, "format": format.rawValue, "turns": rows.count,
                "aimedByPosition": count("aimedByPosition"), "aimedByNameOnly": count("aimedByNameOnly"),
                "aimedUnderPointer": count("aimedUnderPointer"), "inside": "\(count("inside"))/\(scored.count)",
                "snapCorrect": "\(count("snapCorrect"))/\(scored.count)", "medianToCentrePt": median("toCentrePt"),
                "medianToFramePt": median("toFramePt"), "outOfRange": count("outOfRange"),
                "errors": rows.compactMap { $0["errorKind"] as? String }]
    }

    /// "point at the <label>" spoken by `say`, as the 16 kHz and 24 kHz clips
    /// the two stacks take (`scripts/make-voice-fixtures.sh`'s conversion), in a
    /// scratch directory removed afterwards. nil if either step fails.
    nonisolated static func fixture(saying sentence: String) async -> (VoiceBenchPCMClip, VoiceBenchPCMClip)? {
        await Task.detached { () -> (VoiceBenchPCMClip, VoiceBenchPCMClip)? in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("point-format-probe-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
            defer { try? FileManager.default.removeItem(at: directory) }
            func run(_ tool: String, _ arguments: [String]) -> Bool {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            }
            let aiff = directory.appendingPathComponent("say.aiff").path
            let wav16k = directory.appendingPathComponent("16k.wav"), wav24k = directory.appendingPathComponent("24k.wav")
            guard run("/usr/bin/say", ["-o", aiff, sentence]),
                  run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav16k.path]),
                  run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@24000", "-c", "1", aiff, wav24k.path]),
                  let clip16k = (try? Data(contentsOf: wav16k)).flatMap(VoiceBenchPCMClip.parseWAV), clip16k.sampleRate == 16_000,
                  let clip24k = (try? Data(contentsOf: wav24k)).flatMap(VoiceBenchPCMClip.parseWAV), clip24k.sampleRate == 24_000
            else { return nil }
            return (clip16k, clip24k)
        }.value
    }
}
