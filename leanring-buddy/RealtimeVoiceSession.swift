//
//  RealtimeVoiceSession.swift
//  leanring-buddy
//
//  The live push-to-talk loop on a speech-to-speech stack: key-down captures the
//  cursor screen and opens the mic, the PCM streams while the key is held,
//  key-up ends the turn, and the answer plays as it arrives. Tool calls are
//  answered inside `RealtimeVoiceConnection` through the harness.
//
//  Lives beside `CompanionManager`, which only routes the hotkey here.
//
//  Every push-to-talk turn appends one JSON line — counts and timings, never
//  words — to ~/Library/Logs/Clicky/voice-live.log, including a turn that
//  failed or was barged in on, so a silent turn is never an invisible one; and
//  each of its tool calls one line to voice-decisions.log (`RealtimeDecisionTrace`).
//  The words themselves go only to the owner-only voice-transcripts.log
//  (`RealtimeTranscriptLog`, owner's ruling 2026-09-30).
//
//  `--notch-probe` drives `pressed()` / `released()` headless with a fixture in
//  place of the mic (`probeMode`), barge-ins included; `--voice-tool-probe`
//  verifies the shared connection and tool path.
//

import AppKit
import AVFoundation
import Foundation

@MainActor
final class RealtimeVoiceSession {
    private let harnessAnswer: @Sendable (String) -> String
    private var connection: RealtimeVoiceConnection?
    private var connectTask: Task<RealtimeVoiceConnection, Error>?
    private var connectingStack: VoiceStackChoice?

    private let micEngine = AVAudioEngine()
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var turnTask: Task<Void, Never>?
    /// The turn whose line is not yet written; nil once it is.
    private var liveTurn: LiveTurn?
    /// The latest turn's id, kept past its line: a press while its answer still
    /// plays is a barge-in even when that line was already written.
    private var lastTurnID: String?
    /// The last written line's `errorKind`: a failed turn's words are no answer to agree with.
    private var lastLineErrorKind: String?
    /// When the scheduled reply audio runs out, by arithmetic on what was
    /// scheduled — no render callback to trust. 0 once playback is stopped.
    private var replyAudioEndsUptime: TimeInterval = 0
    var isReplyAudioPlaying: Bool { uptime < replyAudioEndsUptime }

    /// Probe only (`--notch-probe`): no mic and no key-down capture —
    /// `feedProbeAudio` stands in for the mic — and nothing is heard aloud.
    var probeMode = false {
        didSet { playerNode.volume = probeMode ? 0 : 1; tickNode.volume = probeMode ? 0 : 1 }
    }
    /// Probe only: the stack, without writing the owner's picker.
    var stackOverride: VoiceStackChoice?
    /// Probe only: each line as it is written, and to its own file — the
    /// owner's voice-live.log stays the owner's.
    var onLiveTurnLine: ((RealtimeLiveTurnLine) -> Void)?
    var liveTurnLogFileName = RealtimeVoiceSession.liveLogFileName
    var estimatedOpenAIUSD: Double { connection?.estimatedOpenAIUSD ?? 0 }

    private final class LiveTurn {
        var line: RealtimeLiveTurnLine
        let pressedUptime: TimeInterval
        var releasedUptime: TimeInterval?
        /// The connection's marks for this turn, once `beginTurn` created them.
        var marks: RealtimeTurnMarks?
        /// The no-reply watchdog showed "No reply" for this turn.
        var watchdogFired = false
        /// `RealtimeVoiceSession.previousReplyWasHeard`, decided at the press.
        var previousReplyWasHeard = false
        init(line: RealtimeLiveTurnLine, pressedUptime: TimeInterval) {
            self.line = line
            self.pressedUptime = pressedUptime
        }
    }

    static let liveLogFileName = "voice-live.log"
    /// The key-down frontmost read is cross-process AX: the system-wide element
    /// can sit on the ~6 s default messaging timeout, then the `AXFrontmost`
    /// fallback on another 0.5 s. The line is a hint, so it gets this long from
    /// key-down — about the capture it runs beside (~230-350 ms) — or is skipped.
    nonisolated static let frontmostReadDeadlineSeconds: Double = 0.3

