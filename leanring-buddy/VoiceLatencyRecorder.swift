//
//  VoiceLatencyRecorder.swift
//  leanring-buddy
//
//  Measurement only. Times one push-to-talk utterance from the hotkey to the
//  first audible word, stage by stage, and appends one JSON line per utterance
//  to ~/Library/Logs/Clicky/voice-latency.log. It changes nothing about how the
//  voice path behaves — the design of a guidance session waits on these numbers.
//
//  Also home to `--voice-latency-probe`: the non-speech half of the same path
//  (capture -> Claude -> TTS download), repeatable without the owner speaking.
//

import Foundation

// MARK: - Log file

/// Append-only JSON-lines files under `~/Library/Logs/Clicky`, shared by every
/// measurement recorder (voice latency, hotkey events, main-thread stalls).
///
/// Writes go through one serial utility queue because two callers run on the
/// main thread — the hotkey tap callback and the voice pipeline — and the stall
/// recorder exists to measure the main thread, so it must not be the thing
/// blocking it.
nonisolated enum MeasurementLogFile {
    private static let writeQueue = DispatchQueue(label: "Clicky.MeasurementLogFile", qos: .utility)

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Clicky", isDirectory: true)
    }

    /// One sorted-key JSON object without its newline, or nil when the object
    /// cannot be serialised. Separate from the write so a test can read exactly
    /// what would reach disk.
    static func jsonLine(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func appendJSONLine(_ object: [String: Any], toFileNamed fileName: String) {
        guard let line = jsonLine(object) else {
            print("⚠️ MeasurementLogFile: a \(fileName) line was not valid JSON and was dropped")
            return
        }
        writeQueue.async {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            appendOwnerOnly(Data((line + "\n").utf8), to: directoryURL.appendingPathComponent(fileName))
        }
    }

    /// Created 0600 by `open` itself — a file created 0644 and chmod-ed after
    /// is readable by every local account in between — and an existing file
    /// is narrowed on every append. These logs carry what the owner said and
    /// which menu items their apps offered (2026-09-25: voice-live.log,
    /// voice-tool-probe.log and voice-bench.log were all 0644).
    static func appendOwnerOnly(_ data: Data, to fileURL: URL) {
        let fileDescriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fileDescriptor >= 0 else { return }
        fchmod(fileDescriptor, 0o600)
        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        try? fileHandle.write(contentsOf: data)
    }

    /// A headless run that terminates straight after its last append would
    /// otherwise lose the line that says what happened.
    static func waitForPendingWrites() {
        writeQueue.sync {}
    }

    /// Uptime seconds to the millisecond — enough to line marks up across logs.
    static func roundedUptime(_ uptimeSeconds: TimeInterval) -> Double {
        (uptimeSeconds * 1000).rounded() / 1000
    }
}

// MARK: - One utterance

