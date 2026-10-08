//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import AppKit
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    /// Pending harness tickets, asked on whatever Space the owner is on.
    private var confirmationCardWindowManager: ConfirmationCardWindowManager?
    private let companionManager = CompanionManager()
    /// One object, two owners: the harness opens tickets, the panel answers them.
    private let confirmations = HarnessConfirmations(
        rulesStore: ApprovalRulesKeychainStore(),
        ignoredApprovalsFileURL: HarnessServer.ignoredLegacyApprovalsFileURL
    )
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    /// One harness per process, socket or not: the voice loop's `open_app` goes
    /// through the same `answer(line:)` the socket does — same policy, kill
    /// switch, kernel, tickets and audit. `--harness` only adds the socket.
    private lazy var harnessServer = HarnessServer(
        globalDryRun: CommandLine.arguments.contains("--harness-dry-run"),
        confirmations: confirmations
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--capture-smoke-test") {
            runCaptureSmokeTest()
            return
        }

        // Spends API credit: capture -> Claude -> TTS download, five times, then quits.
        if CommandLine.arguments.contains("--voice-latency-probe") {
            Task { @MainActor in
                await VoiceLatencyProbe.run(companionManager: companionManager)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Spends API credit on four providers: 20 pipeline runs and 20 speech-to-speech
        // runs against the worker, one JSON line each, then quits. Plays nothing aloud.
        if CommandLine.arguments.contains("--voice-bench") {
            Task { @MainActor in
                await VoiceStackBenchmark.run()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Spends OpenAI credit (capped at US$0.50) and Gemini credit: ten "open
        // settings" turns per realtime stack through the harness, then quits.
        // The card is up so a confirmation ticket can be answered by hand.
        if CommandLine.arguments.contains("--voice-tool-probe") {
            confirmationCardWindowManager = ConfirmationCardWindowManager(confirmations: confirmations)
            Task { @MainActor in
                await VoiceToolProbe.run(harness: self.harnessServer)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Spends OpenAI (capped) and Gemini credit: the live push-to-talk session
        // driven headless through barge-ins, silence and taps, then quits. Needs
        // --harness-dry-run and 120 s of owner idle; refuses every tool call.
        if CommandLine.arguments.contains("--notch-probe") {
            Task { @MainActor in
                await NotchProbe.run()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // find_on_screen + point_at on the app in front, no model and no audio:
        // up to five pointers, each checked against the window server, then
        // quits. Needs --harness-dry-run and 120 s of owner idle.
        if CommandLine.arguments.contains("--point-probe") {
            Task { @MainActor in
                await PointProbe.run(harness: self.harnessServer)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // The pointing format A/B (RealtimePointFormat): "point at the <label>"
        // spoken into both stacks in both formats, raw aims scored against AX,
        // then quits. Spends OpenAI (capped) and Gemini credit. Needs
        // --harness-dry-run, 120 s of owner idle and Cursor / Finder / System
        // Settings / Chrome in front.
        if CommandLine.arguments.contains("--point-format-probe") {
            Task { @MainActor in
                await PointFormatProbe.run(harness: self.harnessServer)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // The credential guard on the real capture path: the redacted screenshot(s)
        // and a JSON summary, 0600, to ~/Library/Logs/Clicky/secret-guard-probe/,
        // then quits. Needs --harness-dry-run; no idle gate (owner-approved 2026-10-02).
        if CommandLine.arguments.contains("--secret-guard-probe") {
            Task { @MainActor in
                await SecretGuardProbe.run()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // A turn the owner did not speak (beginSystemTurn): does each stack answer
        // it, and does a press still cut it off? Spends OpenAI (capped) and Gemini
        // credit. Needs --harness-dry-run and 120 s of owner idle; refuses every tool call.
        if CommandLine.arguments.contains("--speak-probe") {
            Task { @MainActor in
                await SpeakProbe.run()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // The session WATCH loop's cost on the app in front: a forModel snapshot,
        // then a window-title read, every 0.5 s for 60 s each, then quits. Reads
        // only. Needs --harness-dry-run and 120 s of owner idle.
        if CommandLine.arguments.contains("--watch-probe") {
            Task { @MainActor in
                await WatchProbe.run(harness: self.harnessServer)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // The scenario runner: spoken fixtures through the live session, each judged
        // by its own structure read; report to ~/Library/Logs/Clicky/scenarios/,
        // then quits. Spends Gemini (and, if asked, capped OpenAI) credit. Real
        // actions, so it refuses --harness-dry-run; needs 120 s of owner idle. The
        // card is up so a ticket shows as it would live; the runner only denies.
        if CommandLine.arguments.contains("--scenario-run") {
            confirmationCardWindowManager = ConfirmationCardWindowManager(confirmations: confirmations)
            Task { @MainActor in
                await ScenarioRunner.run(harness: self.harnessServer, confirmations: self.confirmations)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // The agent loop (do_task's runner) driven directly on the runner's B
        // scenarios, no voice: Claude via the worker, real actions in a Chrome
        // window it opens and closes by identity; cards photographed and denied.
        // Same gate as the runner: 120 s owner idle, refuses --harness-dry-run.
        if CommandLine.arguments.contains("--agent-loop-probe") {
            confirmationCardWindowManager = ConfirmationCardWindowManager(confirmations: confirmations)
            Task { @MainActor in
                await AgentLoopProbe.run(harness: self.harnessServer, confirmations: self.confirmations)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // The hands (click, type by AX write and by keystrokes, openURL) on a page
        // it writes, in a Chrome window it opens and closes by identity; JSON
        // summary 0600 to ~/Library/Logs/Clicky/hands-probe/, then quits. Real
        // input on its own window only, so it refuses --harness-dry-run.
        if CommandLine.arguments.contains("--hands-probe") {
            Task { @MainActor in
                await HandsProbe.run(harness: self.harnessServer)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // The vision click, the owner-pointer close-up, OCR pointer snapping and
        // annotate, live on the canvas mimic page in a Chrome window it opens
        // and closes by identity; cards denied. Refuses --harness-dry-run.
        if CommandLine.arguments.contains("--vision-probe") {
            confirmationCardWindowManager = ConfirmationCardWindowManager(confirmations: confirmations)
            Task { @MainActor in
                await VisionProbe.run(harness: self.harnessServer, confirmations: self.confirmations)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Generality suite: ~20 general-pattern tasks through the agent loop, each
        // judged by its own state checker; same start gate as the runner. Cards are
        // denied, never allowed; ~/Library/Logs/Clicky/generality/<ts>/, then quits.
        if CommandLine.arguments.contains("--generality-suite") {
            confirmationCardWindowManager = ConfirmationCardWindowManager(confirmations: confirmations)
            Task { @MainActor in
                await GeneralitySuite.run(harness: self.harnessServer, confirmations: self.confirmations)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Coverage audit: per app, AX walk + OCR of a guarded capture + menu index,
        // read-only, zero model calls; ~/Library/Logs/Clicky/coverage/<ts>/, then quits.
        if CommandLine.arguments.contains("--coverage-audit") {
            Task { @MainActor in
                await CoverageAudit.run()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Walks Finder / System Settings / Cursor on main and on a background
        // queue, writes ~/Library/Logs/Clicky/ax-thread-probe.log, then quits.
        if CommandLine.arguments.contains("--ax-thread-probe") {
            Task { @MainActor in
                await AccessibilityThreadProbe.run()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        if CommandLine.arguments.contains("--ax-probe") {
            Task { await AccessibilityDumpRunner.runProbe() }
            return
        }

        if CommandLine.arguments.contains("--ax-survey") {
            Task { await AccessibilityDumpRunner.runSurvey() }
            return
        }

        if CommandLine.arguments.contains("--ax-dump") {
            Task { await AccessibilityDumpRunner.run() }
            return
        }

        if CommandLine.arguments.contains("--ax-action") {
            Task { await AccessibilityDumpRunner.runAction() }
            return
        }

        if CommandLine.arguments.contains("--ax-select") {
            Task { await AccessibilityDumpRunner.runSelect() }
            return
        }

        if CommandLine.arguments.contains("--ax-task") {
            Task { await AccessibilityDumpRunner.runTask() }
            return
        }

        // Started before the harness so its first request is already covered.
        if CommandLine.arguments.contains("--main-thread-stall-log") {
            MainThreadStallRecorder.start()
        }

        // Unlike every other --ax-* entry point, this one does NOT terminate:
        // the harness is a server, so the app carries on being a menu-bar app
        // with a socket open beside it.
        if CommandLine.arguments.contains("--harness") {
            harnessServer.start()
        }

        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager, confirmations: confirmations)
        confirmationCardWindowManager = ConfirmationCardWindowManager(confirmations: confirmations)
        let sharedHarness = harnessServer
        companionManager.realtimeVoiceSession = RealtimeVoiceSession(harnessAnswer: { line in sharedHarness.answer(line: line) })
        confirmationCardWindowManager?.replyAudioIsPlaying = { [companionManager] in
            companionManager.realtimeVoiceSession?.isReplyAudioPlaying ?? false
        }
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    private func runCaptureSmokeTest() {
        print("🧪 Clicky: capture smoke test starting")

        Task { @MainActor in
            do {
                let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                let outputDirectory = URL(fileURLWithPath: "/private/tmp/heyclicky-capture-smoke-test", isDirectory: true)
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

                print("🧪 Clicky: capture count = \(captures.count)")
                for (index, capture) in captures.enumerated() {
                    print("🧪 Clicky: capture[\(index + 1)] label=\(capture.label)")
                    print("🧪 Clicky: capture[\(index + 1)] cursorScreen=\(capture.isCursorScreen)")
                    print("🧪 Clicky: capture[\(index + 1)] displayFrame=\(capture.displayFrame.debugDescription)")
                    print("🧪 Clicky: capture[\(index + 1)] displayPoints=\(capture.displayWidthInPoints)x\(capture.displayHeightInPoints)")
                    print("🧪 Clicky: capture[\(index + 1)] screenshotPixels=\(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels)")

                    let safeLabel = capture.label
                        .lowercased()
                        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    let fileName = "capture-\(index + 1)-\(safeLabel.isEmpty ? "screen" : safeLabel).jpg"
                    let fileURL = outputDirectory.appendingPathComponent(fileName)
                    try capture.imageData.write(to: fileURL, options: .atomic)
                    print("🧪 Clicky: wrote \(fileURL.path)")
                    print("🧪 Clicky: \(capture.label) | \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) px | cursorScreen=\(capture.isCursorScreen)")
                }

                print("🧪 Clicky: capture smoke test finished")
            } catch {
                print("❌ Clicky: capture smoke test failed: \(error)")
            }

            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