    /// `read`'s answer, or nil once `seconds` pass — whichever comes first. The
    /// read cannot be cancelled (a blocked AX call returns when it returns); a
    /// late answer is dropped. Both run on GCD, not the Swift cooperative pool:
    /// a blocking read there holds a pool thread, and a timer task queued behind
    /// busy pool threads lost the race to a 2 s read under a 0.1 s deadline (test run 2026-09-30).
    /// The read runs on its OWN thread (review 2026-09-30): a stuck AX read
    /// never holds a GCD worker the deadline's timer needs.
    nonisolated static func value<T: Sendable>(within seconds: Double, _ read: @escaping @Sendable () -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            Thread { once.resume(read()) }.start()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
        }
    }

    /// The key-down "under the owner's pointer" read, shared with the tool probe:
    /// the AX rung only, bounded — a walk here would queue on the harness in
    /// front of the turn's own calls (review 2026-09-30: ~1.8 s in Mail).
    nonisolated static func keyDownPointerHit(mouse: CGPoint, screens: [CGRect], primaryDisplayHeight: CGFloat) async -> RealtimeScreenHit {
        await RealtimeOpenAppTool.axHit(at: mouse, screens: screens, primaryDisplayHeight: primaryDisplayHeight,
                                        deadlineSeconds: frontmostReadDeadlineSeconds)
    }
    /// Did the owner hear the previous answer whole? Only if this press cut
    /// nothing off — its line was closed and its audio done (both set
    /// `bargedInPreviousTurnID`) — and that turn did not end in an error, whose
    /// transcript may be a fragment. The plain-yes gate trusts `said` only then.
    nonisolated static func previousReplyWasHeard(line: RealtimeLiveTurnLine, previousErrorKind: String?) -> Bool {
        line.bargedInPreviousTurnID == nil && !line.previousAudioWasPlaying && previousErrorKind == nil
    }
    /// The probe's: a tool call may wait on a 60 s confirmation ticket.
    static let turnTimeoutSeconds: Double = 90
    /// Probe only: stands in for the key-down capture, which keeps live
    /// `beginTurn` ~230-350 ms behind the press (review 2026-09-29) — the window
    /// where a cut-off answer's leftovers still arrive for the old turn.
    static let probeCaptureStandInMilliseconds = 300
    /// A turn still `thinking` this long after the release, with no word and no
    /// tool call, shows "No reply" (the turn itself keeps waiting). 4.1x the
    /// slowest release -> first word or tool call on the live path (2,441 ms,
    /// Gemini; n = 243 across voice-live.log and voice-tool-probe.log to
    /// 2026-09-28), and 1.5x the bench's worst outlier (6,727 ms, a full-display
    /// screenshot, voice-bench.log).
    static let noReplyWatchdogSeconds: Double = 10
    /// Probe only: shortened to force the watchdog.
    var noReplyWatchdogSeconds = RealtimeVoiceSession.noReplyWatchdogSeconds
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceStackChoice.outputSampleRate), channels: 1, interleaved: false
    )!

    /// The press and release ticks: their own node on the playback engine, one
    /// cached buffer each, 48 kHz mono (the mixer resamples).
    private let tickNode = AVAudioPlayerNode()
    private let tickFormat = AVAudioFormat(standardFormatWithSampleRate: JarvisNotchTick.sampleRate, channels: 1)!
    private lazy var tickBuffers: [JarvisNotchTick: AVAudioPCMBuffer] = Dictionary(
        uniqueKeysWithValues: JarvisNotchTick.allCases.compactMap { tick in tick.buffer(format: tickFormat).map { (tick, $0) } })

    /// listening on key-down, processing on key-up, responding at first audio, idle when the turn ends.
    var onStateChange: ((CompanionVoiceState) -> Void)?

    init(harnessAnswer: @escaping @Sendable (String) -> String) {
        self.harnessAnswer = harnessAnswer
        playbackEngine.attach(playerNode)
        // The mixer resamples 24 kHz to the device rate.
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.attach(tickNode)
        playbackEngine.connect(tickNode, to: playbackEngine.mainMixerNode, format: tickFormat)
        // The pointer stays while its turn is still being answered or its
        // reply still plays (slice 1b: no fixed 2.5 s); the notch reads the same state.
        ElementPointer.holdWhile = { [weak self] in
            guard let self else { return false }
            return self.liveTurn != nil || self.isReplyAudioPlaying
        }
        ElementPointer.onVisibilityChange = { [weak self] visible, uptime in self?.pointerVisibilityChanged(visible, at: uptime) }
    }

    /// The turn the pointer was shown in: its id and release, and when it appeared.
    private var pointerShown: (turnID: String, releasedUptime: TimeInterval?, shownUptime: TimeInterval)?

    /// One `kind: "pointer"` line in voice-live.log when the pointer goes, ms
    /// from that turn's release: shown, hidden, and when the reply's audio ran
    /// out. Its own line because the turn's line is written before either end.
    private func pointerVisibilityChanged(_ visible: Bool, at uptime: TimeInterval) {
        if visible {
            pointerShown = (lastTurnID ?? "-", liveTurn?.releasedUptime, uptime)
            return
        }
        guard let shown = pointerShown else { return }
        pointerShown = nil
        MeasurementLogFile.appendJSONLine([
            "kind": "pointer", "turnId": shown.turnID,
            "pointerShownMs": Self.milliseconds(from: shown.releasedUptime, to: shown.shownUptime) ?? NSNull(),
            "pointerHiddenMs": Self.milliseconds(from: shown.releasedUptime, to: uptime) ?? NSNull(),
            "replyAudioEndMs": replyAudioEndsUptime > 0 ? (Self.milliseconds(from: shown.releasedUptime, to: replyAudioEndsUptime) ?? NSNull()) as Any : NSNull()
        ], toFileNamed: liveTurnLogFileName)
    }

    private var selectedStack: VoiceStackChoice { stackOverride ?? VoiceStackChoice.stored(in: .standard) }

    // MARK: Connection

    /// Setup is ~2 s (token + socket + session ack), so it is paid here — at app
    /// start, after each turn, and when the picker changes — not at key-down.
    func prewarm() {
        Task { _ = try? await readyConnection() }
    }

    /// Reconnects lazily: a session the server closed (idle limits, Gemini's
    /// GoAway) reports itself closed, and the next press pays setup once.
    /// ponytail: no proactive refresh before a provider's session cap (OpenAI
    /// ~60 min, Gemini ~10 min per connection); add one if a press hits it often.
    private func readyConnection() async throws -> RealtimeVoiceConnection {
        let wanted = selectedStack
        if let connection, connection.isOpen, connection.stack == wanted { return connection }
        if connectTask == nil || connectingStack != wanted {
            connection?.close()
            connection = nil
            connectingStack = wanted
            let harnessAnswer = self.harnessAnswer
            connectTask = Task { @MainActor in
                let newConnection = RealtimeVoiceConnection(stack: wanted, harnessAnswer: harnessAnswer)
                try await newConnection.connect()
                return newConnection
            }
        }
        let task = connectTask!
        do {
            let readyConnection = try await task.value
            if connectTask == task { connectTask = nil }
            wire(readyConnection)
            connection = readyConnection
            return readyConnection
        } catch {
            if connectTask == task { connectTask = nil }
            throw error
        }
    }

    private func wire(_ connection: RealtimeVoiceConnection) {
        connection.onAudio = { [weak self] pcmData in self?.play(pcmData) }
        connection.onTurnFinished = { [weak self] in
            self?.onStateChange?(.idle)
            self?.prewarm()
        }
        connection.onClosed = { [weak self, weak connection] in
            if let self, self.connection === connection { self.connection = nil }
        }
    }

    // MARK: Push-to-talk

    func pressed() {
        // A new request takes the last pointer away (its audio end is still known here).
        ElementPointer.hide()
        // Barge-in: a new press silences whatever is still being said.
        let previousLineWasOpen = liveTurn != nil
        let previousAudioWasPlaying = isReplyAudioPlaying
        writeLiveTurnLine(bargedIn: true)
        let stack = selectedStack
        var line = RealtimeLiveTurnLine(stack: stack.rawValue, turnID: UUID().uuidString,
                                        sessionWasWarm: connection.map { $0.isOpen && $0.stack == stack } ?? false)
        if previousLineWasOpen || previousAudioWasPlaying {
            line.bargedInPreviousTurnID = lastTurnID
            line.previousAudioWasPlaying = previousAudioWasPlaying
        }
        lastTurnID = line.turnID
        liveTurn = LiveTurn(line: line, pressedUptime: uptime)
        liveTurn?.previousReplyWasHeard = Self.previousReplyWasHeard(line: line, previousErrorKind: lastLineErrorKind)
        stopPlayback()
        JarvisNotch.shared.currentTurnID = line.turnID
        JarvisNotch.shared.handle(.hotkeyDown)
        playTick(.press)
        connection?.supersedeForPress()
        turnTask?.cancel()
        audioContinuation?.finish()

        let (audioStream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        audioContinuation = continuation
        do {
            if !probeMode { try startMic(targetSampleRate: selectedStack.inputSampleRate, continuation: continuation) }
        } catch {
            print("❌ realtime: mic failed to start: \(error)")
            writeLiveTurnLine(errorKind: "micFailed")
            JarvisNotch.shared.handle(.hotkeyUp)
            JarvisNotch.shared.handle(.turnEnded)
            continuation.finish()
            onStateChange?(.idle)
            return
        }
        onStateChange?(.listening)
        turnTask = Task { [weak self] in await self?.runTurn(audioStream) }
    }

    func released() {
        liveTurn?.releasedUptime = uptime
        if !probeMode { stopMic() }
        audioContinuation?.finish()
        audioContinuation = nil
        JarvisNotch.shared.handle(.hotkeyUp)
        playTick(.release)
        onStateChange?(.processing)
    }

    /// Probe only: a fixture chunk where the mic's would be, at the input rate.
    func feedProbeAudio(_ pcmChunk: Data) {
        audioContinuation?.yield(pcmChunk)
        JarvisNotch.shared.setLevel(rms: JarvisNotchLevel.rms(pcm16: pcmChunk))
    }

    /// The mic is already running while this connects and captures; its audio
    /// waits in the stream and is sent in order once the turn is open.
    private func runTurn(_ audioStream: AsyncStream<Data>) async {
        let liveTurn = self.liveTurn
        do {
            let probeMode = self.probeMode
            let screenshotTask = Task { @MainActor () -> CompanionScreenCapture? in
                guard !probeMode else {
                    try await Task.sleep(for: .milliseconds(Self.probeCaptureStandInMilliseconds))
                    return nil
                }
                return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen)
            }
            // The app in front, from structure — the harness's own read, off main
            // (cross-process AX), bounded from key-down. Its name only; never
            // Clicky's own panel.
            let frontmostLineTask = Task { () -> String? in
                guard !probeMode else { return nil }
                return await Self.value(within: Self.frontmostReadDeadlineSeconds) { () -> String? in
                    guard let application = AccessibilityTreeWalker.focusedApplication(),
                          !HarnessServer.isHarnessItself(bundleIdentifier: application.bundleIdentifier) else { return nil }
                    return RealtimeOpenAppTool.frontmostAppContextLine(appName: application.localizedName)
                }
            }
            // What is under the owner's mouse, from structure, bounded from key-down
            // like the frontmost line: "this one" / "where my cursor is".
            let mouse = NSEvent.mouseLocation
            let screens = NSScreen.screens.map(\.frame)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let pointerTask = Task { () -> RealtimeScreenHit? in
                guard !probeMode else { return nil }
                return await Self.keyDownPointerHit(mouse: mouse, screens: screens, primaryDisplayHeight: primaryHeight)
            }
            let setupStart = uptime
            let connection = try await readyConnection()
            if liveTurn?.line.sessionWasWarm == false { liveTurn?.line.sessionSetupMs = Self.milliseconds(from: setupStart, to: uptime) }
            var screenshotDisplayFrame: CGRect?
            var screenshotPixelSize: CGSize?
            if let screenshot = try? await screenshotTask.value {
                try await connection.sendScreenshot(screenshot.imageData)
                screenshotDisplayFrame = screenshot.displayFrame
                screenshotPixelSize = CGSize(width: screenshot.screenshotWidthInPixels, height: screenshot.screenshotHeightInPixels)
            }
            // A press since this one owns the connection now: its `beginTurn` must not be replaced by ours.
            guard !Task.isCancelled else { return }
            // A press while the last answer still played cut words off it: those
            // words cannot be what a plain "yes" agrees to (`confirmedByPlainYes`).
            try await connection.beginTurn(previousReplyWasHeard: liveTurn?.previousReplyWasHeard == true)
            let marks = connection.turn
            liveTurn?.marks = marks
            marks.screenshotDisplayFrame = screenshotDisplayFrame
            marks.screenshotPixelSize = screenshotPixelSize
            // Beside the audio, never ahead of it; before the release, so on Gemini
            // it stays inside the owner's activity. Not into a turn that replaced this one.
            let contextSend = Task { @MainActor in
                if let frontmostLine = await frontmostLineTask.value, connection.turn === marks {
                    try? await connection.sendContextText(frontmostLine)
                }
                if connection.pointFormat == .native, connection.stack == .openAIRealtime, let screenshotPixelSize, connection.turn === marks {
                    try? await connection.sendContextText(RealtimeOpenAppTool.screenshotSizeContextLine(pixels: screenshotPixelSize))
                }
                guard case .element(let candidate, let app)? = await pointerTask.value, connection.turn === marks else { return }
                marks.keyDownPointer = RealtimeScreenTarget(candidate: candidate, point: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY),
                                                            app: app, source: .underPointer)
                let appName = app.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName }
                try? await connection.sendContextText(RealtimeOpenAppTool.pointerContextLine(candidate: candidate, appName: appName))
            }
            for await pcmChunk in audioStream {
                try await connection.appendAudio(pcmChunk)
            }
            guard !Task.isCancelled else { return }
            // Bounded by the read's deadline, which started at key-down: already over
            // for any hold longer than ~0.3 s.
            await contextSend.value
            try await connection.endTurn()
            // Still thinking this long after the release, with not a word or a call:
            // say so. The turn keeps waiting; a late answer still plays.
            let watchdogSeconds = noReplyWatchdogSeconds
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(watchdogSeconds))
                guard !Task.isCancelled, let self, self.liveTurn === liveTurn, let liveTurn, let marks = liveTurn.marks,
                      marks.firstAudioUptime == nil, marks.toolCalls.isEmpty, JarvisNotch.shared.state == .thinking else { return }
                liveTurn.watchdogFired = true
                JarvisNotch.shared.handle(.noReply)
            }
            defer { watchdog.cancel() }
            _ = try await connection.turn.finished.value(timeoutSeconds: Self.turnTimeoutSeconds, timeoutKind: "turnTimeout")
            await liveTurn?.marks?.waitForFreshLook()
            if self.liveTurn === liveTurn { writeLiveTurnLine() }
        } catch {
            print("❌ realtime: turn failed: \(error)")
            // A barge-in already wrote this turn's line and owns the state now.
            guard self.liveTurn === liveTurn, liveTurn != nil else { return }
            writeLiveTurnLine(errorKind: (error as? VoiceBenchFailure)?.kind ?? VoiceBenchRun.errorKind(for: error, stage: selectedStack.rawValue))
            JarvisNotch.shared.handle(.turnEnded)
            onStateChange?(.idle)
            prewarm()
        }
    }

    private static func milliseconds(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
        guard let start, let end else { return nil }
        return Int(((end - start) * 1000).rounded())
    }

    /// Once per turn. Timings run from the key-up (`releasedUptime`), which is
    /// what the owner feels; the probe's origin is its last audio sent, which a
    /// fixture sends at the same instant.
    private func writeLiveTurnLine(bargedIn: Bool = false, errorKind: String? = nil) {
        guard let liveTurn else { return }
        self.liveTurn = nil
        var line = liveTurn.line
        let released = liveTurn.releasedUptime
        line.holdMs = Self.milliseconds(from: liveTurn.pressedUptime, to: released)
        line.bargedIn = bargedIn
        line.errorKind = errorKind
        lastLineErrorKind = errorKind
        line.watchdogFired = liveTurn.watchdogFired
        line.turnEndReason = errorKind != nil ? "error" : bargedIn ? "bargedIn"
            : (liveTurn.marks?.toolCalls.isEmpty == false ? "toolAnswered" : liveTurn.marks?.firstAudioUptime != nil ? "spoke" : "silent")
        line.notchTransitions = JarvisNotch.shared.transitions.filter { $0.uptime >= liveTurn.pressedUptime }.map { transition in
            ["state": transition.state, "ms": Self.milliseconds(from: released ?? liveTurn.pressedUptime, to: transition.uptime) ?? 0]
        }
        if let marks = liveTurn.marks {
            let firstDispatch = marks.dispatches.first
            line.firstAudioMs = Self.milliseconds(from: released, to: marks.firstAudioUptime)
            line.toolCalled = !marks.toolCalls.isEmpty
            line.toolName = marks.toolCalls.first?.name
            line.toolCallMs = Self.milliseconds(from: released, to: marks.toolCallUptime)
            line.harnessMs = firstDispatch?.harnessMilliseconds
            line.harnessStatus = firstDispatch?.result["status"] as? String
            line.harnessError = firstDispatch?.result["error"] as? String
            line.freshLook = marks.freshLookOutcome
            line.freshLookMs = marks.freshLookMilliseconds
            line.freshLookArrivedAfterSpeechStartMs = marks.freshLookArrivedAfterSpeechStartMs
            line.followUpFirstAudioMs = Self.milliseconds(from: marks.toolResultSentUptime, to: marks.followUpFirstAudioUptime)
            // No tool: the spoken result IS the first audio.
            line.releaseToSpokenResultMs = Self.milliseconds(
                from: released, to: marks.toolCalls.isEmpty ? marks.firstAudioUptime : marks.followUpFirstAudioUptime)
            line.turnDoneMs = bargedIn || errorKind != nil ? nil : Self.milliseconds(from: released, to: uptime)
            // Negative: a completion that arrived while the key was still held was credited to this turn.
            line.finishedMs = Self.milliseconds(from: marks.lastAudioSentUptime, to: marks.finishedUptime)
            line.staleCompletionsIgnored = marks.staleCompletionsIgnored
            line.eventTrail = marks.eventTrail
            line.claimedWithoutReceipt = RealtimeOpenAppTool.claimedWithoutReceipt(
                transcript: marks.transcript,
                okToolNames: Set(marks.decisions.filter { $0.dispatch?.harnessConfirmed == true }.map(\.call.name)))
            // One line per tool call to voice-decisions.log, joinable on turnId.
            RealtimeDecisionTrace.append(marks.decisions, turnID: line.turnID, stack: line.stack, source: probeMode ? "notchProbe" : "live",
                                         releasedUptime: released)
            if !probeMode { Self.appendTranscriptLine(for: marks, turnID: line.turnID, stack: line.stack, bargedIn: bargedIn) }
        }
        MeasurementLogFile.appendJSONLine(line.jsonObject, toFileNamed: liveTurnLogFileName)
        onLiveTurnLine?(line)
    }

    /// Waits (bounded, detached from the loop) for the owner's transcript to be
    /// complete — OpenAI's completed event, Gemini's quiet window — so the next
    /// press is never held up by it.
    private static func appendTranscriptLine(for marks: RealtimeTurnMarks, turnID: String, stack: String, bargedIn: Bool) {
        let date = Date()
        Task { @MainActor in
            let deadline = (marks.lastAudioSentUptime ?? ProcessInfo.processInfo.systemUptime) + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds
            let complete = RealtimeTranscriptLog.heardComplete(providerSaidDone: await marks.waitForHeard(until: deadline) != nil,
                                                               bargedIn: bargedIn, stack: stack)
            RealtimeTranscriptLog.append(RealtimeTranscriptLog.line(turnID: turnID, stack: stack, date: date, heard: marks.heardText,
                                                                    heardComplete: complete, said: marks.transcript, decisions: marks.decisions))
        }
    }

    private func startMic(targetSampleRate: Int, continuation: AsyncStream<Data>.Continuation) throws {
        let inputNode = micEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0),
                             block: Self.makeTapBlock(targetSampleRate: targetSampleRate, continuation: continuation))
        micEngine.prepare()
        try micEngine.start()
    }

    /// Built outside the main actor: the tap runs on the audio thread, and a
    /// main-isolated closure there is a runtime isolation trap waiting to fire.
    private nonisolated static func makeTapBlock(
        targetSampleRate: Int, continuation: AsyncStream<Data>.Continuation
    ) -> AVAudioNodeTapBlock {
        let converter = BuddyPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))
        return { buffer, _ in
            if let pcmData = converter.convertToPCM16Data(from: buffer) { continuation.yield(pcmData) }
            // The notch's bars: one RMS per buffer (~21 ms at 48 kHz), drawn on main.
            if let channel = buffer.floatChannelData?[0] {
                let rms = JarvisNotchLevel.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                Task { @MainActor in JarvisNotch.shared.setLevel(rms: rms) }
            }
        }
    }

    private func stopMic() {
        micEngine.stop()
        micEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: Playback

    private func play(_ pcm16Data: Data) {
        let frameCount = pcm16Data.count / 2
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let floatSamples = buffer.floatChannelData![0]
        pcm16Data.withUnsafeBytes { rawBytes in
            for frameIndex in 0..<frameCount {
                let sample = Int16(littleEndian: rawBytes.loadUnaligned(fromByteOffset: frameIndex * 2, as: Int16.self))
                floatSamples[frameIndex] = Float(sample) / 32_768
            }
        }
        if !playbackEngine.isRunning {
            do { try playbackEngine.start() } catch { print("❌ realtime: playback failed to start: \(error)"); return }
        }
        playerNode.scheduleBuffer(buffer)
        replyAudioEndsUptime = max(uptime, replyAudioEndsUptime) + Double(frameCount) / playbackFormat.sampleRate
        if !playerNode.isPlaying {
            playerNode.play()
            onStateChange?(.responding)
        }
    }

    /// Silent when the output device is muted.
    private func playTick(_ tick: JarvisNotchTick) {
        guard !JarvisNotchTick.systemOutputIsMuted(), let buffer = tickBuffers[tick] else { return }
        if !playbackEngine.isRunning {
            do { try playbackEngine.start() } catch { print("❌ realtime: playback failed to start: \(error)"); return }
        }
        tickNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !tickNode.isPlaying { tickNode.play() }
    }

    private func stopPlayback() {
        playerNode.stop()
        replyAudioEndsUptime = 0
    }

    func stop() {
        stopMic()
        stopPlayback()
        playbackEngine.stop()
        connection?.close()
        connection = nil
    }
}