/// Every timestamp is `ProcessInfo.systemUptime`: monotonic, and the same clock
/// as `CLOCK_UPTIME_RAW` (verified 2026-09-13 on this machine, agreeing to 3 µs),
/// so lines from this log, the hotkey log and the stall log can be laid side by side.
nonisolated struct VoiceLatencyUtterance {
    enum Mark: String, CaseIterable, Sendable {
        case shortcutPressed
        case shortcutReleased
        case finalTranscriptReceived
        /// Not a speech mark: the probe has no transcript, and without this the
        /// capture stage could not be derived there at all.
        case screenCaptureStarted
        case screenCaptureFinished
        case claudeRequestStarted
        case firstClaudeTextChunk
        case claudeResponseFinished
        case ttsRequestStarted
        case playbackStarted
    }

    enum Outcome: Equatable, Sendable {
        case completed
        /// Superseded by the next press, or its response task was cancelled.
        case cancelled
        /// Pressed and released with no final transcript ever arriving.
        case noTranscript
        case error(kind: String)

        var name: String {
            switch self {
            case .completed: return "completed"
            case .cancelled: return "cancelled"
            case .noTranscript: return "noTranscript"
            case .error: return "error"
            }
        }
    }

    /// The durations a latency question is actually asked in. A stage whose
    /// start or end mark is missing is null, never 0: a zero reads as "instant",
    /// and a stage that did not happen was not instant.
    static let stageDefinitions: [(name: String, from: Mark, to: Mark)] = [
        ("pressToReleaseMs", .shortcutPressed, .shortcutReleased),
        ("releaseToTranscriptMs", .shortcutReleased, .finalTranscriptReceived),
        ("captureMs", .screenCaptureStarted, .screenCaptureFinished),
        ("claudeTimeToFirstChunkMs", .claudeRequestStarted, .firstClaudeTextChunk),
        ("claudeTotalMs", .claudeRequestStarted, .claudeResponseFinished),
        ("ttsMs", .ttsRequestStarted, .playbackStarted),
        ("captureStartToFirstAudioMs", .screenCaptureStarted, .playbackStarted),
        ("releaseToFirstAudioMs", .shortcutReleased, .playbackStarted)
    ]

    let id = UUID()
    /// "live" or "probe".
    let source: String
    let transcriptionProvider: String?
    let model: String?

    private(set) var marksAtUptime: [Mark: TimeInterval] = [:]
    // Text comes in as a String and is kept only as a count. This type has no
    // field that could hold the words, so no serialisation of it can leak what
    // the owner said or what Claude answered.
    private(set) var transcriptCharacterCount: Int?
    private(set) var responseCharacterCount: Int?
    private(set) var spokenTextCharacterCount: Int?
    var imageCount: Int?
    var totalImageBytes: Int?
    private(set) var outcome: Outcome?

    init(source: String, transcriptionProvider: String?, model: String?) {
        self.source = source
        self.transcriptionProvider = transcriptionProvider
        self.model = model
    }

    /// First write wins. `firstClaudeTextChunk` is marked on every streamed
    /// chunk and only the first one is the number we want.
    mutating func mark(_ mark: Mark, atUptime uptimeSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if marksAtUptime[mark] == nil {
            marksAtUptime[mark] = uptimeSeconds
        }
    }

    mutating func countTranscript(_ transcript: String) { transcriptCharacterCount = transcript.count }
    mutating func countResponse(_ responseText: String) { responseCharacterCount = responseText.count }
    mutating func countSpokenText(_ spokenText: String) { spokenTextCharacterCount = spokenText.count }

    mutating func finish(_ outcome: Outcome) {
        if self.outcome == nil {
            self.outcome = outcome
        }
    }

    func durationMilliseconds(from startMark: Mark, to endMark: Mark) -> Int? {
        guard let startUptime = marksAtUptime[startMark], let endUptime = marksAtUptime[endMark] else {
            return nil
        }
        return Int(((endUptime - startUptime) * 1000).rounded())
    }

    /// On a failure, the furthest the utterance got — which names the stage that broke.
    var lastMarkReached: Mark? {
        marksAtUptime.max(by: { $0.value < $1.value })?.key
    }

    func jsonObject() -> [String: Any] {
        var stagesInMilliseconds: [String: Any] = [:]
        for stage in Self.stageDefinitions {
            stagesInMilliseconds[stage.name] = durationMilliseconds(from: stage.from, to: stage.to) ?? NSNull()
        }
        var marks: [String: Any] = [:]
        for mark in Mark.allCases {
            marks[mark.rawValue] = marksAtUptime[mark].map(MeasurementLogFile.roundedUptime) ?? NSNull()
        }
        var errorKind: Any = NSNull()
        if case .error(let kind) = outcome {
            errorKind = kind
        }
        return [
            "kind": "utterance",
            "source": source,
            "transcriptionProvider": transcriptionProvider ?? NSNull(),
            "model": model ?? NSNull(),
            "outcome": outcome?.name ?? "unfinished",
            "errorKind": errorKind,
            "lastMarkReached": lastMarkReached?.rawValue ?? NSNull(),
            "transcriptCharacters": transcriptCharacterCount ?? NSNull(),
            "responseCharacters": responseCharacterCount ?? NSNull(),
            "spokenCharacters": spokenTextCharacterCount ?? NSNull(),
            "imageCount": imageCount ?? NSNull(),
            "imageBytes": totalImageBytes ?? NSNull(),
            "marksAtUptime": marks,
            "stagesMs": stagesInMilliseconds
        ]
    }

    /// Median and max per stage across a run. A stage no utterance reached is
    /// null, and `n` says how many utterances each figure stands on.
    static func summaryJSONObject(for utterances: [VoiceLatencyUtterance], source: String) -> [String: Any] {
        var stages: [String: Any] = [:]
        for stage in stageDefinitions {
            let durations = utterances
                .compactMap { $0.durationMilliseconds(from: stage.from, to: stage.to) }
                .sorted()
            guard let maximum = durations.last else {
                stages[stage.name] = NSNull()
                continue
            }
            let middle = durations.count / 2
            let median = durations.count % 2 == 1
                ? durations[middle]
                : (durations[middle - 1] + durations[middle]) / 2
            stages[stage.name] = ["n": durations.count, "medianMs": median, "maxMs": maximum]
        }
        var outcomeCounts: [String: Int] = [:]
        var errorKinds: [String] = []
        for utterance in utterances {
            outcomeCounts[utterance.outcome?.name ?? "unfinished", default: 0] += 1
            if case .error(let kind) = utterance.outcome, !errorKinds.contains(kind) {
                errorKinds.append(kind)
            }
        }
        return [
            "kind": "summary",
            "source": source,
            "utterances": utterances.count,
            "outcomes": outcomeCounts,
            "errorKinds": errorKinds,
            "stagesMs": stages
        ]
    }
}

