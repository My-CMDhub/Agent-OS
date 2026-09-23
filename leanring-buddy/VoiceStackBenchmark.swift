//
//  VoiceStackBenchmark.swift
//  leanring-buddy
//
//  Measurement only. `--voice-bench` times the three candidate voice stacks from
//  this Mac, on the same audio and the same screenshot, so the step-B choice is
//  made on numbers instead of vendor latency claims:
//
//    (P) pipeline:          Deepgram Nova-3 streaming STT -> Claude Haiku 4.5
//                           (image + transcript) -> OpenAI gpt-4o-mini-tts
//    (S) speech-to-speech:  Gemini Live API, gemini-3.1-flash-live-preview
//    (R) speech-to-speech:  OpenAI Realtime API, gpt-realtime-mini
//
//  Every clock start at the same instant — the last audio chunk leaving this
//  machine, i.e. the moment a push-to-talk user lets go — and stop at the first
//  byte of audio that could be played. Nothing is ever played: the bench never
//  touches an audio device.
//
//  Spends API credit on four providers, so it is only ever run by hand. Every
//  run appends one JSON line to ~/Library/Logs/Clicky/voice-bench.log carrying
//  timings and counts, never the words spoken or answered. The words — what each
//  stack heard and said, so the owner can judge quality as well as speed — go to
//  a separate owner-only (0600) file per bench, voice-bench-answers-<benchId>.jsonl.
//

import Foundation

// MARK: - WAV fixtures

/// Raw PCM from one of the committed fixtures in `scripts/voice-fixtures`.
nonisolated struct VoiceBenchPCMClip: Equatable {
    let sampleRate: Int
    let channelCount: Int
    let bitsPerSample: Int
    let pcmData: Data

    /// Walks the RIFF chunk list instead of assuming a 44-byte header: `afconvert`
    /// writes a 4,044-byte `FLLR` padding chunk between `fmt ` and `data` (read
    /// from the committed fixtures with xxd), so byte 44 is padding, not audio,
    /// and a fixed-offset parser would stream 4 KB of silence into both stacks.
    static func parseWAV(_ fileData: Data) -> VoiceBenchPCMClip? {
        let bytes = [UInt8](fileData)

        func littleEndianInteger(at offset: Int, byteCount: Int) -> Int {
            var value = 0
            for byteIndex in 0..<byteCount {
                value |= Int(bytes[offset + byteIndex]) << (8 * byteIndex)
            }
            return value
        }

        func fourCharacterCode(at offset: Int) -> String {
            String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
        }

        guard bytes.count >= 12, fourCharacterCode(at: 0) == "RIFF", fourCharacterCode(at: 8) == "WAVE" else {
            return nil
        }

        var parsedFormat: (audioFormat: Int, channelCount: Int, sampleRate: Int, bitsPerSample: Int)?
        var chunkOffset = 12
        while chunkOffset + 8 <= bytes.count {
            let chunkIdentifier = fourCharacterCode(at: chunkOffset)
            let chunkSize = littleEndianInteger(at: chunkOffset + 4, byteCount: 4)
            let chunkBodyOffset = chunkOffset + 8
            guard chunkBodyOffset + chunkSize <= bytes.count else { return nil }

            if chunkIdentifier == "fmt " {
                guard chunkSize >= 16 else { return nil }
                parsedFormat = (
                    audioFormat: littleEndianInteger(at: chunkBodyOffset, byteCount: 2),
                    channelCount: littleEndianInteger(at: chunkBodyOffset + 2, byteCount: 2),
                    sampleRate: littleEndianInteger(at: chunkBodyOffset + 4, byteCount: 4),
                    bitsPerSample: littleEndianInteger(at: chunkBodyOffset + 14, byteCount: 2)
                )
            } else if chunkIdentifier == "data" {
                // Format 1 is integer PCM — the only thing linear16 can mean.
                guard let parsedFormat, parsedFormat.audioFormat == 1 else { return nil }
                let pcmStart = fileData.startIndex + chunkBodyOffset
                return VoiceBenchPCMClip(
                    sampleRate: parsedFormat.sampleRate,
                    channelCount: parsedFormat.channelCount,
                    bitsPerSample: parsedFormat.bitsPerSample,
                    pcmData: fileData.subdata(in: pcmStart..<(pcmStart + chunkSize))
                )
            }

            // RIFF pads an odd-sized chunk to an even boundary, and the size field excludes the pad.
            chunkOffset = chunkBodyOffset + chunkSize + (chunkSize % 2)
        }
        return nil
    }

    /// The 24 kHz twin of a 16 kHz fixture, for the OpenAI Realtime stack, which
    /// takes audio/pcm at 24 kHz only. `nil` file data is a missing twin. The
    /// duration check catches a twin made from a different utterance: both rates
    /// come from one source, so they agree to well under a chunk (worst pair
    /// measured 2026-09-23: 21 µs apart).
    static func paired24kClip(fileData: Data?, matching clip16k: VoiceBenchPCMClip) -> Result<VoiceBenchPCMClip, VoiceBenchFailure> {
        guard let fileData else { return .failure(VoiceBenchFailure(kind: "fixture24kMissing")) }
        guard let clip = parseWAV(fileData), clip.sampleRate == 24_000, clip.channelCount == 1, clip.bitsPerSample == 16 else {
            return .failure(VoiceBenchFailure(kind: "fixture24kUnreadable"))
        }
        guard abs(clip.durationSeconds - clip16k.durationSeconds) < 0.02 else {
            return .failure(VoiceBenchFailure(kind: "fixture24kDurationMismatch"))
        }
        return .success(clip)
    }

    static func bytesPerChunk(sampleRate: Int, channelCount: Int, bitsPerSample: Int, milliseconds: Int) -> Int {
        let bytesPerFrame = channelCount * bitsPerSample / 8
        return sampleRate * milliseconds / 1000 * bytesPerFrame
    }

    var durationSeconds: Double {
        let bytesPerSecond = Self.bytesPerChunk(sampleRate: sampleRate, channelCount: channelCount, bitsPerSample: bitsPerSample, milliseconds: 1000)
        return bytesPerSecond > 0 ? Double(pcmData.count) / Double(bytesPerSecond) : 0
    }

    /// Consecutive slices of `milliseconds` of audio; the last one may be shorter.
    func chunks(milliseconds: Int) -> [Data] {
        let chunkByteCount = Self.bytesPerChunk(sampleRate: sampleRate, channelCount: channelCount, bitsPerSample: bitsPerSample, milliseconds: milliseconds)
        guard chunkByteCount > 0 else { return [] }
        return stride(from: 0, to: pcmData.count, by: chunkByteCount).map { chunkStart in
            let sliceStart = pcmData.startIndex + chunkStart
            let sliceEnd = pcmData.startIndex + min(chunkStart + chunkByteCount, pcmData.count)
            return pcmData.subdata(in: sliceStart..<sliceEnd)
        }
    }
}

// MARK: - First sentence