/// One live push-to-talk turn, as logged. Counts and timings only — no field
/// here can carry what was said. Names match `--voice-tool-probe`'s marks where
/// they mean the same thing; `releaseToSpokenResultMs` is the probe's
/// `totalToFirstSpokenResultMs`, and on a turn with no tool it is the first audio.
nonisolated struct RealtimeLiveTurnLine {
    let stack: String
    let turnID: String
    let sessionWasWarm: Bool
    var sessionSetupMs: Int?
    var holdMs: Int?
    var firstAudioMs: Int?
    var toolCalled = false
    var toolName: String?
    var toolCallMs: Int?
    var harnessMs: Int?
    var harnessStatus: String?
    var harnessError: String?
    /// "attached", a refusal code, or nil when no look was attempted.
    var freshLook: String?
    var freshLookMs: Int?
    /// Look complete minus the spoken result's first audio.
    var freshLookArrivedAfterSpeechStartMs: Int?
    var followUpFirstAudioMs: Int?
    var releaseToSpokenResultMs: Int?
    var turnDoneMs: Int?
    var bargedIn = false
    var errorKind: String?
    /// spoke | toolAnswered | silent | error | bargedIn — how it really ended.
    var turnEndReason: String?
    /// The no-reply watchdog showed "No reply" before that.
    var watchdogFired = false
    /// When `finished` settled, ms from the release; negative is a completion credited early.
    var finishedMs: Int?
    var staleCompletionsIgnored = 0
    /// Set when this press cut off the previous turn — its line still open or its
    /// answer still playing — even if that line was already written.
    var bargedInPreviousTurnID: String?
    var previousAudioWasPlaying = false
    /// Provider event names from `beginTurn`, ms from the release (negative before it).
    var eventTrail: [String] = []
    /// Each notch state this turn reached, ms from the key-up (negative before it).
    /// Later ones (a hold running out) are in notch-drawn.log under this turnId.
    var notchTransitions: [[String: Any]] = []
    /// Counts-only: the model said done / pointed / clicked with no ok result
    /// of that kind this turn (`RealtimeOpenAppTool.claimedWithoutReceipt`).
    var claimedWithoutReceipt = false

    init(stack: String, turnID: String, sessionWasWarm: Bool) {
        self.stack = stack
        self.turnID = turnID
        self.sessionWasWarm = sessionWasWarm
    }

    /// Every key is always present, null when unmeasured — an absent key and a
    /// turn that never got that far must not look alike.
    var jsonObject: [String: Any] {
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        return [
            "kind": "turn", "stack": stack, "turnId": turnID,
            "sessionWasWarm": sessionWasWarm, "sessionSetupMs": value(sessionSetupMs),
            "holdMs": value(holdMs), "firstAudioMs": value(firstAudioMs),
            "toolCalled": toolCalled, "toolName": value(toolName), "toolCallMs": value(toolCallMs),
            "harnessMs": value(harnessMs), "harnessStatus": value(harnessStatus), "harnessError": value(harnessError),
            "freshLook": value(freshLook), "freshLookMs": value(freshLookMs),
            "freshLookArrivedAfterSpeechStartMs": value(freshLookArrivedAfterSpeechStartMs),
            "followUpFirstAudioMs": value(followUpFirstAudioMs), "releaseToSpokenResultMs": value(releaseToSpokenResultMs),
            "turnDoneMs": value(turnDoneMs), "bargedIn": bargedIn, "errorKind": value(errorKind),
            "turnEndReason": value(turnEndReason), "watchdogFired": watchdogFired, "finishedMs": value(finishedMs), "staleCompletionsIgnored": staleCompletionsIgnored,
            "bargedInPreviousTurnId": value(bargedInPreviousTurnID), "previousAudioWasPlaying": previousAudioWasPlaying,
            "eventTrail": eventTrail, "notchTransitions": notchTransitions, "claimedWithoutReceipt": claimedWithoutReceipt
        ]
    }
}