// MARK: - Recorder

/// Holds the one open utterance and writes it when it ends. Lives beside
/// `CompanionManager`, not inside it; the voice path calls it in single lines.
@MainActor
final class VoiceLatencyRecorder {
    static let logFileName = "voice-latency.log"

    private var openUtterance: VoiceLatencyUtterance?

    var openUtteranceID: UUID? { openUtterance?.id }

    func beginUtterance(source: String, transcriptionProvider: String?, model: String?) {
        if let abandonedUtterance = openUtterance {
            // The previous utterance never reached an ending of its own: the
            // owner pressed again while it was in flight, or pressed and let go
            // without speaking. It is written now rather than silently lost.
            let outcome: VoiceLatencyUtterance.Outcome =
                abandonedUtterance.marksAtUptime[.finalTranscriptReceived] == nil ? .noTranscript : .cancelled
            finish(abandonedUtterance.id, outcome: outcome)
        }
        openUtterance = VoiceLatencyUtterance(source: source, transcriptionProvider: transcriptionProvider, model: model)
    }

    /// `utteranceID` nil means whichever utterance is open. A response task
    /// passes the id it started with, so a cancelled task that unwinds after the
    /// next press cannot write its marks into the new utterance.
    func update(utteranceID: UUID? = nil, _ change: (inout VoiceLatencyUtterance) -> Void) {
        guard var utterance = openUtterance, utteranceID == nil || utterance.id == utteranceID else { return }
        change(&utterance)
        openUtterance = utterance
    }

    func mark(_ mark: VoiceLatencyUtterance.Mark, utteranceID: UUID? = nil) {
        update(utteranceID: utteranceID) { $0.mark(mark) }
    }

    /// Writes the line once; a second finish for the same utterance is a no-op.
    @discardableResult
    func finish(_ utteranceID: UUID?, outcome: VoiceLatencyUtterance.Outcome) -> VoiceLatencyUtterance? {
        guard var utterance = openUtterance, utteranceID == nil || utterance.id == utteranceID else { return nil }
        utterance.finish(outcome)
        openUtterance = nil
        MeasurementLogFile.appendJSONLine(utterance.jsonObject(), toFileNamed: Self.logFileName)
        return utterance
    }