nonisolated enum VoiceBenchSentence {
    /// The text a pipeline could hand to TTS first: everything through the first
    /// `.`, `?` or `!` that is followed by whitespace — or, once the stream has
    /// ended, by the end of the text. A terminator at the end of a still-growing
    /// buffer is not a boundary yet: "version 3." may be about to become "version 3.5".
    static func firstSentence(in text: String, textIsComplete: Bool) -> String? {
        var characterIndex = text.startIndex
        while characterIndex < text.endIndex {
            let character = text[characterIndex]
            let nextIndex = text.index(after: characterIndex)
            if character == "." || character == "?" || character == "!" {
                let isBoundary = nextIndex == text.endIndex ? textIsComplete : text[nextIndex].isWhitespace
                let sentence = text[..<nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                // A terminator with nothing speakable before it (a reply opening
                // with "." or "...") is not a sentence; TTS would be sent a lone
                // full stop. Keep scanning. Caught by the unit test, 2026-09-14.
                if isBoundary, sentence.contains(where: { $0.isLetter || $0.isNumber }) {
                    return sentence
                }
            }
            characterIndex = nextIndex
        }
        return nil
    }
}

// MARK: - Statistics

nonisolated enum VoiceBenchStatistics {
    struct Distribution: Equatable {
        let count: Int
        let medianMs: Int
        let p95Ms: Int
    }

    /// `nil` is a mark a run never reached. It is dropped, never counted as 0:
    /// a zero reads as "instant", and a stage that did not happen was not instant.
    /// `count` says how many runs each figure stands on.
    static func distribution(of millisecondValues: [Int?]) -> Distribution? {
        let sortedValues = millisecondValues.compactMap { $0 }.sorted()
        guard !sortedValues.isEmpty else { return nil }
        let middle = sortedValues.count / 2
        let median = sortedValues.count % 2 == 1
            ? sortedValues[middle]
            : (sortedValues[middle - 1] + sortedValues[middle]) / 2
        // Nearest rank. With twenty runs p95 is the 19th value: exactly one run was slower.
        let p95Rank = Int((0.95 * Double(sortedValues.count)).rounded(.up))
        return Distribution(count: sortedValues.count, medianMs: median, p95Ms: sortedValues[max(p95Rank, 1) - 1])
    }
}

// MARK: - OpenAI Realtime spend

/// The owner's OpenAI credit is under US$8, so the Realtime stack is metered
/// from its own `response.done` usage and switched off before it can matter.
nonisolated enum VoiceBenchRealtimeCost {
    // gpt-realtime-mini, US$ per 1M tokens. Source, read 2026-09-23:
    // https://developers.openai.com/api/docs/pricing ("Realtime and audio generation models").
    // No cached-image price is published, so cached image tokens pay the full image rate.
    static let textInputUSDPerMillion = 0.60
    static let cachedTextInputUSDPerMillion = 0.06
    static let audioInputUSDPerMillion = 10.00
    static let cachedAudioInputUSDPerMillion = 0.30
    static let imageInputUSDPerMillion = 0.80
    static let textOutputUSDPerMillion = 2.40
    static let audioOutputUSDPerMillion = 20.00

    /// `response.usage` flattened to dotted integer keys ("input_token_details.audio_tokens").
    /// Counts only: anything that is not an integer is dropped, so no text survives.
    static func flattenedUsage(_ usage: [String: Any], keyPrefix: String = "") -> [String: Int] {
        var flattened: [String: Int] = [:]
        for (key, value) in usage {
            let dottedKey = keyPrefix + key
            if let nested = value as? [String: Any] {
                flattened.merge(flattenedUsage(nested, keyPrefix: dottedKey + "."), uniquingKeysWith: { first, _ in first })
            } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                flattened[dottedKey] = number.intValue
            }
        }
        return flattened
    }

    /// `nil` when the usage lacks even the two totals. Tokens the details do not
    /// attribute to a modality are charged as audio, the dearest rate on each
    /// side, so a changed usage shape can only over-estimate.
    static func estimatedUSD(flattenedUsage usage: [String: Int]) -> Double? {
        guard let inputTokens = usage["input_tokens"], let outputTokens = usage["output_tokens"] else { return nil }
        func count(_ key: String) -> Int { usage[key] ?? 0 }
        let inputText = count("input_token_details.text_tokens")
        let inputAudio = count("input_token_details.audio_tokens")
        let inputImage = count("input_token_details.image_tokens")
        let cachedText = min(count("input_token_details.cached_tokens_details.text_tokens"), inputText)
        let cachedAudio = min(count("input_token_details.cached_tokens_details.audio_tokens"), inputAudio)
        let unattributedInput = max(inputTokens - inputText - inputAudio - inputImage, 0)
        let outputText = count("output_token_details.text_tokens")
        let outputAudio = count("output_token_details.audio_tokens")
        let unattributedOutput = max(outputTokens - outputText - outputAudio, 0)

        let microDollars = Double(inputText - cachedText) * textInputUSDPerMillion
            + Double(cachedText) * cachedTextInputUSDPerMillion
            + Double(inputAudio - cachedAudio + unattributedInput) * audioInputUSDPerMillion
            + Double(cachedAudio) * cachedAudioInputUSDPerMillion
            + Double(inputImage) * imageInputUSDPerMillion
            + Double(outputText) * textOutputUSDPerMillion
            + Double(outputAudio + unattributedOutput) * audioOutputUSDPerMillion
        return microDollars / 1_000_000
    }
}

/// Running total with a hard stop. A run with no usage (it failed, or
/// `response.done` never came) is charged the ceiling, never 0: a response the
/// server may have generated and billed is not free because we did not see the bill.
nonisolated struct VoiceBenchCostGuard {
    let capUSD: Double
    let missingUsageCeilingUSD: Double
    private(set) var totalUSD = 0.0

    var isCapReached: Bool { totalUSD > capUSD }

    /// Returns what this run was charged.
    mutating func record(flattenedUsage usage: [String: Int]) -> Double {
        let runUSD = VoiceBenchRealtimeCost.estimatedUSD(flattenedUsage: usage) ?? missingUsageCeilingUSD
        totalUSD += runUSD
        return runUSD
    }
}

// MARK: - One run

nonisolated enum VoiceBenchStack: String, CaseIterable, Sendable {
    case pipeline
    case speechToSpeech
    case openAIRealtime

    /// Every stack's first figure after setup, in the order `allCases` rotates:
    /// clip N starts at stack N mod 3, so over a bench each goes first equally
    /// often and none systematically inherits a network path another just warmed.
    static func order(forClipIndex clipIndex: Int) -> [VoiceBenchStack] {
        let stacks = allCases
        let firstIndex = clipIndex % stacks.count
        return Array(stacks[firstIndex...] + stacks[..<firstIndex])
    }

    /// Every duration is milliseconds. The two stacks share `sessionSetupMs`
    /// (token + connect, before the user's audio — a product would do this at
    /// key-down) and one end-to-end figure measured from the last audio chunk:
    /// `pipelineFirstAudioMs` and `stsFirstAudioMs` are the pair to compare.
    var markNames: [String] {
        switch self {
        case .pipeline:
            return [
                "sessionSetupMs",
                "sttFinalMs",             // last chunk sent -> Deepgram's from_finalize result
                "llmFirstTokenMs",        // Claude request sent -> first text delta
                "llmFirstSentenceMs",     // Claude request sent -> first complete sentence
                "ttsFirstByteMs",         // TTS request sent -> first audio byte
                "pipelineFirstAudioMs"    // last chunk sent -> first TTS audio byte
            ]
        case .speechToSpeech:
            return [
                "sessionSetupMs",
                "stsFirstAudioMs",        // last chunk sent -> first audio inlineData
                "stsTurnCompleteMs"       // last chunk sent -> turnComplete
            ]
        case .openAIRealtime:
            return [
                "sessionSetupMs",         // token + connect + session.updated + screenshot item acknowledged
                "rtFirstAudioMs",         // last chunk sent -> first response.output_audio.delta
                "rtResponseDoneMs"        // last chunk sent -> response.done
            ]
        }
    }
}