/// `~/Library/Logs/Clicky/voice-transcripts.log`: what the owner said and what
/// the model said, one JSON line per LIVE turn (never a probe or the bench),
/// with the turn's tool calls. Owner's ruling 2026-09-30: the owner's words are
/// kept, LOCAL ONLY — 0600, rotated at 5 MB, never sent anywhere and never
/// copied into a counts-only log (voice-live.log, voice-decisions.log join it
/// on turnId). `heard` is the provider's input transcription, `said` its
/// transcript of the model's audio; `heardComplete` false means the provider
/// never said it was done (a barged-in turn, a dropped transcription).
nonisolated enum RealtimeTranscriptLog {
    static let fileName = "voice-transcripts.log"

    static func line(turnID: String, stack: String, date: Date, heard: String, heardComplete: Bool, said: String,
                     decisions: [RealtimeToolDecision]) -> [String: Any] {
        [
            "kind": "transcript", "turnId": turnID, "stack": stack,
            "timestamp": ISO8601DateFormatter().string(from: date),
            "heard": heard, "heardComplete": heardComplete, "said": said,
            "toolCalls": decisions.map { decision -> [String: Any] in
                ["tool": decision.call.name, "args": RealtimeDecisionTrace.loggedArguments(for: decision.call),
                 "error": (decision.dispatch?.result["error"] as? String) ?? NSNull()]
            }
        ]
    }

    /// Gemini's pieces carry no item id: once the owner presses again, a
    /// barged turn's late pieces land in the new turn and are dropped there
    /// (`RealtimeVoiceConnection.geminiStaleHeardPieceSeconds`), so a quiet
    /// window on the old turn proves nothing. OpenAI routes by item id.
    static func heardComplete(providerSaidDone: Bool, bargedIn: Bool, stack: String) -> Bool {
        providerSaidDone && !(bargedIn && stack == VoiceStackChoice.geminiLive.rawValue)
    }

    static func append(_ line: [String: Any], in directory: URL = MeasurementLogFile.directoryURL) {
        MeasurementLogFile.appendJSONLine(line, toFileNamed: fileName, rotatingAtBytes: HarnessServer.auditLogRotationBytes, in: directory)
    }
}

/// Resumes its continuation once; later answers are dropped (`RealtimeVoiceSession.value(within:_:)`).
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