    /// Domain and code only. `localizedDescription` can carry a server's error
    /// body, and nothing in this log may carry text we did not write.
    nonisolated static func errorKind(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }
}

// MARK: - Headless probe

/// `--voice-latency-probe`: N runs of capture -> Claude -> TTS download against
/// the real clients, with the speech marks null and `source: "probe"`. Spends
/// API credit, so it is only ever run by hand.
@MainActor
enum VoiceLatencyProbe {
    static let iterationCount = 5
    static let cannedTranscript = "what app am i looking at right now?"

    static func run(companionManager: CompanionManager) async {
        // The exact instances the voice path uses — same worker URL, same model,
        // same session configuration — so the probe cannot drift from what it measures.
        let claudeAPI = companionManager.claudeAPI
        let ttsClient = companionManager.elevenLabsTTSClient
        let recorder = VoiceLatencyRecorder()
        var finishedUtterances: [VoiceLatencyUtterance] = []
        let logPath = MeasurementLogFile.directoryURL.appendingPathComponent(VoiceLatencyRecorder.logFileName).path
        print("🧪 Clicky: voice latency probe, \(iterationCount) iterations -> \(logPath)")

        for iteration in 1...iterationCount {
            recorder.beginUtterance(source: "probe", transcriptionProvider: nil, model: claudeAPI.model)
            recorder.update { $0.countTranscript(cannedTranscript) }
            var outcome: VoiceLatencyUtterance.Outcome = .completed

            do {
                recorder.mark(.screenCaptureStarted)
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                recorder.update { utterance in
                    utterance.mark(.screenCaptureFinished)
                    utterance.imageCount = screenCaptures.count
                    utterance.totalImageBytes = screenCaptures.reduce(0) { $0 + $1.imageData.count }
                }

                // The same labels the voice path sends, so the request is the same size.
                let labeledImages = screenCaptures.map { capture in
                    (data: capture.imageData,
                     label: capture.label + " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)")
                }

                recorder.mark(.claudeRequestStarted)
                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
                    conversationHistory: [],
                    userPrompt: cannedTranscript,
                    onTextChunk: { _ in recorder.mark(.firstClaudeTextChunk) }
                )
                recorder.update { utterance in
                    utterance.mark(.claudeResponseFinished)
                    utterance.countResponse(fullResponseText)
                }

                let spokenText = CompanionManager.parsePointingCoordinates(from: fullResponseText).spokenText
                recorder.update { $0.countSpokenText(spokenText) }

                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    recorder.mark(.ttsRequestStarted)
                    try await ttsClient.speakText(spokenText)
                    // speakText returns straight after play(). Stopping in the same
                    // main-actor turn measures the download without talking over the
                    // owner's machine; the client itself is unchanged.
                    ttsClient.stopPlayback()
                    recorder.mark(.playbackStarted)
                }
            } catch {
                outcome = .error(kind: VoiceLatencyRecorder.errorKind(for: error))
                print("❌ Clicky: voice latency probe iteration \(iteration) failed: \(error)")
            }

            if let finishedUtterance = recorder.finish(nil, outcome: outcome) {
                finishedUtterances.append(finishedUtterance)
            }
        }

        var summary = VoiceLatencyUtterance.summaryJSONObject(for: finishedUtterances, source: "probe")
        // The committed worker URL is a placeholder (commit 6b8257e). If it is still
        // in place every iteration fails on DNS, and the summary should say why.
        summary["workerBaseURLIsPlaceholder"] = CompanionManager.workerBaseURL.contains("your-worker-name")
        MeasurementLogFile.appendJSONLine(summary, toFileNamed: VoiceLatencyRecorder.logFileName)
        MeasurementLogFile.waitForPendingWrites()
        print("🧪 Clicky: voice latency probe finished")
    }
}
