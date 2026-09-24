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
            continuation.finish()
            onStateChange?(.idle)
            return
        }
        onStateChange?(.listening)
        turnTask = Task { [weak self] in await self?.runTurn(audioStream) }
    }

    func released() {
        stopMic()
        audioContinuation?.finish()
        audioContinuation = nil
        onStateChange?(.processing)
    }

    /// The mic is already running while this connects and captures; its audio
    /// waits in the stream and is sent in order once the turn is open.
    private func runTurn(_ audioStream: AsyncStream<Data>) async {
        do {
            let screenshotTask = Task { @MainActor in
                try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen)
            }
            let connection = try await readyConnection()
            if let screenshot = try? await screenshotTask.value {
                try await connection.sendScreenshot(screenshot.imageData)
            }
            try await connection.beginTurn()
            for await pcmChunk in audioStream {
                try await connection.appendAudio(pcmChunk)
            }
            guard !Task.isCancelled else { return }
            try await connection.endTurn()
        } catch {
            print("❌ realtime: turn failed: \(error)")
            onStateChange?(.idle)
            prewarm()
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
