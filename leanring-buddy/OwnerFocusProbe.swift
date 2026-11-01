//
//  OwnerFocusProbe.swift
//  leanring-buddy
//
//  `--focus-probe` (2026-11-01): the focus resolver live, with no human and no
//  model. Each case posts real mouse moves (CGEvent, the HID tap) while the
//  session's own `OwnerFocusTracker` watches — the same monitors, selection read,
//  hit tests and guarded close-up a voice turn uses — then checks the answer
//  against a witness read by another path:
//    selection  a TextEdit document the probe opens from its own file (never
//               edited or saved; its window is closed by identity, TextEdit quit
//               only if the probe launched it); the selected range is set by AX.
//               Witness: the substring the probe selected.
//    circle     a loop around a menu-bar status icon (Wi‑Fi, else Battery, else the
//               first). Witness: `SystemUITargets.read` (the status verb), not the hit test.
//    dwell      a move onto a Dock icon, a rest, a move onto a second, a rest.
//               Witness: the Dock's own AXList items.
//    hover      the pointer still on a Finder toolbar button of a window the probe
//               opened. Witness: that button, read from the window's tree.
//  Also drives the notch's focus line on the real panel. Needs the start gate
//  (`ScenarioRunner.refusalToStart`: 120 s owner idle, no secure input).
//  Summary (0600) and the close-ups to ~/Library/Logs/Clicky/focus-probe/<ts>/, then quits.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum OwnerFocusProbe {
    static let textEdit = "com.apple.TextEdit"
    static let probeText = "JARVIS focus probe: the quick brown fox jumps over the lazy dog."
    static let selectedWords = "quick brown fox"

    static func run(harness: HarnessServer) async {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = MeasurementLogFile.directoryURL.appendingPathComponent("focus-probe/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var summary: [String: Any] = ["kind": "focusProbe", "timestamp": stamp]
        let startMouse = NSEvent.mouseLocation
        defer {
            move(to: startMouse)
            let line = MeasurementLogFile.jsonLine(summary) ?? #"{"kind":"focusProbe","outcome":"summaryNotSerialisable"}"#
            _ = MeasurementLogFile.appendOwnerOnly(Data((line + "\n").utf8), to: folder.appendingPathComponent("results.json"))
            MeasurementLogFile.waitForPendingWrites()
            print("🎯 focus probe: \(summary["outcome"] ?? "?") -> \(folder.path)")
        }
        if let refusal = ScenarioRunner.refusalToStart() { summary["outcome"] = "refused"; summary["reason"] = refusal; return }
        let answer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        let only = CommandLine.arguments.first { $0.hasPrefix("--focus-probe-cases=") }?
            .dropFirst("--focus-probe-cases=".count).split(separator: ",").map(String.init)
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }

        var results: [String: Any] = [:]
        if wanted("selection") { results["selection"] = await selectionCase(folder: folder, answer: answer) }
        if wanted("circle") { results["circle"] = await circleCase(folder: folder, answer: answer) }
        if wanted("dwell") { results["dwell"] = await dwellCase(folder: folder, answer: answer) }
        if wanted("hover") { results["hover"] = await hoverCase(folder: folder, answer: answer) }
        // Spends one Gemini Live turn: only when a clip is given.
        if let clipPath = CommandLine.arguments.first(where: { $0.hasPrefix("--focus-probe-voice=") })?.dropFirst("--focus-probe-voice=".count) {
            results["voice"] = await voiceCase(clipPath: String(clipPath), answer: answer)
        }
        summary["cases"] = results
        let verdicts = results.values.compactMap { ($0 as? [String: Any])?["outcome"] as? String }
        summary["outcome"] = verdicts.allSatisfy { $0 == "passed" } ? "passed" : "failed"
    }

    // MARK: Pointer

    /// One posted move to an AppKit point (the HID tap; CG's origin is top-left).
    static func move(to point: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGPoint(x: point.x, y: primaryHeight - point.y)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: topLeft, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Moves along `points`, one every `stepMilliseconds`.
    static func glide(_ points: [CGPoint], stepMilliseconds: Int = 12) async {
        for point in points {
            move(to: point)
            try? await Task.sleep(for: .milliseconds(stepMilliseconds))
        }
    }

    static func line(from a: CGPoint, to b: CGPoint, steps: Int = 14) -> [CGPoint] {
        (1...steps).map { index in
            let t = CGFloat(index) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// A turn as the session runs it: the tracker from the press, `during` while held, then the release.
    static func turn(folder: URL, name: String, answer: @escaping @Sendable (String) -> String,
                     during: () async -> Void) async -> (record: [String: Any], note: OwnerFocusNote?, target: RealtimeScreenTarget?) {
        let mouse = NSEvent.mouseLocation
        let tracker = OwnerFocusTracker(mouse: mouse)
        JarvisNotch.shared.handle(.hotkeyDown)
        await during()
        tracker.stop()
        JarvisNotch.shared.handle(.hotkeyUp)
        let (note, target, measured) = await tracker.resolve(harnessAnswer: answer)
        var record: [String: Any] = [
            "rung": measured.rung.rawValue, "resolveMs": measured.milliseconds, "selectionReadMs": measured.selectionReadMilliseconds,
            "samples": measured.samples, "dwells": measured.dwells, "namesFound": measured.namesFound, "crop": measured.crop ?? NSNull(),
            "pathSamplesRecorded": tracker.samples.count
        ]
        if let display = NSScreen.screens.first?.frame, let note {
            record["line"] = note.line(position: { RealtimeOpenAppTool.pointerPosition(mouse: $0, display: display, format: .fractions,
                                                                                        stack: .geminiLive, pixels: nil) })
            record["notchName"] = note.notchName
            JarvisNotch.shared.handle(.focusShown(name: note.notchName))
            record["notchState"] = JarvisNotch.shared.state.name
            if let crop = note.crop {
                let url = folder.appendingPathComponent("\(name)-crop.jpg")
                _ = MeasurementLogFile.appendOwnerOnly(crop, to: url)
                record["cropBytes"] = crop.count
                record["cropPixels"] = pixelSize(crop).map { [Int($0.width), Int($0.height)] } ?? NSNull()
            }
        }
        if let target { record["target"] = target.candidate?.name ?? "point \(Int(target.point.x)),\(Int(target.point.y))" }
        try? await Task.sleep(for: .milliseconds(1_400))
        record["notchStateAfterHold"] = JarvisNotch.shared.state.name
        JarvisNotch.shared.handle(.turnEnded)
        return (record, note, target)
    }

    static func pixelSize(_ jpeg: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: Cases

    static func circleCase(folder: URL, answer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        let screens = NSScreen.screens.map(\.frame)
        let targets = await Task.detached { SystemUITargets.read(frontApp: nil, answer: answer, screens: screens) }.value
        let icons = targets.filter { $0.place == .menuBar && $0.subrole == SystemUITargets.statusItemSubrole }
        // Control Centre's Wi‑Fi and Battery are not in the status read on this Mac (2026-11-01: Australian, Claude,
        // Wispr Flow only): found by sweeping the menu bar's right side with the hit test instead.
        func isWanted(_ name: String) -> Bool { name.hasPrefix("Wi\u{2011}Fi") || name.hasPrefix("Wi-Fi") || name.lowercased().hasPrefix("battery") }
        var swept: SystemUITargets.Target?
        var seen: [String] = []
        if let display = NSScreen.screens.first?.frame {
            let primaryHeight = display.height
            for x in stride(from: display.maxX - 520, to: display.maxX - 60, by: 6) where swept == nil {
                let point = CGPoint(x: x, y: display.maxY - 12)
                let hit = await RealtimeOpenAppTool.axHit(at: point, screens: screens, primaryDisplayHeight: primaryHeight, deadlineSeconds: 0.3)
                let label = hit.candidate.map { "\($0.name) \(Int($0.frame.width))" } ?? "\(hit)"
                if seen.last != label { seen.append(label) }
                if let candidate = hit.candidate, isWanted(candidate.name), candidate.frame.width > 0, candidate.frame.width < 80 {
                    swept = SystemUITargets.target(name: candidate.name, role: candidate.role, subrole: candidate.subrole, frame: candidate.frame,
                                                   place: .menuBar, screens: screens)
                }
            }
        }
        guard let icon = swept ?? icons.first(where: { $0.aliases.contains(where: isWanted) }) ?? icons.first else {
            return ["outcome": "skipped", "reason": "no status icon is on screen"]
        }
        let centre = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        let radius = max(icon.frame.width, icon.frame.height) / 2 + 10
        let path = OwnerFocusProbePaths.circle(centre: centre, radius: radius, sweep: 2.15 * .pi, count: 44)
        move(to: path[0])
        try? await Task.sleep(for: .milliseconds(300))
        var (record, note, _) = await turn(folder: folder, name: "circle", answer: answer) { await glide(path) }
        record["witness"] = ["icon": icon.name, "frame": [icon.frame.minX, icon.frame.minY, icon.frame.width, icon.frame.height]]
        record["statusIcons"] = icons.map { $0.aliases.joined(separator: "|") }
        record["sweep"] = seen
        var named = false
        if case .circle(let region, let inside)? = note?.kind {
            record["region"] = [region.minX, region.minY, region.width, region.height]
            named = inside.contains { described in icon.aliases.contains { described.contains($0) } }
            record["regionHoldsIcon"] = region.contains(centre)
        }
        record["outcome"] = note?.rung == .circle && named && note?.crop != nil ? "passed" : "failed"
        return record
    }

    static func dwellCase(folder: URL, answer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        let screens = NSScreen.screens.map(\.frame)
        guard let display = NSScreen.screens.first?.frame else { return ["outcome": "skipped", "reason": "no screen"] }
        // An autohidden Dock publishes its icons below the edge: the pointer at the bottom edge reveals it,
        // and it stays while the pointer stays on it.
        let start = CGPoint(x: display.midX, y: display.minY + 1)
        move(to: start)
        try? await Task.sleep(for: .milliseconds(1_200))
        let targets = await Task.detached { SystemUITargets.read(frontApp: nil, answer: answer, screens: screens) }.value
        let dock = targets.filter { $0.place == .dock && $0.role == "AXDockItem" && $0.subrole == "AXApplicationDockItem" }
        guard dock.count >= 3 else {
            return ["outcome": "skipped", "reason": "fewer than three Dock icons on screen"]
        }
        let first = dock[dock.count / 2 - 1], second = dock[dock.count / 2 + 1]
        let a = CGPoint(x: first.frame.midX, y: first.frame.midY), b = CGPoint(x: second.frame.midX, y: second.frame.midY)
        // The Dock magnifies under the pointer, so which icon a rest is on is read during that rest, from the
        // Dock's own items (not the hit test): the witness.
        func dockItemUnderPointer() async -> String? {
            let point = NSEvent.mouseLocation
            return await Task.detached {
                SystemUITargets.read(frontApp: nil, answer: answer, screens: screens).first { $0.place == .dock && $0.frame.contains(point) }?.name
            }.value
        }
        var restedOn: [String?] = []
        var (record, note, target) = await turn(folder: folder, name: "dwell", answer: answer) {
            await glide(line(from: start, to: a))
            try? await Task.sleep(for: .milliseconds(250))
            restedOn.append(await dockItemUnderPointer())
            try? await Task.sleep(for: .milliseconds(450))
            await glide(line(from: a, to: b, steps: 8))
            try? await Task.sleep(for: .milliseconds(200))
            restedOn.append(await dockItemUnderPointer())
            try? await Task.sleep(for: .milliseconds(300))
        }
        let firstRest = restedOn.first ?? nil, secondRest = restedOn.last ?? nil
        record["witness"] = ["aimedAt": [first.name, second.name], "restedOn": restedOn.map { $0 ?? "nothing" }]
        var inOrder = false
        if case .dwell(let stops)? = note?.kind {
            let described = stops.map { $0.described ?? "" }
            record["stops"] = described.count
            if let firstRest, let secondRest,
               let firstIndex = described.firstIndex(where: { $0.contains(UntrustedText(firstRest).forDisplay) }),
               let secondIndex = described.lastIndex(where: { $0.contains(UntrustedText(secondRest).forDisplay) }) {
                inOrder = firstIndex < secondIndex
            }
        }
        // "This one" is the longer rest: the first.
        let targetIsFirst = firstRest != nil && target?.candidate?.name == firstRest
        record["targetIsFirst"] = targetIsFirst
        record["outcome"] = note?.rung == .dwell && inOrder && targetIsFirst ? "passed" : "failed"
        return record
    }

    static func hoverCase(folder: URL, answer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        let directory = URL(fileURLWithPath: "/private/tmp/clicky-focus-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return ["outcome": "skipped", "reason": "Finder is not running"]
        }
        let before = Set(windows(of: finder.processIdentifier).map(AccessibilityElementKey.init))
        NSWorkspace.shared.open(directory)
        var opened: AXUIElement?
        for _ in 0..<40 where opened == nil {
            try? await Task.sleep(for: .milliseconds(150))
            opened = windows(of: finder.processIdentifier).first { !before.contains(AccessibilityElementKey(element: $0)) }
        }
        guard let window = opened else { return ["outcome": "failed", "reason": "the probe's Finder window never appeared"] }
        defer { close(window, processIdentifier: finder.processIdentifier) }
        try? await Task.sleep(for: .milliseconds(600))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let (buttonName, buttonFrame) = toolbarButton(in: window, primaryHeight: primaryHeight) else {
            return ["outcome": "failed", "reason": "no named toolbar button in the probe's Finder window"]
        }
        let point = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        move(to: point)
        try? await Task.sleep(for: .milliseconds(300))
        var (record, note, _) = await turn(folder: folder, name: "hover", answer: answer) {
            try? await Task.sleep(for: .milliseconds(600))
        }
        // The session's hover path: the key-down pointer read, as a note for the agent.
        let screens = NSScreen.screens.map(\.frame)
        let hit = await RealtimeVoiceSession.keyDownPointerHit(mouse: point, screens: screens, primaryDisplayHeight: primaryHeight)
        let hover = OwnerFocusNote.hoverNote(target: RealtimeOpenAppTool.keyDownPointerTarget(hit: hit, mouse: point), closeUp: nil)
        record["hoverNotchName"] = hover?.notchName ?? NSNull()
        record["hoverAgentLine"] = hover.map { note in
            note.line(position: { OwnerFocusNote.agentPosition($0, frame: screens.first, pixels: screens.first?.size) })
        } ?? NSNull()
        record["witness"] = ["button": buttonName]
        let named = hit.candidate.map { $0.name == buttonName || $0.frame.contains(point) && $0.name.contains(buttonName) } ?? false
        record["outcome"] = note == nil && record["rung"] as? String == "hover" && named ? "passed" : "failed"
        return record
    }

    static func selectionCase(folder: URL, answer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).isEmpty else {
            return ["outcome": "skipped", "reason": "TextEdit is running: it may hold the owner's documents"]
        }
        let directory = URL(fileURLWithPath: "/private/tmp/clicky-focus-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("JARVIS focus probe.txt")
        try? probeText.write(to: file, atomically: true, encoding: .utf8)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: textEdit) else {
            return ["outcome": "skipped", "reason": "TextEdit is not installed"]
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration)
        var area: AXUIElement?
        var window: AXUIElement?
        var application: NSRunningApplication?
        for _ in 0..<50 where area == nil {
            try? await Task.sleep(for: .milliseconds(200))
            application = NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).first
            guard let pid = application?.processIdentifier else { continue }
            window = windows(of: pid).first { title(of: $0)?.contains("JARVIS focus probe") == true }
            area = window.flatMap { firstDescendant(of: $0, role: kAXTextAreaRole) }
        }
        defer {
            if let window, let pid = application?.processIdentifier { close(window, processIdentifier: pid) }
            // Launched by the probe and holding only its own unedited file.
            if let application, !application.isTerminated { application.terminate() }
        }
        guard let area, let window else { return ["outcome": "failed", "reason": "the probe's TextEdit document never appeared"] }
        let start = (probeText as NSString).range(of: selectedWords)
        var range = CFRange(location: start.location, length: start.length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            return ["outcome": "failed", "reason": "setting the selection failed"]
        }
        _ = window
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let frame = AccessibilityTreeWalker.copyFrame(from: area).frame.map({
            AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame($0, primaryDisplayHeightInPoints: primaryHeight)
        }) else { return ["outcome": "failed", "reason": "the text area has no frame"] }
        move(to: CGPoint(x: frame.midX, y: frame.midY))
        try? await Task.sleep(for: .milliseconds(400))
        var (record, note, _) = await turn(folder: folder, name: "selection", answer: answer) {
            try? await Task.sleep(for: .milliseconds(600))
        }
        record["witness"] = ["selected": selectedWords]
        var matches = false
        if case .selectedText(let app, let text, _)? = note?.kind { matches = text == selectedWords && app == "TextEdit" }
        record["outcome"] = note?.rung == .selection && matches ? "passed" : "failed"
        return record
    }

    /// The whole voice turn: the session's own press/release with a spoken "what is this" clip where the mic's
    /// audio would be (`fixtureMic`, as the scenario runner drives it), circling a menu-bar icon while it plays.
    /// Witnesses: the turn's voice-live line (focusRung, focusNames, focusCrop) and the model's own answer.
    static func voiceCase(clipPath: String, answer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: clipPath)), let clip = VoiceBenchPCMClip.parseWAV(data),
              clip.sampleRate == 16_000 else { return ["outcome": "skipped", "reason": "no readable 16 kHz clip"] }
        guard let display = NSScreen.screens.first?.frame else { return ["outcome": "skipped", "reason": "no screen"] }
        let screens = NSScreen.screens.map(\.frame)
        // The Battery icon, found as the circle case finds it.
        var icon: RealtimeScreenCandidate?
        for x in stride(from: display.maxX - 520, to: display.maxX - 60, by: 6) where icon == nil {
            let hit = await RealtimeOpenAppTool.axHit(at: CGPoint(x: x, y: display.maxY - 12), screens: screens,
                                                      primaryDisplayHeight: display.height, deadlineSeconds: 0.3)
            if let candidate = hit.candidate, candidate.name.lowercased().hasPrefix("battery") { icon = candidate }
        }
        guard let icon else { return ["outcome": "skipped", "reason": "no Battery icon in the menu bar"] }
        let centre = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        let path = OwnerFocusProbePaths.circle(centre: centre, radius: max(icon.frame.width, icon.frame.height) / 2 + 10, sweep: 2.15 * .pi, count: 44)

        let session = RealtimeVoiceSession(harnessAnswer: answer)
        session.fixtureMic = true
        session.interruptedOffer = nil
        session.stackOverride = .geminiLive
        session.liveTurnLogFileName = "focus-probe-voice.log"
        var line: RealtimeLiveTurnLine?
        var marks: RealtimeTurnMarks?
        session.onLiveTurnLine = { line = $0 }
        session.onLiveTurnMarks = { marks = $0 }
        defer { session.stop() }
        session.prewarm()
        try? await Task.sleep(for: .seconds(ScenarioRunner.prewarmSeconds))
        move(to: path[0])
        try? await Task.sleep(for: .milliseconds(300))

        session.pressed()
        let circling = Task { @MainActor in await glide(path) }
        let chunks = clip.chunks(milliseconds: VoiceStackBenchmark.audioChunkMilliseconds)
        let clock = ContinuousClock()
        let start = clock.now
        for (index, chunk) in chunks.enumerated() {
            try? await clock.sleep(until: start + .milliseconds(VoiceStackBenchmark.audioChunkMilliseconds * index), tolerance: nil)
            session.feedProbeAudio(chunk)
        }
        await circling.value
        try? await clock.sleep(until: start + .milliseconds(VoiceStackBenchmark.audioChunkMilliseconds * chunks.count), tolerance: nil)
        session.released()
        for _ in 0..<300 where line == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let line else { return ["outcome": "failed", "reason": "the turn wrote no line in 30 s"] }
        let said = marks?.transcript ?? ""
        var record: [String: Any] = line.jsonObject.filter { $0.key.hasPrefix("focus") || ["turnEndReason", "errorKind", "firstAudioMs", "toolName"].contains($0.key) }
        record["said"] = said
        record["witness"] = ["icon": icon.name]
        record["focusNoteRung"] = marks?.ownerFocus?.rung.rawValue ?? NSNull()
        record["outcome"] = line.focusRung == "circle" && (line.focusNames ?? 0) >= 1 && line.focusCrop == "attached"
            && said.lowercased().contains("battery") ? "passed" : "failed"
        return record
    }

    // MARK: AX helpers (the probe's own windows only)

    nonisolated static func windows(of pid: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    nonisolated static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    nonisolated static func firstDescendant(of element: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        for child in children(element) {
            if attribute(child, kAXRoleAttribute) == role { return child }
            if let found = firstDescendant(of: child, role: role, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The first named button in the window's toolbar, with its AppKit frame.
    nonisolated static func toolbarButton(in window: AXUIElement, primaryHeight: CGFloat) -> (String, CGRect)? {
        guard let toolbar = firstDescendant(of: window, role: kAXToolbarRole) else { return nil }
        func visit(_ element: AXUIElement, depth: Int) -> (String, CGRect)? {
            for child in children(element) {
                if attribute(child, kAXRoleAttribute) == kAXButtonRole,
                   let name = attribute(child, kAXDescriptionAttribute) ?? attribute(child, kAXTitleAttribute), !name.isEmpty,
                   let frame = AccessibilityTreeWalker.copyFrame(from: child).frame, frame.width > 0, frame.height > 0 {
                    return (name, AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(frame, primaryDisplayHeightInPoints: primaryHeight))
                }
                if depth < 4, let found = visit(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return visit(toolbar, depth: 0)
    }

    /// Closes a window the probe opened, by its own close button (audited like every direct close).
    static func close(_ window: AXUIElement, processIdentifier: pid_t) {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button,
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
        let press = AccessibilityActionPerformer.perform(kAXPressAction, on: button as! AXUIElement)
        HarnessServer.auditDirectClose(tool: "OwnerFocusProbe.close", processIdentifier: processIdentifier, windowNumber: nil,
                                       why: "focus probe cleanup: its own window", closed: press.error == .success)
    }
}

/// The probe's circle: `sweep` radians from angle 0, `count` steps.
nonisolated enum OwnerFocusProbePaths {
    static func circle(centre: CGPoint, radius: CGFloat, sweep: CGFloat, count: Int) -> [CGPoint] {
        (0...count).map { index in
            let angle = sweep * CGFloat(index) / CGFloat(count)
            return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
    }
}