nonisolated struct VoiceBenchFailure: Error {
    let kind: String
}

nonisolated struct VoiceBenchRun {
    let benchID: String
    let stack: VoiceBenchStack
    let clipName: String
    let repetition: Int
    var marksMs: [String: Int] = [:]
    // Counts only — this type has no field that could hold the words.
    var transcriptCharacters: Int?
    var responseCharacters: Int?
    var responseAudioBytes: Int?
    var usageTokens: [String: Int] = [:]
    var estimatedCostUSD: Double?
    var errorKind: String?

    func jsonObject() -> [String: Any] {
        var marks: [String: Any] = [:]
        for markName in stack.markNames {
            marks[markName] = marksMs[markName] ?? NSNull()
        }
        return [
            "kind": "run",
            "benchId": benchID,
            "stack": stack.rawValue,
            "clip": clipName,
            "repetition": repetition,
            "marksMs": marks,
            "transcriptCharacters": transcriptCharacters ?? NSNull(),
            "responseCharacters": responseCharacters ?? NSNull(),
            "responseAudioBytes": responseAudioBytes ?? NSNull(),
            "usageTokens": usageTokens.isEmpty ? NSNull() : usageTokens,
            "estimatedCostUSD": estimatedCostUSD ?? NSNull(),
            "errorKind": errorKind ?? NSNull()
        ]
    }

    static func summaryJSONObject(for runs: [VoiceBenchRun], stack: VoiceBenchStack, benchID: String) -> [String: Any] {
        var marks: [String: Any] = [:]
        for markName in stack.markNames {
            if let distribution = VoiceBenchStatistics.distribution(of: runs.map { $0.marksMs[markName] }) {
                marks[markName] = ["n": distribution.count, "medianMs": distribution.medianMs, "p95Ms": distribution.p95Ms]
            } else {
                marks[markName] = NSNull()
            }
        }
        var errorKindCounts: [String: Int] = [:]
        for run in runs {
            if let errorKind = run.errorKind {
                errorKindCounts[errorKind, default: 0] += 1
            }
        }
        let metredCosts = runs.compactMap(\.estimatedCostUSD)
        return [
            "kind": "summary",
            "benchId": benchID,
            "stack": stack.rawValue,
            "runs": runs.count,
            "errors": errorKindCounts.values.reduce(0, +),
            "errorKinds": errorKindCounts,
            "marksMs": marks,
            "estimatedCostUSD": metredCosts.isEmpty ? NSNull() : metredCosts.reduce(0, +)
        ]
    }

    /// Stage, then domain and code only. A server's error text can carry anything,
    /// and nothing in this log may carry text we did not write.
    static func errorKind(for error: Error, stage: String) -> String {
        if let benchFailure = error as? VoiceBenchFailure {
            return benchFailure.kind
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed: return "\(stage):dns"
            case .timedOut: return "\(stage):timeout"
            case .notConnectedToInternet, .networkConnectionLost: return "\(stage):offline"
            default: return "\(stage):urlError\(urlError.code.rawValue)"
            }
        }
        let nsError = error as NSError
        // ClaudeAPI reports a non-2xx response as its own domain with the HTTP status as the code.
        if nsError.domain == "ClaudeAPI", nsError.code >= 100 {
            return "\(stage):http\(nsError.code)"
        }
        return "\(stage):\(nsError.domain)#\(nsError.code)"
    }
}

/// What one run heard and said, kept apart from `VoiceBenchRun` so the counts-only
/// log has no field that could hold words. Goes only to the 0600 answers file.
nonisolated struct VoiceBenchAnswer {
    var heardText: String?
    var answerText: String?
}

// MARK: - Async plumbing

/// A value that arrives from a WebSocket callback, awaited with a deadline.
/// First settle wins, so a late message cannot overwrite a timeout and a
/// timeout cannot overwrite a message that already arrived.
@MainActor
final class VoiceBenchWaiter<Value> {
    private var settledResult: Result<Value, Error>?
    private var waitingContinuation: CheckedContinuation<Value, Error>?

    func settle(_ result: Result<Value, Error>) {
        guard settledResult == nil else { return }
        settledResult = result
        waitingContinuation?.resume(with: result)
        waitingContinuation = nil
    }

    func value(timeoutSeconds: Double, timeoutKind: String) async throws -> Value {
        if let settledResult {
            return try settledResult.get()
        }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.settle(.failure(VoiceBenchFailure(kind: timeoutKind)))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            if let settledResult {
                continuation.resume(with: settledResult)
            } else {
                waitingContinuation = continuation
            }
        }
    }
}

/// Mutable per-run state the socket and streaming callbacks write into. A class
/// because those callbacks are `@Sendable` and may not mutate a captured `var`.
@MainActor
final class VoiceBenchLiveState {
    var finalTranscriptSegments: [String] = []
    var firstTextUptime: TimeInterval?
    var firstSentenceUptime: TimeInterval?
    var ttsTask: Task<(requestStartUptime: TimeInterval, firstByteUptime: TimeInterval), Error>?
    var responseAudioBytes = 0
    var usageTokens: [String: Int] = [:]
    var heardText = ""
    var answerText = ""
}

@MainActor
final class VoiceBenchWebSocket {
    let task: URLSessionWebSocketTask
    private var receiveLoop: Task<Void, Never>?

    init(request: URLRequest, session: URLSession) {
        task = session.webSocketTask(with: request)
    }

