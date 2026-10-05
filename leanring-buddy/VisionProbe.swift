//
//  VisionProbe.swift
//  leanring-buddy
//
//  `--vision-probe` (2026-10-05): the three capabilities of that day, live, on
//  the canvas mimic page (scripts/scenarios/pages/canvas.html: three buttons
//  drawn as pixels, nothing of them in AX) in a NEW Chrome window this probe
//  opens, finds by a nonce in its title and closes by its own close button.
//
//   1. owner pointer: a posted mouse-MOVE (never a click) onto "Launch demo";
//      the key-down screenshot and AX hit the session uses, the close-up with
//      its crosshair (written as a JPEG), and the context line it would send.
//   2. the model's pointer at a bare position: the harness's highlight lands on
//      the OCR word box (`snappedTo`), photographed with `screencapture -x`.
//   3. annotate through `RealtimeOpenAppTool.dispatch`, photographed, with the
//      window server's own list of Clicky's overlay windows as the witness.
//   4. press_element "Launch demo" at its position through the shared
//      `RealtimeVoiceConnection.runToolCall` -> `visionClick`; witness: the
//      page's own title (`launch=1`), never the verb's verification. Then the
//      refusals at the verb: other words there, an irreversible word, a
//      destructive word (its ticket DENIED here, never allowed), no words, and
//      a control AX can press (Chrome's Reload: refused, nothing clicked).
//
//  Real input on its own window only: refuses --harness-dry-run, needs 30 s of
//  owner idle, and checks before every step that the window is still in front.
//  Summary (0600) to ~/Library/Logs/Clicky/vision-probe/, then quits.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum VisionProbe {
    static let chromeBundleIdentifier = "com.google.Chrome"
    static let requiredIdleSeconds = 30.0

    static var directoryURL: URL { MeasurementLogFile.directoryURL.appendingPathComponent("vision-probe", isDirectory: true) }

    static func run(harness: HarnessServer, confirmations: HarnessConfirmations) async {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let nonce = String(UUID().uuidString.prefix(8))
        let folder = directoryURL.appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var summary: [String: Any] = ["kind": "visionProbe", "timestamp": stamp, "nonce": nonce]
        defer {
            let line = MeasurementLogFile.jsonLine(summary) ?? #"{"kind":"visionProbe","outcome":"summaryNotSerialisable"}"#
            _ = MeasurementLogFile.appendOwnerOnly(Data((line + "\n").utf8), to: folder.appendingPathComponent("results.json"))
            MeasurementLogFile.waitForPendingWrites()
            print("🔎 vision probe: \(summary["outcome"] ?? "?") -> \(folder.path)")
        }
        let answer: @Sendable (String) -> String = { line in harness.answer(line: line) }
        func ask(_ request: [String: Any]) async -> [String: Any] {
            let line = String(decoding: (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            return RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(line) }.value)
        }
        guard !CommandLine.arguments.contains("--harness-dry-run") else {
            summary["outcome"] = "refused"; summary["reason"] = "real clicks on its own window; run without --harness-dry-run"; return
        }
        guard !SecureInputState.current().isOn else { summary["outcome"] = "refused"; summary["reason"] = "secure input is on"; return }
        let idle = ScenarioRunner.secondsSinceLastInput()
        guard idle >= requiredIdleSeconds else {
            summary["outcome"] = "refused"; summary["reason"] = "owner active (\(Int(idle)) s idle, needs \(Int(requiredIdleSeconds)))"; return
        }
        // Open: a new window, found by the nonce in its title and by being new; a
        // window that turns up after the deadline is still swept, by that nonce.
        var components = URLComponents(url: ScenarioRunner.pagesDirectory.appendingPathComponent("canvas.html"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "n", value: nonce)]
        guard let pageURL = components?.url else { summary["outcome"] = "noPage"; return }
        guard let window = ScenarioRunnerAX.openChromeWindow(urls: [pageURL], nonce: nonce) else {
            summary["outcome"] = "windowNotFound"; summary["cleanup"] = ScenarioRunnerAX.sweepLateRunnerWindows(nonce: nonce); return
        }
        defer { summary["cleanup"] = ScenarioRunnerAX.close(window, why: "vision probe cleanup: its own window, n=\(nonce)") }
        try? await Task.sleep(for: .milliseconds(800))
        guard inFront(window), let canvas = canvasFrame() else {
            summary["outcome"] = "pageNotReady"; summary["frontTitleHasNonce"] = title(window.element)?.contains(nonce) ?? false; return
        }
        summary["canvas"] = rect(canvas)
        // The page's own buttons, in CSS px from the canvas's top-left (inside its 1 px border).
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: canvas.minX + 1 + x, y: canvas.maxY - 1 - y) }
        let launch = point(130, 68), delete = point(390, 68), buy = point(130, 148), blank = point(390, 148)
        func pageState() -> String { title(window.element) ?? "" }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func topLeft(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }

        // 1. The owner's pointer, close up: a posted MOVE inside our own window.
        HarnessHands.postMouseMove(atTopLeft: topLeft(launch))
        try? await Task.sleep(for: .milliseconds(300))
        let mouse = NSEvent.mouseLocation
        var ownerPointer: [String: Any] = ["mouse": ["x": mouse.x, "y": mouse.y]]
        var pointerTarget: RealtimeScreenTarget?
        if let shot = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen) {
            let screens = NSScreen.screens.map(\.frame)
            let hit = await RealtimeVoiceSession.keyDownPointerHit(mouse: mouse, screens: screens, primaryDisplayHeight: primaryHeight)
            pointerTarget = RealtimeOpenAppTool.keyDownPointerTarget(hit: hit, mouse: mouse)
            let pixels = CGSize(width: shot.screenshotWidthInPixels, height: shot.screenshotHeightInPixels)
            let (jpeg, display) = (shot.imageData, shot.displayFrame)
            // As the session does at launch (`prewarm`), then the bounded call it makes
            // at key-down: in this fresh process, the first close-up Vision runs.
            let warming = Date()
            await Task.detached { ScreenOCR.warmUp() }.value
            ownerPointer["warmUpMs"] = Int(Date().timeIntervalSince(warming) * 1000)
            let started = Date()
            let closeUp = await RealtimeVoiceSession.value(within: RealtimeVoiceSession.pointerCloseUpDeadlineSeconds) {
                ScreenOCR.pointerCloseUp(screenshotJPEG: jpeg, mouse: mouse, display: display, imagePixels: pixels)
            }
            ownerPointer["closeUpMs"] = Int(Date().timeIntervalSince(started) * 1000)
            // And with no deadline, after it.
            var unboundedMs: [Int] = []
            for _ in 0..<3 {
                let began = Date()
                _ = await Task.detached { ScreenOCR.pointerCloseUp(screenshotJPEG: jpeg, mouse: mouse, display: display, imagePixels: pixels) }.value
                unboundedMs.append(Int(Date().timeIntervalSince(began) * 1000))
            }
            ownerPointer["unboundedMs"] = unboundedMs
            ownerPointer["deadlineMs"] = Int(RealtimeVoiceSession.pointerCloseUpDeadlineSeconds * 1000)
            if let closeUp { try? closeUp.jpeg.write(to: folder.appendingPathComponent("owner-pointer-closeup.jpg")) }
            ownerPointer["axHit"] = hit.name ?? (hit == .nothing ? "nothing" : "refused")
            ownerPointer["targetHasElement"] = pointerTarget?.candidate != nil
            ownerPointer["line"] = RealtimeOpenAppTool.ownerPointerContextLine(
                candidate: pointerTarget?.candidate, appName: "Google Chrome",
                position: RealtimeOpenAppTool.pointerPosition(mouse: mouse, display: display, format: .fractions, stack: .geminiLive, pixels: pixels),
                wordsUnderPointer: closeUp?.wordsUnderPointer, closeUpSent: closeUp != nil) ?? NSNull()
            summary["display"] = rect(display)
        }
        summary["ownerPointer"] = ownerPointer

        // 2. The model's pointer at a bare position: on the OCR word box, exactly.
        guard inFront(window) else { summary["outcome"] = "aborted"; summary["abort"] = "window left the front before step 2"; return }
        let pointed = await ask(["verb": "highlight", "target": "point", "pointer": true, "seconds": 3,
                                 "nearPoint": ["x": launch.x, "y": launch.y], "expectApp": chromeBundleIdentifier])
        try? await Task.sleep(for: .milliseconds(900))
        summary["pointAt"] = ["ok": pointed["ok"] ?? NSNull(), "snappedTo": pointed["snappedTo"] ?? NSNull(), "approximate": pointed["approximate"] ?? NSNull(),
                              "ocrText": pointed["ocrText"] ?? NSNull(), "drawnRect": pointed["drawnRect"] ?? NSNull(),
                              "screenshot": screencapture(folder, "point-at.png")]
        ElementPointer.hide()

        // 3. annotate, through the shared dispatch; the window server says what is drawn.
        guard inFront(window) else { summary["outcome"] = "aborted"; summary["abort"] = "window left the front before step 3"; return }
        let shapes = [RealtimeAnnotation(shape: "box", name: "Game lobby", underPointer: false, text: nil),
                      RealtimeAnnotation(shape: "label", name: "Game lobby", underPointer: false, text: "start here"),
                      RealtimeAnnotation(shape: "arrow", name: "Controls are drawn on the canvas above.", underPointer: false, text: nil),
                      RealtimeAnnotation(shape: "circle", name: nil, underPointer: true, text: nil),
                      RealtimeAnnotation(shape: "underline", name: "Mimic Arcade", underPointer: false, text: nil)]
        let drawn = await RealtimeOpenAppTool.dispatch(RealtimeToolCall(callID: "probe", name: RealtimeVoiceVerbs.annotateName,
                                                                        appName: chromeBundleIdentifier, shapes: shapes),
                                                       screenTarget: pointerTarget, answer: answer)
        try? await Task.sleep(for: .milliseconds(500))
        let ours = Set(AnnotationOverlay.windowNumbers)
        let serverWindows = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).filter {
            ($0[kCGWindowNumber as String] as? Int).map(ours.contains) ?? false
        }
        summary["annotate"] = ["result": drawn.result, "overlayWindowsOnScreen": serverWindows.count,
                               "screenshot": screencapture(folder, "annotate.png")]
        AnnotationOverlay.hide()

        // 4. press_element by sight, through the shared tool path.
        guard inFront(window), let display = NSScreen.screens.first(where: { $0.frame.contains(launch) })?.frame else {
            summary["outcome"] = "aborted"; summary["abort"] = "window left the front before step 4"; return
        }
        let marks = RealtimeTurnMarks()
        let now = ProcessInfo.processInfo.systemUptime
        marks.heardText = "press the launch demo button"
        marks.heardCompleteUptime = now
        marks.lastAudioSentUptime = now
        marks.screenshotDisplayFrame = display
        let press = RealtimeToolCall(callID: "probe-press", name: RealtimeVoiceVerbs.pressElementName, appName: chromeBundleIdentifier,
                                     elementName: "Launch demo", x: Double((launch.x - display.minX) / display.width),
                                     y: Double((display.maxY - launch.y) / display.height))
        marks.toolCalls = [press]
        marks.decisions = [RealtimeToolDecision(call: press, callUptime: now)]
        let stateBefore = pageState()
        let pressed = await RealtimeVoiceConnection.runToolCall(press, decisionIndex: 0, in: marks, harnessAnswer: answer, isCurrent: { true })
        try? await Task.sleep(for: .milliseconds(300))
        summary["visionPress"] = ["snappedBy": marks.decisions[0].snappedBy ?? NSNull(), "result": pressed?.result ?? NSNull(),
                                  "pageBefore": stateBefore, "pageAfter": pageState(),
                                  "witness": pageState().contains("launch=1") && stateBefore.contains("launch=0")]

        // The refusals, at the verb: nothing may change on the page.
        var refusals: [[String: Any]] = []
        func refusal(_ name: String, _ request: [String: Any]) async {
            guard inFront(window) else { refusals.append(["case": name, "skipped": "window not in front"]); return }
            let before = pageState()
            var response = await ask(request)
            if response["error"] as? String == "confirmationRequired", let ticket = response["ticket"] as? String {
                // A card the owner would answer: photographed, then denied here, never allowed.
                try? await Task.sleep(for: .milliseconds(700))
                response["cardScreenshot"] = screencapture(folder, "card-\(name).png")
                confirmations.answer(ticket, allow: false, scope: .once)
                var reissue = request
                reissue["ticket"] = ticket
                let denied = await ask(reissue)
                response["afterDeny"] = denied["error"] ?? NSNull()
            }
            try? await Task.sleep(for: .milliseconds(300))
            refusals.append(["case": name, "ok": response["ok"] ?? NSNull(), "error": response["error"] ?? NSNull(),
                             "afterDeny": response["afterDeny"] ?? NSNull(), "cardScreenshot": response["cardScreenshot"] ?? NSNull(), "ocrText": response["ocrText"] ?? NSNull(),
                             "kernel": (response["kernel"] as? [String: Any])?["decision"] ?? NSNull(),
                             "pageUnchanged": before == pageState()])
        }
        func vision(_ title: String, _ at: CGPoint) -> [String: Any] {
            ["verb": "visionClick", "title": title, "nearPoint": ["x": at.x, "y": at.y], "expectApp": chromeBundleIdentifier]
        }
        await refusal("otherWordsThere", vision("Launch demo", delete))
        await refusal("irreversibleWord", vision("Buy now", buy))
        await refusal("destructiveWordDenied", vision("Delete all", delete))
        await refusal("noWords", vision("Launch demo", blank))
        if let reload = chromeReloadCentre() { await refusal("axCanPressIt", vision("Reload", reload)) }
        summary["visionRefusals"] = refusals
        summary["outcome"] = "ran"
    }

    // MARK: Reads

    private static func title(_ window: AXUIElement) -> String? {
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private static func inFront(_ window: ScenarioWindow) -> Bool {
        let read = HarnessHands.browserWindow(processIdentifier: window.processIdentifier)
        return read.frontmost && read.window.map { CFEqual($0, window.element) } == true
    }

    /// The canvas: the 522 x 202 pt element (520 x 200 CSS px and its border).
    private static func canvasFrame() -> CGRect? {
        guard let root = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?.rootNode else { return nil }
        return root.flattenedDescendants().map(\.frameInAppKitCoordinates)
            .first { abs($0.width - 522) <= 3 && abs($0.height - 202) <= 3 }
    }

    private static func chromeReloadCentre() -> CGPoint? {
        guard let root = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?.rootNode,
              let node = root.flattenedDescendants().first(where: { $0.role == "AXButton" && $0.displayName?.raw == "Reload" }) else { return nil }
        let frame = node.frameInAppKitCoordinates
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private static func rect(_ frame: CGRect) -> [String: Double] {
        ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
    }

    /// The whole screen, as the owner sees it, while the drawing is up.
    private static func screencapture(_ folder: URL, _ name: String) -> String {
        let path = folder.appendingPathComponent(name).path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", path]
        try? process.run()
        process.waitUntilExit()
        return path
    }
}
