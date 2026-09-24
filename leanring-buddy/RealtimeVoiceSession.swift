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
//  failed or was barged in on, so a silent turn is never an invisible one.
//
//  Coded, not verified by a run: nothing here can be exercised headlessly (it
//  needs the owner's hotkey and mic). `--voice-tool-probe` verifies the shared
//  connection and tool path with a fixture instead of the mic.
//

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

    private final class LiveTurn {
        var line: RealtimeLiveTurnLine
        let pressedUptime: TimeInterval
        var releasedUptime: TimeInterval?
        /// The connection's marks for this turn, once `beginTurn` created them.
        var marks: RealtimeTurnMarks?
        init(line: RealtimeLiveTurnLine, pressedUptime: TimeInterval) {
            self.line = line
            self.pressedUptime = pressedUptime
        }
    }

    static let liveLogFileName = "voice-live.log"
    /// The probe's: a tool call may wait on a 60 s confirmation ticket.
    static let turnTimeoutSeconds: Double = 90
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceStackChoice.outputSampleRate), channels: 1, interleaved: false
    )!

    /// listening on key-down, processing on key-up, responding at first audio, idle when the turn ends.
    var onStateChange: ((CompanionVoiceState) -> Void)?

    init(harnessAnswer: @escaping @Sendable (String) -> String) {
        self.harnessAnswer = harnessAnswer
        playbackEngine.attach(playerNode)
        // The mixer resamples 24 kHz to the device rate.
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
    }

    private var selectedStack: VoiceStackChoice { VoiceStackChoice.stored(in: .standard) }

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
        // Barge-in: a new press silences whatever is still being said.
        writeLiveTurnLine(bargedIn: true)
        let stack = selectedStack
        liveTurn = LiveTurn(
            line: RealtimeLiveTurnLine(stack: stack.rawValue, turnID: UUID().uuidString,
                                       sessionWasWarm: connection.map { $0.isOpen && $0.stack == stack } ?? false),
            pressedUptime: uptime)
        stopPlayback()
        connection?.cancelResponse()
        turnTask?.cancel()
        audioContinuation?.finish()

        let (audioStream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        audioContinuation = continuation
        do {
            try startMic(targetSampleRate: selectedStack.inputSampleRate, continuation: continuation)
        } catch {
            print("❌ realtime: mic failed to start: \(error)")
            writeLiveTurnLine(errorKind: "micFailed")
            continuation.finish()
            onStateChange?(.idle)
            return
        }
        onStateChange?(.listening)
        turnTask = Task { [weak self] in await self?.runTurn(audioStream) }
    }

    func released() {
        liveTurn?.releasedUptime = uptime
        stopMic()
        audioContinuation?.finish()
        audioContinuation = nil
        onStateChange?(.processing)
    }

    /// The mic is already running while this connects and captures; its audio
    /// waits in the stream and is sent in order once the turn is open.
    private func runTurn(_ audioStream: AsyncStream<Data>) async {
        let liveTurn = self.liveTurn
        do {
            let screenshotTask = Task { @MainActor in
                try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen)
            }
            let setupStart = uptime
            let connection = try await readyConnection()
            if liveTurn?.line.sessionWasWarm == false { liveTurn?.line.sessionSetupMs = Self.milliseconds(from: setupStart, to: uptime) }
            if let screenshot = try? await screenshotTask.value {
                try await connection.sendScreenshot(screenshot.imageData)
            }
            try await connection.beginTurn()
            liveTurn?.marks = connection.turn
            for await pcmChunk in audioStream {
                try await connection.appendAudio(pcmChunk)
            }
            guard !Task.isCancelled else { return }
            try await connection.endTurn()
            _ = try await connection.turn.finished.value(timeoutSeconds: Self.turnTimeoutSeconds, timeoutKind: "turnTimeout")
            await liveTurn?.marks?.waitForFreshLook()
            if self.liveTurn === liveTurn { writeLiveTurnLine() }
        } catch {
            print("❌ realtime: turn failed: \(error)")
            // A barge-in already wrote this turn's line and owns the state now.
            guard self.liveTurn === liveTurn, liveTurn != nil else { return }
            writeLiveTurnLine(errorKind: (error as? VoiceBenchFailure)?.kind ?? VoiceBenchRun.errorKind(for: error, stage: selectedStack.rawValue))
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
        }
        MeasurementLogFile.appendJSONLine(line.jsonObject, toFileNamed: Self.liveLogFileName)
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
        if !playerNode.isPlaying {
            playerNode.play()
            onStateChange?(.responding)
        }
    }

    private func stopPlayback() {
        playerNode.stop()
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
            "turnDoneMs": value(turnDoneMs), "bargedIn": bargedIn, "errorKind": value(errorKind)
        ]
    }
}