    /// Reads until the socket ends. Each JSON message is handed over with the
    /// uptime it arrived at, taken before any parsing, so parse cost is not latency.
    func start(
        onMessage: @escaping @MainActor @Sendable ([String: Any], TimeInterval) -> Void,
        onEnd: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        task.resume()
        receiveLoop = Task { @MainActor [task] in
            do {
                while true {
                    let message = try await task.receive()
                    let arrivalUptime = ProcessInfo.processInfo.systemUptime
                    let messageData: Data
                    switch message {
                    case .string(let text): messageData = Data(text.utf8)
                    // Gemini sends its JSON in binary frames.
                    case .data(let data): messageData = data
                    @unknown default: continue
                    }
                    guard let messageObject = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                        continue
                    }
                    onMessage(messageObject, arrivalUptime)
                }
            } catch {
                onEnd(error)
            }
        }
    }

    func sendJSON(_ messageObject: [String: Any]) async throws {
        let messageData = try JSONSerialization.data(withJSONObject: messageObject)
        try await task.send(.string(String(decoding: messageData, as: UTF8.self)))
    }

    /// A refused handshake surfaces as a generic URLError; the HTTP status says why.
    /// A socket the server closed carries a close code instead.
    func failureKind(for error: Error, stage: String) -> String {
        if let statusCode = (task.response as? HTTPURLResponse)?.statusCode, statusCode != 101 {
            return "\(stage):http\(statusCode)"
        }
        if task.closeCode != .invalid {
            if let closeReason = task.closeReason {
                // Console only, never the log: the reason is the server's text.
                print("🧪 voice bench: \(stage) closed \(task.closeCode.rawValue): \(String(decoding: closeReason, as: UTF8.self))")
            }
            return "\(stage):close\(task.closeCode.rawValue)"
        }
        return VoiceBenchRun.errorKind(for: error, stage: stage)
    }

    func close() {
        receiveLoop?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Runner

@MainActor
enum VoiceStackBenchmark {
    static let logFileName = "voice-bench.log"
    static let repetitionCount = 4
    static let audioChunkMilliseconds = 80
    static let claudeModel = "claude-haiku-4-5-20251001"
    static let claudeMaxTokens = 150
    static let openAITTSModel = "gpt-4o-mini-tts"
    static let openAITTSVoice = "alloy"
    static let geminiLiveModel = "gemini-3.1-flash-live-preview"
    static let openAIRealtimeModel = "gpt-realtime-mini"
    // "marin" is the voice OpenAI's own GA realtime examples use.
    static let openAIRealtimeVoice = "marin"
    // Cost guard, not a style choice: an audio answer is billed per output token at
    // US$20/1M, so the cap bounds one runaway reply at under a cent. Output audio
    // runs well under 400 tokens for the two short sentences the prompt asks for.
    static let openAIRealtimeMaxOutputTokens = 400
    static let openAIRealtimeCostCapUSD = 1.00
    static let openAIRealtimeMissingUsageCeilingUSD = 0.05
    static let geminiLiveConstrainedURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"

    /// A debug entry point run from the DerivedData build on this machine, so the
    /// committed fixtures are read from the source tree rather than copied into
    /// the bundle. The app is not sandboxed (`com.apple.security.app-sandbox` false).
    static let fixtureDirectoryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/voice-fixtures", isDirectory: true)
    static let fixture24kDirectoryURL = fixtureDirectoryURL
        .deletingLastPathComponent()
        .appendingPathComponent("voice-fixtures-24k", isDirectory: true)

    private static let benchURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Created on first use, after the configuration check, so an unconfigured
    /// run never fires ClaudeAPI's TLS warm-up at the placeholder host.
    private static let claudeAPI = ClaudeAPI(proxyURL: WorkerConfiguration.routeURL("/chat").absoluteString, model: claudeModel)

    /// Speech-to-speech stacks speak their own text, so there is no step where the
    /// `[POINT:...]` tag can be stripped the way the pipeline strips it before TTS —
    /// measured 2026-09-23, gpt-realtime-mini said "[POINT:none]" aloud. They get the
    /// same prompt with the pointing section cut, so answer quality is compared fairly.
    static let speechToSpeechSystemPrompt: String = {
        let fullPrompt = CompanionManager.companionVoiceResponseSystemPrompt
        guard let pointingSection = fullPrompt.range(of: "\n\nelement pointing:") else { return fullPrompt }
        return String(fullPrompt[..<pointingSection.lowerBound])
    }()

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func milliseconds(from startUptime: TimeInterval, to endUptime: TimeInterval) -> Int {
        Int(((endUptime - startUptime) * 1000).rounded())
    }

    private static func appendLine(_ lineObject: [String: Any]) {
        MeasurementLogFile.appendJSONLine(lineObject, toFileNamed: logFileName)
    }

    static func run() async {
        defer { MeasurementLogFile.waitForPendingWrites() }
        let benchID = UUID().uuidString
        let logPath = MeasurementLogFile.directoryURL.appendingPathComponent(logFileName).path

        guard WorkerConfiguration.isConfigured else {
            // Nothing below can succeed, and forty failed runs would bury the one reason.
            appendLine([
                "kind": "notConfigured",
                "benchId": benchID,
                "workerBaseURLIsPlaceholder": WorkerConfiguration.baseURL == WorkerConfiguration.placeholderBaseURL,
                "clientKeyPresent": WorkerConfiguration.clientKey != nil,
                "requiredDefaults": [WorkerConfiguration.baseURLDefaultsKey, WorkerConfiguration.clientKeyDefaultsKey]
            ])
            print("🧪 voice bench: worker not configured, nothing measured -> \(logPath)")
            return
        }

        var clips: [(name: String, clip: VoiceBenchPCMClip, clip24k: VoiceBenchPCMClip)] = []
        let fixtureURLs = ((try? FileManager.default.contentsOfDirectory(at: fixtureDirectoryURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for fixtureURL in fixtureURLs {
            let clipName = fixtureURL.deletingPathExtension().lastPathComponent
            guard let fileData = try? Data(contentsOf: fixtureURL),
                  let clip = VoiceBenchPCMClip.parseWAV(fileData),
                  clip.sampleRate == 16_000, clip.channelCount == 1, clip.bitsPerSample == 16 else {
                appendLine(["kind": "fixtureUnreadable", "benchId": benchID, "clip": clipName])
                print("🧪 voice bench: \(clipName) is not 16 kHz mono linear16 -> \(logPath)")
                return
            }
            let twinData = try? Data(contentsOf: fixture24kDirectoryURL.appendingPathComponent(fixtureURL.lastPathComponent))
            switch VoiceBenchPCMClip.paired24kClip(fileData: twinData, matching: clip) {
            case .success(let clip24k):
                clips.append((name: clipName, clip: clip, clip24k: clip24k))
            case .failure(let failure):
                // Refused, not skipped: a stack measured on fewer clips is not the same comparison.
                appendLine(["kind": failure.kind, "benchId": benchID, "clip": clipName])
                print("🧪 voice bench: \(clipName) has no usable 24 kHz twin (\(failure.kind)) -> \(logPath)")
                return
            }
        }
        guard !clips.isEmpty else {
            appendLine(["kind": "fixturesMissing", "benchId": benchID, "directory": fixtureDirectoryURL.path])
            print("🧪 voice bench: no fixtures in \(fixtureDirectoryURL.path) -> \(logPath)")
            return
        }

        // ONE screenshot for all forty runs: a fresh capture per run would hand
        // each stack a different image, and image content moves both latency and
        // answer length.
        let screenshot: CompanionScreenCapture
        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let chosenCapture = captures.first(where: { $0.isCursorScreen }) ?? captures.first else {
                throw VoiceBenchFailure(kind: "capture:noDisplay")
            }
            screenshot = chosenCapture
        } catch {
            appendLine(["kind": "captureFailed", "benchId": benchID, "errorKind": VoiceBenchRun.errorKind(for: error, stage: "capture")])
            print("🧪 voice bench: screen capture failed -> \(logPath)")
            return
        }
        let imageLabel = screenshot.label + " (image dimensions: \(screenshot.screenshotWidthInPixels)x\(screenshot.screenshotHeightInPixels) pixels)"

        appendLine([
            "kind": "start",
            "benchId": benchID,
            "clips": clips.map { ["name": $0.name, "seconds": ($0.clip.durationSeconds * 1000).rounded() / 1000] },
            "repetitions": repetitionCount,
            "imageBytes": screenshot.imageData.count,
            "imagePixels": "\(screenshot.screenshotWidthInPixels)x\(screenshot.screenshotHeightInPixels)",
            "claudeModel": claudeModel,
            "ttsModel": openAITTSModel,
            "liveModel": geminiLiveModel,
            "realtimeModel": openAIRealtimeModel,
            "realtimeCostCapUSD": openAIRealtimeCostCapUSD
        ])
        print("🧪 voice bench: \(clips.count) clips x \(repetitionCount) repetitions per stack -> \(logPath)")

        let answersFileURL = MeasurementLogFile.directoryURL.appendingPathComponent("voice-bench-answers-\(benchID).jsonl")
        let answersFileHandle = openOwnerOnlyAnswersFile(at: answersFileURL)
        defer { try? answersFileHandle?.close() }

        var costGuard = VoiceBenchCostGuard(capUSD: openAIRealtimeCostCapUSD, missingUsageCeilingUSD: openAIRealtimeMissingUsageCeilingUSD)
        var finishedRuns: [VoiceBenchRun] = []
        var clipIndex = 0
        for repetition in 1...repetitionCount {
            for (clipName, clip, clip24k) in clips {
                let stackOrder = VoiceBenchStack.order(forClipIndex: clipIndex)
                clipIndex += 1

                for stack in stackOrder {
                    // Checked before each run, so the cap stops the stack at the first
                    // run after the total crosses it; the other two keep going.
                    if stack == .openAIRealtime, costGuard.isCapReached { continue }
                    var run = VoiceBenchRun(benchID: benchID, stack: stack, clipName: clipName, repetition: repetition)
                    let answer: VoiceBenchAnswer
                    switch stack {
                    case .pipeline:
                        answer = await measurePipeline(into: &run, clip: clip, screenshot: screenshot, imageLabel: imageLabel)
                    case .speechToSpeech:
                        answer = await measureSpeechToSpeech(into: &run, clip: clip, screenshot: screenshot)
                    case .openAIRealtime:
                        answer = await measureOpenAIRealtime(into: &run, clip: clip24k, screenshot: screenshot)
                        run.estimatedCostUSD = costGuard.record(flattenedUsage: run.usageTokens)
                    }
                    appendLine(run.jsonObject())
                    // Once only: after this, the check above skips every Realtime run.
                    if stack == .openAIRealtime, costGuard.isCapReached {
                        appendLine([
                            "kind": "costCapReached",
                            "benchId": benchID,
                            "stack": stack.rawValue,
                            "capUSD": openAIRealtimeCostCapUSD,
                            "estimatedTotalUSD": costGuard.totalUSD
                        ])
                    }
                    if let answersFileHandle, let answerLine = MeasurementLogFile.jsonLine([
                        "benchId": benchID,
                        "stack": stack.rawValue,
                        "clip": clipName,
                        "repetition": repetition,
                        "heard": answer.heardText ?? NSNull(),
                        "answer": answer.answerText ?? NSNull()
                    ]) {
                        try? answersFileHandle.write(contentsOf: Data((answerLine + "\n").utf8))
                    }
                    finishedRuns.append(run)
                    print("🧪 voice bench: \(stack.rawValue) \(clipName) #\(repetition) \(run.errorKind ?? "ok") \(run.marksMs)")
                }
            }
        }

        for stack in VoiceBenchStack.allCases {
            appendLine(VoiceBenchRun.summaryJSONObject(for: finishedRuns.filter { $0.stack == stack }, stack: stack, benchID: benchID))
        }
        print("🧪 voice bench: finished (OpenAI Realtime estimated US$\(costGuard.totalUSD))")
    }

    /// Created 0600 before the first word is written — not chmod-ed afterwards, which
    /// would leave a window where the answers are readable by other local users.
    /// A failure costs the quality record, never the timing run.
    private static func openOwnerOnlyAnswersFile(at fileURL: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fileDescriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o600)
        guard fileDescriptor >= 0 else {
            print("🧪 voice bench: answers file not created (errno \(errno)), answers not recorded")
            return nil
        }
        return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }

    // MARK: Shared steps

    /// Sends each chunk on an absolute schedule, so one slow send is caught up
    /// rather than pushing every later chunk back. Returns the uptime at which
    /// the last chunk finished sending — where both stacks' clocks start.
    private static func streamInRealTime(_ audioChunks: [Data], send: (Data) async throws -> Void) async throws -> TimeInterval {
        let clock = ContinuousClock()
        let streamStartInstant = clock.now
        for (chunkIndex, audioChunk) in audioChunks.enumerated() {
            try await clock.sleep(until: streamStartInstant + .milliseconds(audioChunkMilliseconds * chunkIndex), tolerance: nil)
            try await send(audioChunk)
        }
        return uptime
    }

    private static func postToWorker(routePath: String, jsonBody: [String: Any], stage: String) async throws -> (bytes: URLSession.AsyncBytes, startUptime: TimeInterval) {
        var request = URLRequest(url: WorkerConfiguration.routeURL(routePath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        WorkerConfiguration.attachClientKey(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        let requestStartUptime = uptime
        let (responseBytes, response) = try await benchURLSession.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            responseBytes.task.cancel()
            throw VoiceBenchFailure(kind: "\(stage):http\(statusCode)")
        }
        return (responseBytes, requestStartUptime)
    }

    private static func fetchWorkerJSON(routePath: String, stage: String) async throws -> [String: Any] {
        let (responseBytes, _) = try await postToWorker(routePath: routePath, jsonBody: [:], stage: stage)
        var responseData = Data()
        for try await byte in responseBytes {
            responseData.append(byte)
        }
        guard let responseObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw VoiceBenchFailure(kind: "\(stage):badJSON")
        }
        return responseObject
    }

    // MARK: (P) Deepgram -> Claude -> OpenAI TTS

    private static func measurePipeline(
        into run: inout VoiceBenchRun,
        clip: VoiceBenchPCMClip,
        screenshot: CompanionScreenCapture,
        imageLabel: String
    ) async -> VoiceBenchAnswer {
        var answer = VoiceBenchAnswer()
        var stage = "deepgramToken"
        var deepgramSocket: VoiceBenchWebSocket?
        let liveState = VoiceBenchLiveState()
        defer {
            deepgramSocket?.close()
            liveState.ttsTask?.cancel()
        }

        do {
            let setupStartUptime = uptime
            let grant = try await fetchWorkerJSON(routePath: "/deepgram-token", stage: stage)
            guard let accessToken = grant["access_token"] as? String else {
                throw VoiceBenchFailure(kind: "\(stage):noAccessToken")
            }

            stage = "stt"
            var listenURLComponents = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
            listenURLComponents.queryItems = [
                URLQueryItem(name: "model", value: "nova-3"),
                URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "sample_rate", value: String(clip.sampleRate)),
                URLQueryItem(name: "channels", value: String(clip.channelCount)),
                URLQueryItem(name: "interim_results", value: "true"),
                URLQueryItem(name: "smart_format", value: "true")
            ]
            var listenRequest = URLRequest(url: listenURLComponents.url!)
            // A grant JWT is presented as Bearer; the long-lived key would be `Token`.
            listenRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let socket = VoiceBenchWebSocket(request: listenRequest, session: benchURLSession)
            deepgramSocket = socket

            let finalizeWaiter = VoiceBenchWaiter<TimeInterval>()
            socket.start(onMessage: { message, arrivalUptime in
                guard message["type"] as? String == "Results" else { return }
                if message["is_final"] as? Bool == true,
                   let channel = message["channel"] as? [String: Any],
                   let alternatives = channel["alternatives"] as? [[String: Any]],
                   let transcript = alternatives.first?["transcript"] as? String,
                   !transcript.isEmpty {
                    liveState.finalTranscriptSegments.append(transcript)
                }
                if message["from_finalize"] as? Bool == true {
                    finalizeWaiter.settle(.success(arrivalUptime))
                }
            }, onEnd: { error in
                finalizeWaiter.settle(.failure(error))
            })

            // A send completes only once the handshake has, so this proves the
            // socket is open before the audio clock starts. KeepAlive is a
            // documented client message that transcribes nothing.
            try await socket.sendJSON(["type": "KeepAlive"])
            run.marksMs["sessionSetupMs"] = milliseconds(from: setupStartUptime, to: uptime)

            let lastAudioSentUptime = try await streamInRealTime(clip.chunks(milliseconds: audioChunkMilliseconds)) { audioChunk in
                try await socket.task.send(.data(audioChunk))
            }
            // Finalize flushes what Deepgram is holding instead of waiting for its
            // own endpointing — the push-to-talk release, stated to the server.
            try await socket.sendJSON(["type": "Finalize"])
            let finalizedUptime = try await finalizeWaiter.value(timeoutSeconds: 10, timeoutKind: "stt:finalizeTimeout")
            run.marksMs["sttFinalMs"] = milliseconds(from: lastAudioSentUptime, to: finalizedUptime)
            try? await socket.sendJSON(["type": "CloseStream"])
            socket.close()
            deepgramSocket = nil

            let transcript = liveState.finalTranscriptSegments.joined(separator: " ")
            answer.heardText = transcript
            run.transcriptCharacters = transcript.count
            guard !transcript.isEmpty else { throw VoiceBenchFailure(kind: "stt:emptyTranscript") }

            stage = "llm"
            let llmStartUptime = uptime
            let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                images: [(data: screenshot.imageData, label: imageLabel)],
                systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
                userPrompt: transcript,
                maxTokens: claudeMaxTokens,
                onTextChunk: { accumulatedText in
                    let chunkUptime = ProcessInfo.processInfo.systemUptime
                    if liveState.firstTextUptime == nil {
                        liveState.firstTextUptime = chunkUptime
                    }
                    // A real pipeline starts speaking at the first sentence, while
                    // Claude is still writing the rest — so TTS starts here, not at the end.
                    guard liveState.ttsTask == nil,
                          let sentence = VoiceBenchSentence.firstSentence(in: accumulatedText, textIsComplete: false) else { return }
                    let spokenSentence = CompanionManager.parsePointingCoordinates(from: sentence).spokenText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !spokenSentence.isEmpty else { return }
                    liveState.firstSentenceUptime = chunkUptime
                    liveState.ttsTask = Task { @MainActor in try await requestFirstTTSByte(for: spokenSentence) }
                }
            )
            run.responseCharacters = fullResponseText.count
            answer.answerText = fullResponseText
            if let firstTextUptime = liveState.firstTextUptime {
                run.marksMs["llmFirstTokenMs"] = milliseconds(from: llmStartUptime, to: firstTextUptime)
            }

            if liveState.ttsTask == nil {
                // No sentence boundary while streaming (a one-clause answer): the
                // whole spoken text only became available when the stream ended.
                let spokenText = CompanionManager.parsePointingCoordinates(from: fullResponseText).spokenText
                let sentence = VoiceBenchSentence.firstSentence(in: spokenText, textIsComplete: true)
                    ?? spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentence.isEmpty else { throw VoiceBenchFailure(kind: "llm:emptyResponse") }
                liveState.firstSentenceUptime = uptime
                liveState.ttsTask = Task { @MainActor in try await requestFirstTTSByte(for: sentence) }
            }
            if let firstSentenceUptime = liveState.firstSentenceUptime {
                run.marksMs["llmFirstSentenceMs"] = milliseconds(from: llmStartUptime, to: firstSentenceUptime)
            }

            stage = "tts"
            guard let ttsTask = liveState.ttsTask else { throw VoiceBenchFailure(kind: "tts:notStarted") }
            let ttsTiming = try await ttsTask.value
            run.marksMs["ttsFirstByteMs"] = milliseconds(from: ttsTiming.requestStartUptime, to: ttsTiming.firstByteUptime)
            run.marksMs["pipelineFirstAudioMs"] = milliseconds(from: lastAudioSentUptime, to: ttsTiming.firstByteUptime)
        } catch {
            run.errorKind = deepgramSocket?.failureKind(for: error, stage: stage)
                ?? VoiceBenchRun.errorKind(for: error, stage: stage)
        }
        return answer
    }

    /// Asks for raw PCM streamed as bytes — the earliest-playable form the
    /// endpoint offers (`sse` wraps the same audio in base64 events) — and stops
    /// reading at the first byte. The audio is never decoded or played.
    private static func requestFirstTTSByte(for text: String) async throws -> (requestStartUptime: TimeInterval, firstByteUptime: TimeInterval) {
        let (audioBytes, requestStartUptime) = try await postToWorker(
            routePath: "/openai-tts",
            jsonBody: [
                "model": openAITTSModel,
                "voice": openAITTSVoice,
                "input": text,
                "response_format": "pcm",
                "stream_format": "audio"
            ],
            stage: "tts"
        )
        defer { audioBytes.task.cancel() }
        var byteIterator = audioBytes.makeAsyncIterator()
        guard try await byteIterator.next() != nil else {
            throw VoiceBenchFailure(kind: "tts:emptyBody")
        }
        return (requestStartUptime, ProcessInfo.processInfo.systemUptime)
    }

    // MARK: (S) Gemini Live

    private static func measureSpeechToSpeech(
        into run: inout VoiceBenchRun,
        clip: VoiceBenchPCMClip,
        screenshot: CompanionScreenCapture
    ) async -> VoiceBenchAnswer {
        var stage = "geminiToken"
        var geminiSocket: VoiceBenchWebSocket?
        let liveState = VoiceBenchLiveState()
        defer { geminiSocket?.close() }

        do {
            let setupStartUptime = uptime
            let tokenResponse = try await fetchWorkerJSON(routePath: "/gemini-live-token", stage: stage)
            guard let ephemeralToken = tokenResponse["token"] as? String else {
                throw VoiceBenchFailure(kind: "\(stage):noToken")
            }

            stage = "sts"
            // Ephemeral tokens work only on the v1beta *Constrained* endpoint.
            var liveURLComponents = URLComponents(string: geminiLiveConstrainedURL)!
            liveURLComponents.queryItems = [URLQueryItem(name: "access_token", value: ephemeralToken)]
            let socket = VoiceBenchWebSocket(request: URLRequest(url: liveURLComponents.url!), session: benchURLSession)
            geminiSocket = socket

            let setupCompleteWaiter = VoiceBenchWaiter<TimeInterval>()
            let firstAudioWaiter = VoiceBenchWaiter<TimeInterval>()
            let turnCompleteWaiter = VoiceBenchWaiter<TimeInterval>()
            socket.start(onMessage: { message, arrivalUptime in
                if let usageMetadata = message["usageMetadata"] as? [String: Any] {
                    // Top-level counts only; the per-modality detail arrays are dropped.
                    liveState.usageTokens = usageMetadata.compactMapValues { $0 as? Int }
                }
                if message["setupComplete"] != nil {
                    setupCompleteWaiter.settle(.success(arrivalUptime))
                }
                guard let serverContent = message["serverContent"] as? [String: Any] else { return }
                if let heardPiece = (serverContent["inputTranscription"] as? [String: Any])?["text"] as? String {
                    liveState.heardText += heardPiece
                }
                if let answerPiece = (serverContent["outputTranscription"] as? [String: Any])?["text"] as? String {
                    liveState.answerText += answerPiece
                }
                // Gemini 3.1 can put several parts in one event; every one is counted.
                if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                   let parts = modelTurn["parts"] as? [[String: Any]] {
                    for part in parts {
                        guard let inlineData = part["inlineData"] as? [String: Any],
                              (inlineData["mimeType"] as? String)?.hasPrefix("audio/") == true,
                              let base64Audio = inlineData["data"] as? String else { continue }
                        liveState.responseAudioBytes += Data(base64Encoded: base64Audio)?.count ?? 0
                        firstAudioWaiter.settle(.success(arrivalUptime))
                    }
                }
                if serverContent["turnComplete"] as? Bool == true {
                    turnCompleteWaiter.settle(.success(arrivalUptime))
                }
            }, onEnd: { error in
                setupCompleteWaiter.settle(.failure(error))
                firstAudioWaiter.settle(.failure(error))
                turnCompleteWaiter.settle(.failure(error))
            })

            try await socket.sendJSON([
                "setup": [
                    "model": "models/\(geminiLiveModel)",
                    "generationConfig": [
                        "responseModalities": ["AUDIO"],
                        // The lowest level the model offers (and its documented default), stated
                        // so a changed default cannot move the number silently.
                        "thinkingConfig": ["thinkingLevel": "MINIMAL"]
                    ],
                    "systemInstruction": ["parts": [["text": speechToSpeechSystemPrompt]]],
                    // Our end-of-turn, not the server's VAD: activityStart/activityEnd
                    // are push-to-talk press and release, as Finalize is for Deepgram.
                    "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
                    // Added 2026-09-23 for the answers file. Transcription is extra
                    // server work in the same session and could itself move latency,
                    // so the 2026-09-15 medians taken without it (first audio 1,620 ms;
                    // pipeline 3,451 ms) are the control this change is judged against.
                    "inputAudioTranscription": [String: Any](),
                    "outputAudioTranscription": [String: Any]()
                ]
            ])
            _ = try await setupCompleteWaiter.value(timeoutSeconds: 10, timeoutKind: "sts:setupTimeout")

            // The screenshot goes in before the turn opens. Gemini 3.1's default
            // turn coverage includes all video since the last turn.
            try await socket.sendJSON(["realtimeInput": ["video": ["mimeType": "image/jpeg", "data": screenshot.imageData.base64EncodedString()]]])
            run.marksMs["sessionSetupMs"] = milliseconds(from: setupStartUptime, to: uptime)

            try await socket.sendJSON(["realtimeInput": ["activityStart": [String: Any]()]])
            let lastAudioSentUptime = try await streamInRealTime(clip.chunks(milliseconds: audioChunkMilliseconds)) { audioChunk in
                try await socket.sendJSON(["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": audioChunk.base64EncodedString()]]])
            }
            try await socket.sendJSON(["realtimeInput": ["activityEnd": [String: Any]()]])

            let firstAudioUptime = try await firstAudioWaiter.value(timeoutSeconds: 15, timeoutKind: "sts:firstAudioTimeout")
            run.marksMs["stsFirstAudioMs"] = milliseconds(from: lastAudioSentUptime, to: firstAudioUptime)

            stage = "stsTurn"
            let turnCompleteUptime = try await turnCompleteWaiter.value(timeoutSeconds: 30, timeoutKind: "stsTurn:turnCompleteTimeout")
            run.marksMs["stsTurnCompleteMs"] = milliseconds(from: lastAudioSentUptime, to: turnCompleteUptime)
        } catch {
            run.errorKind = geminiSocket?.failureKind(for: error, stage: stage)
                ?? VoiceBenchRun.errorKind(for: error, stage: stage)
        }
        run.responseAudioBytes = liveState.responseAudioBytes
        run.usageTokens = liveState.usageTokens
        run.responseCharacters = liveState.answerText.isEmpty ? nil : liveState.answerText.count
        return VoiceBenchAnswer(
            heardText: liveState.heardText.isEmpty ? nil : liveState.heardText,
            answerText: liveState.answerText.isEmpty ? nil : liveState.answerText
        )
    }

    // MARK: (R) OpenAI Realtime

    private static func measureOpenAIRealtime(
        into run: inout VoiceBenchRun,
        clip: VoiceBenchPCMClip,
        screenshot: CompanionScreenCapture
    ) async -> VoiceBenchAnswer {
        var stage = "openAIToken"
        var realtimeSocket: VoiceBenchWebSocket?
        let liveState = VoiceBenchLiveState()
        defer { realtimeSocket?.close() }
        // Our own id, so the acknowledgement we wait for is provably the screenshot's.
        let imageItemID = "bench_screenshot"

        do {
            let setupStartUptime = uptime
            let tokenResponse = try await fetchWorkerJSON(routePath: "/openai-realtime-token", stage: stage)
            guard let ephemeralKey = tokenResponse["token"] as? String else {
                throw VoiceBenchFailure(kind: "\(stage):noToken")
            }

            stage = "rt"
            var realtimeURLComponents = URLComponents(string: "wss://api.openai.com/v1/realtime")!
            realtimeURLComponents.queryItems = [URLQueryItem(name: "model", value: openAIRealtimeModel)]
            var realtimeRequest = URLRequest(url: realtimeURLComponents.url!)
            // GA needs only the bearer; the beta's `OpenAI-Beta: realtime=v1` header is not sent.
            realtimeRequest.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
            let socket = VoiceBenchWebSocket(request: realtimeRequest, session: benchURLSession)
            realtimeSocket = socket

            let sessionUpdatedWaiter = VoiceBenchWaiter<TimeInterval>()
            let imageAcknowledgedWaiter = VoiceBenchWaiter<TimeInterval>()
            let firstAudioWaiter = VoiceBenchWaiter<TimeInterval>()
            let responseDoneWaiter = VoiceBenchWaiter<TimeInterval>()
            let heardWaiter = VoiceBenchWaiter<TimeInterval>()
            let allWaiters = [sessionUpdatedWaiter, imageAcknowledgedWaiter, firstAudioWaiter, responseDoneWaiter, heardWaiter]
            socket.start(onMessage: { message, arrivalUptime in
                switch message["type"] as? String {
                case "session.updated":
                    sessionUpdatedWaiter.settle(.success(arrivalUptime))
                case "conversation.item.added", "conversation.item.done", "conversation.item.created":
                    if (message["item"] as? [String: Any])?["id"] as? String == imageItemID {
                        imageAcknowledgedWaiter.settle(.success(arrivalUptime))
                    }
                case "response.output_audio.delta":
                    liveState.responseAudioBytes += Data(base64Encoded: message["delta"] as? String ?? "")?.count ?? 0
                    firstAudioWaiter.settle(.success(arrivalUptime))
                case "response.output_audio_transcript.delta":
                    liveState.answerText += message["delta"] as? String ?? ""
                case "response.output_audio_transcript.done":
                    // The whole transcript, authoritative over the deltas if they disagree.
                    if let fullTranscript = message["transcript"] as? String { liveState.answerText = fullTranscript }
                case "conversation.item.input_audio_transcription.completed":
                    liveState.heardText = message["transcript"] as? String ?? ""
                    heardWaiter.settle(.success(arrivalUptime))
                case "response.done":
                    let response = message["response"] as? [String: Any]
                    if let usage = response?["usage"] as? [String: Any] {
                        liveState.usageTokens = VoiceBenchRealtimeCost.flattenedUsage(usage)
                    }
                    // A failed response still ends with response.done; it is not an answer.
                    if let status = response?["status"] as? String, status == "failed" || status == "cancelled" {
                        responseDoneWaiter.settle(.failure(VoiceBenchFailure(kind: "rtTurn:response\(status == "failed" ? "Failed" : "Cancelled")")))
                    } else {
                        responseDoneWaiter.settle(.success(arrivalUptime))
                    }
                case "error":
                    // Console only, never the log: the message is the server's text.
                    let serverError = message["error"] as? [String: Any]
                    print("🧪 voice bench: realtime error \(serverError?["code"] ?? "-"): \(serverError?["message"] ?? "-")")
                    for waiter in allWaiters { waiter.settle(.failure(VoiceBenchFailure(kind: "serverError"))) }
                default:
                    break
                }
            }, onEnd: { error in
                for waiter in allWaiters { waiter.settle(.failure(error)) }
            })

            try await socket.sendJSON([
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "instructions": speechToSpeechSystemPrompt,
                    "output_modalities": ["audio"],
                    "max_output_tokens": openAIRealtimeMaxOutputTokens,
                    "audio": [
                        "input": [
                            "format": ["type": "audio/pcm", "rate": 24_000],
                            // Push-to-talk like the others (Deepgram Finalize, Gemini
                            // activityEnd): we commit, the server's VAD does not decide.
                            "turn_detection": NSNull(),
                            // For the answers file. Runs beside the response, not in front
                            // of it, and bills separately at a fraction of a cent per clip.
                            "transcription": ["model": "gpt-4o-mini-transcribe"]
                        ],
                        "output": [
                            // The rate is required here too, though 24 kHz is the only one
                            // offered: without it session.update fails with
                            // missing_required_parameter (probed 2026-09-23).
                            "format": ["type": "audio/pcm", "rate": 24_000],
                            "voice": openAIRealtimeVoice
                        ]
                    ]
                ]
            ])
            _ = try await sessionUpdatedWaiter.value(timeoutSeconds: 10, timeoutKind: "rt:sessionUpdateTimeout")

            // Before the audio and off the clock, as Gemini's video frame is. Waiting for
            // the server's acknowledgement means a refused image fails the run here,
            // loudly, instead of the model answering blind and looking faster for it.
            try await socket.sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "id": imageItemID,
                    "type": "message",
                    "role": "user",
                    "content": [[
                        "type": "input_image",
                        "image_url": "data:image/jpeg;base64," + screenshot.imageData.base64EncodedString()
                    ]]
                ]
            ])
            _ = try await imageAcknowledgedWaiter.value(timeoutSeconds: 10, timeoutKind: "rt:imageAckTimeout")
            run.marksMs["sessionSetupMs"] = milliseconds(from: setupStartUptime, to: uptime)

            let lastAudioSentUptime = try await streamInRealTime(clip.chunks(milliseconds: audioChunkMilliseconds)) { audioChunk in
                try await socket.sendJSON(["type": "input_audio_buffer.append", "audio": audioChunk.base64EncodedString()])
            }
            try await socket.sendJSON(["type": "input_audio_buffer.commit"])
            try await socket.sendJSON(["type": "response.create"])

            let firstAudioUptime = try await firstAudioWaiter.value(timeoutSeconds: 15, timeoutKind: "rt:firstAudioTimeout")
            run.marksMs["rtFirstAudioMs"] = milliseconds(from: lastAudioSentUptime, to: firstAudioUptime)

            stage = "rtTurn"
            let responseDoneUptime = try await responseDoneWaiter.value(timeoutSeconds: 30, timeoutKind: "rtTurn:responseDoneTimeout")
            run.marksMs["rtResponseDoneMs"] = milliseconds(from: lastAudioSentUptime, to: responseDoneUptime)

            // Off the clock: the transcript of what was heard may land after the answer.
            _ = try? await heardWaiter.value(timeoutSeconds: 3, timeoutKind: "rt:heardTimeout")
        } catch {
            if let benchFailure = error as? VoiceBenchFailure, benchFailure.kind == "serverError" {
                run.errorKind = "\(stage):serverError"
            } else {
                run.errorKind = realtimeSocket?.failureKind(for: error, stage: stage)
                    ?? VoiceBenchRun.errorKind(for: error, stage: stage)
            }
        }
        run.responseAudioBytes = liveState.responseAudioBytes
        run.usageTokens = liveState.usageTokens
        run.transcriptCharacters = liveState.heardText.isEmpty ? nil : liveState.heardText.count
        run.responseCharacters = liveState.answerText.isEmpty ? nil : liveState.answerText.count
        return VoiceBenchAnswer(
            heardText: liveState.heardText.isEmpty ? nil : liveState.heardText,
            answerText: liveState.answerText.isEmpty ? nil : liveState.answerText
        )
    }
}
