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
    /// Runner only (`--scenario-run`): `feedProbeAudio` replaces the mic and
    /// nothing else — capture, guard, context lines and after-reply all run as
    /// live. Silent, and its turns stay out of the owner's transcript log.
    var fixtureMic = false {
        didSet { playerNode.volume = fixtureMic ? 0 : 1; tickNode.volume = fixtureMic ? 0 : 1 }
    }
    /// Runner only: the finished turn's marks (its tool decisions), beside its line.
    var onLiveTurnMarks: ((RealtimeTurnMarks?) -> Void)?
    /// Probe only: the stack, without writing the owner's picker.
    var stackOverride: VoiceStackChoice?
    /// Probe only: each line as it is written, and to its own file — the
    /// owner's voice-live.log stays the owner's.
    var onLiveTurnLine: ((RealtimeLiveTurnLine) -> Void)?
    var liveTurnLogFileName = RealtimeVoiceSession.liveLogFileName
    var estimatedOpenAIUSD: Double { connection?.estimatedOpenAIUSD ?? 0 }

    // MARK: Agent loop state (`do_task`)

    /// The running task, if any: one at a time; a new do_task replaces it.
    private(set) var agentLoop: AgentLoop?
    private var agentTask: Task<Void, Never>?
    private let agentModel = AgentLoopModel()
    /// Set when a press stopped a task: the next turn's context says where.
    private var agentStoppedLine: String?
    /// The last task (2026-10-08): its status goes with every owner turn while it
    /// runs, waits on a question, or ended within `askOwnerAnswerWindowSeconds`;
    /// paused on ask_owner, the owner's answer resumes it.
    struct TaskRecord {
        let loop: AgentLoop
        var endedUptime: TimeInterval?
        var stoppedByPress = false
    }
    private var lastTask: TaskRecord?
    /// The system turns the running task spoke, so its words can be reported.
    private var agentSpokenTurns: [RealtimeTurnMarks] = []
    /// Runner only: the task's outcome, its tool decisions and what was spoken.
    var onAgentLoopFinished: ((AgentLoopReport) -> Void)?

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
    /// The pointer close-up's crop, OCR and crosshair: ~0.1 s for a 320 px crop; past this it is skipped.
    nonisolated static let pointerCloseUpDeadlineSeconds: Double = 0.35

    /// `read`'s answer, or nil once `seconds` pass — whichever comes first. The
    /// read cannot be cancelled (a blocked AX call returns when it returns); a
    /// late answer is dropped. Both run on GCD, not the Swift cooperative pool:
    /// a blocking read there holds a pool thread, and a timer task queued behind
    /// busy pool threads lost the race to a 2 s read under a 0.1 s deadline (test run 2026-09-30).
    /// The read runs on its OWN thread (review 2026-09-30): a stuck AX read
    /// never holds a GCD worker the deadline's timer needs.
    /// The hand-over at key-down: a password being typed is never photographed.
    nonisolated static func photographsThisTurn(_ secureInput: SecureInputState) -> Bool { !secureInput.isOn }

    nonisolated static func value<T: Sendable>(within seconds: Double, _ read: @escaping @Sendable () -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            Thread { once.resume(read()) }.start()
            // The deadline gets its own thread too: on the shared pool it waited 2 s behind a loaded test run (2026-10-02).
            Thread { Thread.sleep(forTimeInterval: seconds); once.resume(nil) }.start()
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
        // The pointer close-up's OCR, off main: cold it overruns its key-down deadline.
        DispatchQueue.global(qos: .utility).async { ScreenOCR.warmUp() }
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
        connection.onDoTask = { [weak self] goal, heard, startBundle in
            self?.startAgentLoop(goal: goal, heard: heard, startBundle: startBundle)
                ?? ["ok": false, "status": NSNull(), "error": "noSession", "message": "the task runner is not available"]
        }
        connection.isAgentLoopRunning = { [weak self] in self?.agentLoop?.isRunning == true }
    }

    // MARK: Agent loop

    /// The owner's words of a task that ended asking them something: their
    /// answer starts a new task, judged by both turns' words (theirs only).
    /// Re-review of 2e45939 (A): it was cleared only by the next do_task, so a
    /// task minutes later was judged by an older task's words, and a question
    /// answered by another question piled the words up. Now only the press right
    /// after the question answers it (`askedOwnerAfterPress`), and the words are
    /// the original request plus that one answer (`taskWords`).
    struct AskedOwner: Equatable {
        /// The original request's words: never an answer's.
        var heard: String
        var uptime: TimeInterval
        /// Presses since the question: the first is the answer turn.
        var pressesSince = 0
    }
    private var askedOwner: AskedOwner?
    nonisolated static let askOwnerAnswerWindowSeconds: TimeInterval = 300

    nonisolated static func askedOwnerAfterPress(_ asked: AskedOwner?) -> AskedOwner? {
        guard var asked, asked.pressesSince == 0 else { return nil }
        asked.pressesSince = 1
        return asked
    }

    /// The words a new task is judged by, and the root kept if it asks again.
    nonisolated static func taskWords(heard: String, asked: AskedOwner?, now: TimeInterval) -> (words: String, root: String) {
        guard let asked, now - asked.uptime <= askOwnerAnswerWindowSeconds else { return (heard, heard) }
        return (asked.heard + " " + heard, asked.heard)
    }
    /// Agent system turns, one after another (OpenAI refuses a second
    /// `response.create` while one is answering).
    private var agentSpeech: Task<Void, Never>?
    private var agentSpeechBusy = false

    /// do_task's answer, at once; the loop runs on and speaks for itself.
    /// `heard`: the owner's words of the turn that called it.
    /// `startBundle`: the app in front at the owner's key-down — where the task began.
    private func startAgentLoop(goal: String, heard: String, startBundle: String?) -> [String: Any] {
        agentTask?.cancel()
        // The old task's lines must not speak over the new one.
        agentSpeech?.cancel()
        let (words, root) = Self.taskWords(heard: heard, asked: askedOwner, now: uptime)
        // The press right after a question, inside its window, answers it: the SAME task resumes.
        let answering = askedOwner.map { uptime - $0.uptime <= Self.askOwnerAnswerWindowSeconds } ?? false
        askedOwner = nil
        let paused = lastTask?.loop.pausedAsk != nil ? lastTask?.loop : nil
        let resuming = answering && paused != nil
        // ponytail: an unrelated request in the very answer turn resumes too (the loop sees the
        // owner's words and may end it); a flag on do_task would split them if it bites.
        let loop: AgentLoop
        if resuming, let paused {
            loop = paused
        } else {
            loop = AgentLoop.live(heard: words, startBundle: startBundle, harnessAnswer: harnessAnswer, model: agentModel) { [weak self] line in
                self?.enqueueAgentSpeech(line, final: false)
            }
        }
        let setAside = paused != nil && !resuming
        lastTask = TaskRecord(loop: loop)
        agentLoop = loop
        agentSpokenTurns = []
        agentTask = Task { @MainActor [weak self] in
            let outcome = resuming ? await loop.resume(answer: heard, words: words) : await loop.run(goal: goal, heard: words)
            guard let self else { return }
            if self.lastTask?.loop === loop { self.lastTask?.endedUptime = self.uptime }
            if case .askOwner = outcome { self.askedOwner = AskedOwner(heard: root, uptime: self.uptime) }
            if let final = AgentLoop.finalLine(outcome, goal: goal, lastProgress: loop.lastProgress, step: loop.step), !Task.isCancelled {
                await self.enqueueAgentSpeech(final, final: true)?.value
            }
            if self.agentLoop === loop { self.agentLoop = nil }
            await self.reportAgentLoop(loop, outcome: outcome)
        }
        let status = AgentLoop.statusLine(goal: loop.goal.isEmpty ? goal : loop.goal, state: .running, step: loop.step,
                                          receipts: loop.receipts, artifacts: loop.artifacts)
        return ["ok": true, "status": resuming ? "resumed" : "started", "error": NSNull(), "task": status,
                "message": (resuming ? "the paused task has resumed with the owner's answer, from step \(loop.step); its earlier steps stand as "
                                + "the task status shows. "
                            : "a new task has started; no step of it has run yet. "
                                + (setAside ? "the earlier task that was waiting for the owner's answer was set aside; say so in a few words. " : ""))
                    + "progress and the outcome come as system lines: say only a few words now, and claim nothing the status does not show"]
    }

    /// The task status line for this owner turn, nil when no task is recent.
    private func agentStatusLine() -> String? {
        guard let record = lastTask else { return nil }
        if let ended = record.endedUptime, uptime - ended > Self.askOwnerAnswerWindowSeconds {
            lastTask = nil
            return nil
        }
        let loop = record.loop
        let state = AgentLoop.taskState(isRunning: loop.isRunning, stoppedByPress: record.stoppedByPress, outcome: loop.lastOutcome,
                                        pausedQuestion: loop.pausedAsk?.question)
        return AgentLoop.statusLine(goal: loop.goal, state: state, step: loop.step, receipts: loop.receipts, artifacts: loop.artifacts)
    }

    /// The owner pressed: the running task stops before its next tool call,
    /// and any line it still meant to say is dropped. Returns the step a
    /// RUNNING task stopped at.
    private func stopAgentLoop() -> Int? {
        let running = agentLoop.flatMap { $0.isRunning ? $0.step : nil }
        if running != nil, lastTask?.loop === agentLoop { lastTask?.stoppedByPress = true }
        agentTask?.cancel()
        agentSpeech?.cancel()
        return running
    }

    /// What an agent line does now (pure, tested). Cancelled: dropped. The
    /// owner's turn or reply audio still going: a progress line is dropped,
    /// the final line waits (15 s at most). Lines never overlap: each waits on
    /// the one before it (`enqueueAgentSpeech`).
    enum AgentSpeechStep: Equatable { case speak, wait, drop }

    nonisolated static func agentSpeechStep(cancelled: Bool, final: Bool, ownerTurnActive: Bool, replyPlaying: Bool,
                                            pastDeadline: Bool) -> AgentSpeechStep {
        if cancelled { return .drop }
        guard ownerTurnActive || replyPlaying else { return .speak }
        return final && !pastDeadline ? .wait : .drop
    }

    /// Queued behind the previous agent line; a progress line arriving while
    /// one is in flight is dropped rather than queued.
    @discardableResult
    private func enqueueAgentSpeech(_ text: String, final: Bool) -> Task<Void, Never>? {
        if !final, agentSpeechBusy { return nil }
        let previous = agentSpeech
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.speakForAgent(text, final: final)
        }
        agentSpeech = task
        return task
    }

    /// A speech-only system turn, only between the owner's turns, and waited
    /// on until answered so the next line never collides with it.
    private func speakForAgent(_ text: String, final: Bool) async {
        agentSpeechBusy = true
        defer { agentSpeechBusy = false }
        let deadline = uptime + (final ? 15 : 0)
        // A cancelled sleep returns at once; the next pass then drops the line, never spins.
        waiting: while true {
            switch Self.agentSpeechStep(cancelled: Task.isCancelled, final: final, ownerTurnActive: liveTurn != nil,
                                        replyPlaying: isReplyAudioPlaying, pastDeadline: uptime >= deadline) {
            case .drop: return
            case .wait: try? await Task.sleep(for: .milliseconds(200))
            case .speak: break waiting
            }
        }
        guard let connection = try? await readyConnection(), liveTurn == nil, !Task.isCancelled else { return }
        do {
            try await connection.beginSystemTurn(text: text, variant: RealtimeOpenAppTool.systemTurnVariant(for: connection.stack),
                                                 speechOnly: true)
            let turn = connection.turn
            agentSpokenTurns.append(turn)
            _ = try? await turn.finished.value(timeoutSeconds: 20, timeoutKind: "agentSpeech")
            // The audio it scheduled plays out before the next line may start.
            while isReplyAudioPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        } catch {
            print("🤖 agent loop: system turn failed: \(error)")
        }
    }

    private func reportAgentLoop(_ loop: AgentLoop, outcome: AgentLoop.Outcome) async {
        guard let onAgentLoopFinished else { return }
        onAgentLoopFinished(AgentLoopReport(outcome: outcome, steps: loop.step, decisions: loop.decisions,
                                            spoken: agentSpokenTurns.map(\.transcript).joined(separator: " ")))
    }

    // MARK: Push-to-talk

    func pressed() {
        // A new request takes the last pointer and drawing away (its audio end is still known here).
        ElementPointer.hide()
        AnnotationOverlay.hide()
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
        // The owner's press stops a running task; this turn is told where.
        if let stoppedAt = stopAgentLoop() { agentStoppedLine = AgentLoop.stoppedContextLine(step: stoppedAt) }
        askedOwner = Self.askedOwnerAfterPress(askedOwner)
        JarvisNotch.shared.currentTurnID = line.turnID
        JarvisNotch.shared.handle(.hotkeyDown)
        playTick(.press)
        connection?.supersedeForPress()
        turnTask?.cancel()
        audioContinuation?.finish()

        let (audioStream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        audioContinuation = continuation
        do {
            if !probeMode && !fixtureMic { try startMic(targetSampleRate: selectedStack.inputSampleRate, continuation: continuation) }
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
        if !probeMode && !fixtureMic { stopMic() }
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
            // Key-down: a password being typed is the owner's (the hand-over) -
            // nothing is photographed, and the model is told why.
            let secureInput = probeMode ? SecureInputState.off : SecureInputState.current()
            let screenshotTask = Task { @MainActor () -> CompanionScreenCapture? in
                guard !probeMode else {
                    try await Task.sleep(for: .milliseconds(Self.probeCaptureStandInMilliseconds))
                    return nil
                }
                guard Self.photographsThisTurn(secureInput) else { return nil }
                return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen)
            }
            // The app in front, from structure — the harness's own read, off main
            // (cross-process AX), bounded from key-down. Its name only; never
            // Clicky's own panel.
            let frontmostLineTask = Task { () -> (line: String?, bundle: String?)? in
                guard !probeMode else { return nil }
                return await Self.value(within: Self.frontmostReadDeadlineSeconds) { () -> (line: String?, bundle: String?)? in
                    guard let application = AccessibilityTreeWalker.focusedApplication(),
                          !HarnessServer.isHarnessItself(bundleIdentifier: application.bundleIdentifier) else { return nil }
                    return (RealtimeOpenAppTool.frontmostAppContextLine(appName: application.localizedName), application.bundleIdentifier)
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
            let screenshotResult = await screenshotTask.result
            // The owner's pointer, close up (owner 2026-10-05: "let the model know precisely
            // what and where I am targeting"): a crop of this guarded screenshot with a
            // crosshair, and the words OCR reads under it - never over a password box or
            // Clicky itself. Sent BEFORE the screenshot, so the screenshot stays the last
            // image (Gemini Live reads its video frames as a stream).
            let pointerHit = await pointerTask.value
            var pointerCloseUp: ScreenOCR.PointerCloseUp?
            if let screenshot = try? screenshotResult.get(), RealtimeOpenAppTool.keyDownPointerTarget(hit: pointerHit, mouse: mouse) != nil {
                let (jpeg, display) = (screenshot.imageData, screenshot.displayFrame)
                let size = CGSize(width: screenshot.screenshotWidthInPixels, height: screenshot.screenshotHeightInPixels)
                pointerCloseUp = await Self.value(within: Self.pointerCloseUpDeadlineSeconds) {
                    ScreenOCR.pointerCloseUp(screenshotJPEG: jpeg, mouse: mouse, display: display, imagePixels: size)
                }
            }
            if let screenshot = try? screenshotResult.get() {
                if let pointerCloseUp { try await connection.sendScreenshot(pointerCloseUp.jpeg) }
                try await connection.sendScreenshot(screenshot.imageData)
                screenshotDisplayFrame = screenshot.displayFrame
                screenshotPixelSize = CGSize(width: screenshot.screenshotWidthInPixels, height: screenshot.screenshotHeightInPixels)
            }
            var withheld: ScreenSecretGuard.Report?
            if case .failure(let error) = screenshotResult { withheld = (error as? ScreenSecretGuard.Withheld)?.report }
            let guardLine = RealtimeOpenAppTool.credentialGuardContextLine(secureInput: secureInput, withheld: withheld)
            // A press since this one owns the connection now: its `beginTurn` must not be replaced by ours.
            guard !Task.isCancelled else { return }
            // A press while the last answer still played cut words off it: those
            // words cannot be what a plain "yes" agrees to (`confirmedByPlainYes`).
            try await connection.beginTurn(previousReplyWasHeard: liveTurn?.previousReplyWasHeard == true)
            let marks = connection.turn
            liveTurn?.marks = marks
            marks.screenshotDisplayFrame = screenshotDisplayFrame
            marks.screenshotPixelSize = screenshotPixelSize
            marks.screenshotGuard = (try? screenshotResult.get())?.secretGuard?.outcome ?? withheld?.outcome
            // Beside the audio, never ahead of it; before the release, so on Gemini
            // it stays inside the owner's activity. Not into a turn that replaced this one.
            let stoppedLine = agentStoppedLine
            agentStoppedLine = nil
            let taskStatusLine = agentStatusLine()
            let closeUp = pointerCloseUp
            let contextSend = Task { @MainActor in
                if let guardLine, connection.turn === marks {
                    try? await connection.sendContextText(guardLine)
                }
                if let stoppedLine, connection.turn === marks {
                    try? await connection.sendContextText(stoppedLine)
                }
                if let taskStatusLine, connection.turn === marks {
                    try? await connection.sendContextText(taskStatusLine)
                }
                let front = await frontmostLineTask.value
                marks.keyDownFrontBundle = front?.bundle
                if let frontmostLine = front?.line, connection.turn === marks {
                    try? await connection.sendContextText(frontmostLine)
                }
                if connection.pointFormat == .native, connection.stack == .openAIRealtime, let screenshotPixelSize, connection.turn === marks {
                    try? await connection.sendContextText(RealtimeOpenAppTool.screenshotSizeContextLine(pixels: screenshotPixelSize))
                }
                // Where, in the tools' own space; what AX names there; the words under it.
                guard connection.turn === marks, let pointer = RealtimeOpenAppTool.keyDownPointerTarget(hit: pointerHit, mouse: mouse) else { return }
                marks.keyDownPointer = pointer
                let appName = pointer.app.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName }
                let position = screenshotDisplayFrame.flatMap {
                    RealtimeOpenAppTool.pointerPosition(mouse: mouse, display: $0, format: connection.pointFormat, stack: connection.stack,
                                                        pixels: screenshotPixelSize)
                }
                if let line = RealtimeOpenAppTool.ownerPointerContextLine(candidate: pointer.candidate, appName: appName, position: position,
                                                                          wordsUnderPointer: closeUp?.wordsUnderPointer, closeUpSent: closeUp != nil) {
                    try? await connection.sendContextText(line)
                }
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
            if !probeMode, let liveTurn, self.liveTurn === liveTurn, let marks = liveTurn.marks, connection.turn === marks, !marks.supersededByPress {
                await afterReply(liveTurn, marks: marks, connection: connection)
            }
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

    /// Once the reply is done (hands design items 9 and 10): a claim no receipt
    /// backs is corrected aloud through a system turn, and a reply that told
    /// the owner to click something nobody pointed at gets the pointer — never
    /// a word, and nothing when the live screen does not name it exactly once.
    private func afterReply(_ liveTurn: LiveTurn, marks: RealtimeTurnMarks, connection: RealtimeVoiceConnection) async {
        let answer = harnessAnswer
        let outcome = await RealtimeOpenAppTool.afterReply(
            transcript: marks.transcript, decisions: marks.decisions,
            sendCorrection: { correction in
                try? await connection.beginSystemTurn(text: correction, variant: RealtimeOpenAppTool.systemTurnVariant(for: connection.stack))
            },
            pointWhenTelling: {
                await RealtimeOpenAppTool.pointWhenTelling(
                    reply: marks.transcript, decisions: marks.decisions, answer: answer,
                    screens: NSScreen.screens.map(\.frame), screenshotDisplay: marks.screenshotDisplayFrame,
                    stillCurrent: { [weak self] in self?.liveTurn === liveTurn })
            })
        liveTurn.line.receiptCorrectionSent = outcome.correctionSent
        liveTurn.line.pointedWhenTelling = outcome.pointed
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
            line.internalWordsSpoken = RealtimeOpenAppTool.internalWordsSpoken(marks.transcript).count
            // One line per tool call to voice-decisions.log, joinable on turnId.
            RealtimeDecisionTrace.append(marks.decisions, turnID: line.turnID, stack: line.stack, source: probeMode ? "notchProbe" : fixtureMic ? "scenarioRun" : "live",
                                         releasedUptime: released)
            if !probeMode && !fixtureMic { Self.appendTranscriptLine(for: marks, turnID: line.turnID, stack: line.stack, bargedIn: bargedIn) }
        }
        MeasurementLogFile.appendJSONLine(line.jsonObject, toFileNamed: liveTurnLogFileName)
        onLiveTurnLine?(line)
        onLiveTurnMarks?(liveTurn.marks)
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
        agentTask?.cancel()
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
    /// Counts-only: tool names, error codes or system lines said aloud
    /// (`RealtimeOpenAppTool.internalWordsSpoken`).
    var internalWordsSpoken = 0
    /// That claim was corrected aloud (`RealtimeOpenAppTool.receiptCorrection`).
    var receiptCorrectionSent = false
    /// The reply told the owner to click something unpointed: pointed | notFound | noApp | an error code; nil when it did not.
    var pointedWhenTelling: String?

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
            "eventTrail": eventTrail, "notchTransitions": notchTransitions, "claimedWithoutReceipt": claimedWithoutReceipt,
            "internalWordsSpoken": internalWordsSpoken,
            "receiptCorrectionSent": receiptCorrectionSent, "pointedWhenTelling": value(pointedWhenTelling)
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

/// What a finished task did, for the scenario runner: its outcome, its tool
/// calls as the voice turn records them, and the words its system turns spoke.
struct AgentLoopReport {
    let outcome: AgentLoop.Outcome
    let steps: Int
    let decisions: [RealtimeToolDecision]
    let spoken: String
}
