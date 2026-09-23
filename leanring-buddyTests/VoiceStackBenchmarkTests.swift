//
//  VoiceStackBenchmarkTests.swift
//  leanring-buddyTests
//
//  Pure logic behind `--voice-bench`: WAV parsing and chunking, the sentence
//  boundary that starts TTS, and the summary statistics. The network half is
//  proven by running the bench, not here — mocking a WebSocket tests the mock.
//

import Foundation
import Testing
@testable import Clicky

struct VoiceStackBenchmarkTests {

    private func littleEndianBytes(_ value: Int, byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    /// Builds a WAV shaped like the committed fixtures: `fmt `, an optional extra chunk, then `data`.
    private func makeWAV(pcm: Data, sampleRate: Int = 16_000, extraChunk: (identifier: String, body: Data)? = nil) -> Data {
        var riffBody = Data("WAVE".utf8)
        riffBody += Data("fmt ".utf8) + littleEndianBytes(16, byteCount: 4)
        riffBody += littleEndianBytes(1, byteCount: 2)          // integer PCM
        riffBody += littleEndianBytes(1, byteCount: 2)          // mono
        riffBody += littleEndianBytes(sampleRate, byteCount: 4)     // sample rate
        riffBody += littleEndianBytes(sampleRate * 2, byteCount: 4) // byte rate
        riffBody += littleEndianBytes(2, byteCount: 2)          // block align
        riffBody += littleEndianBytes(16, byteCount: 2)         // bits per sample
        if let extraChunk {
            riffBody += Data(extraChunk.identifier.utf8) + littleEndianBytes(extraChunk.body.count, byteCount: 4) + extraChunk.body
            if extraChunk.body.count % 2 == 1 {
                riffBody += Data([0])
            }
        }
        riffBody += Data("data".utf8) + littleEndianBytes(pcm.count, byteCount: 4) + pcm
        return Data("RIFF".utf8) + littleEndianBytes(riffBody.count, byteCount: 4) + riffBody
    }

    private let samplePCM = Data((0..<3_200).map { UInt8($0 % 251) })

    @Test func wavParserSkipsThePaddingChunkAfconvertWrites() {
        let wav = makeWAV(pcm: samplePCM, extraChunk: (identifier: "FLLR", body: Data(count: 4_044)))
        let clip = VoiceBenchPCMClip.parseWAV(wav)
        #expect(clip?.sampleRate == 16_000)
        #expect(clip?.channelCount == 1)
        #expect(clip?.bitsPerSample == 16)
        #expect(clip?.pcmData == samplePCM)
    }

    @Test func wavParserHonoursRiffPaddingAfterAnOddSizedChunk() {
        let wav = makeWAV(pcm: samplePCM, extraChunk: (identifier: "LIST", body: Data([1, 2, 3])))
        #expect(VoiceBenchPCMClip.parseWAV(wav)?.pcmData == samplePCM)
    }

    @Test func wavParserRejectsWhatIsNotAWholeWAV() {
        #expect(VoiceBenchPCMClip.parseWAV(Data("not a wav file at all".utf8)) == nil)
        let truncatedWAV = makeWAV(pcm: samplePCM).dropLast(100)
        #expect(VoiceBenchPCMClip.parseWAV(Data(truncatedWAV)) == nil)
    }

    @Test func eightyMillisecondsOfSixteenKilohertzMonoIs2560Bytes() {
        #expect(VoiceBenchPCMClip.bytesPerChunk(sampleRate: 16_000, channelCount: 1, bitsPerSample: 16, milliseconds: 80) == 2_560)

        // One second is 32,000 bytes: twelve whole 80 ms chunks and one half chunk.
        let oneSecond = Data((0..<32_000).map { UInt8($0 % 256) })
        let clip = VoiceBenchPCMClip(sampleRate: 16_000, channelCount: 1, bitsPerSample: 16, pcmData: oneSecond)
        let chunks = clip.chunks(milliseconds: 80)
        #expect(chunks.count == 13)
        #expect(chunks.dropLast().allSatisfy { $0.count == 2_560 })
        #expect(chunks.last?.count == 1_280)
        #expect(chunks.reduce(Data(), +) == oneSecond)
        #expect(clip.durationSeconds == 1.0)
    }

    @Test func committedFixturesAreSixteenKilohertzMonoLinear16() throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/voice-fixtures", isDirectory: true)
        let fixtureURLs = try FileManager.default.contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        #expect(fixtureURLs.count == 5)
        for fixtureURL in fixtureURLs {
            let clip = VoiceBenchPCMClip.parseWAV(try Data(contentsOf: fixtureURL))
            #expect(clip?.sampleRate == 16_000, "\(fixtureURL.lastPathComponent)")
            #expect(clip?.channelCount == 1)
            #expect(clip?.bitsPerSample == 16)
            #expect((clip?.durationSeconds ?? 0) > 0.5)
        }
    }

    @Test func firstSentenceNeedsWhitespaceAfterTheTerminatorUntilTheStreamEnds() {
        #expect(VoiceBenchSentence.firstSentence(in: "you're in xcode. the build", textIsComplete: false) == "you're in xcode.")
        #expect(VoiceBenchSentence.firstSentence(in: "what is that? it's finder", textIsComplete: false) == "what is that?")
        #expect(VoiceBenchSentence.firstSentence(in: "nice! ", textIsComplete: false) == "nice!")
        // Still growing: "version 3." may be about to become "version 3.5".
        #expect(VoiceBenchSentence.firstSentence(in: "that's version 3.", textIsComplete: false) == nil)
        #expect(VoiceBenchSentence.firstSentence(in: "that's version 3.5 now", textIsComplete: false) == nil)
        // Once the stream has ended, the end of text is a boundary.
        #expect(VoiceBenchSentence.firstSentence(in: "that's version 3.", textIsComplete: true) == "that's version 3.")
        #expect(VoiceBenchSentence.firstSentence(in: "wait... what", textIsComplete: false) == "wait...")
        #expect(VoiceBenchSentence.firstSentence(in: "no terminator here", textIsComplete: true) == nil)
        #expect(VoiceBenchSentence.firstSentence(in: ". leading", textIsComplete: false) == nil)
    }

    @Test func distributionExcludesMissingMarksInsteadOfCountingThemAsZero() {
        let distribution = VoiceBenchStatistics.distribution(of: [nil, 300, 100, nil, 200])
        #expect(distribution == VoiceBenchStatistics.Distribution(count: 3, medianMs: 200, p95Ms: 300))
        #expect(VoiceBenchStatistics.distribution(of: [nil, nil]) == nil)
        #expect(VoiceBenchStatistics.distribution(of: []) == nil)
    }

    @Test func distributionOfTwentyRunsTakesTheNineteenthValueAsP95() {
        let twentyRuns: [Int?] = (1...20).reversed().map { $0 * 10 }
        let distribution = VoiceBenchStatistics.distribution(of: twentyRuns)
        #expect(distribution?.count == 20)
        #expect(distribution?.medianMs == 105)   // (100 + 110) / 2
        #expect(distribution?.p95Ms == 190)
    }

    @Test func runLineCarriesEveryMarkOfItsStackAsNullWhenUnreached() {
        var run = VoiceBenchRun(benchID: "bench", stack: .pipeline, clipName: "01", repetition: 1)
        run.marksMs["sttFinalMs"] = 412
        run.errorKind = "llm:http401"
        let line = run.jsonObject()
        let marks = line["marksMs"] as? [String: Any]
        #expect(marks?.count == VoiceBenchStack.pipeline.markNames.count)
        #expect(marks?["sttFinalMs"] as? Int == 412)
        #expect(marks?["pipelineFirstAudioMs"] is NSNull)
        #expect(line["errorKind"] as? String == "llm:http401")
        #expect(MeasurementLogFile.jsonLine(line) != nil)
    }

    // MARK: 24 kHz twins

    @Test func a24kTwinIsPairedOnlyWhenPresentMonoSixteenBitAndTheSameLength() throws {
        let oneSecond16k = try #require(VoiceBenchPCMClip.parseWAV(makeWAV(pcm: Data(count: 32_000))))
        let matchingTwin = makeWAV(pcm: Data(count: 48_000), sampleRate: 24_000)
        #expect((try? VoiceBenchPCMClip.paired24kClip(fileData: matchingTwin, matching: oneSecond16k).get())?.sampleRate == 24_000)

        func failureKind(_ fileData: Data?) -> String? {
            if case .failure(let failure) = VoiceBenchPCMClip.paired24kClip(fileData: fileData, matching: oneSecond16k) { return failure.kind }
            return nil
        }
        #expect(failureKind(nil) == "fixture24kMissing")
        // A 16 kHz file where the twin should be — the mistake the rate check exists for.
        #expect(failureKind(makeWAV(pcm: Data(count: 32_000))) == "fixture24kUnreadable")
        #expect(failureKind(Data("not a wav".utf8)) == "fixture24kUnreadable")
        // Half a second: a twin cut from some other utterance.
        #expect(failureKind(makeWAV(pcm: Data(count: 24_000), sampleRate: 24_000)) == "fixture24kDurationMismatch")
    }

    // MARK: Three-way order

    @Test func stackOrderRotatesSoEachStackGoesFirstEquallyOften() {
        #expect(VoiceBenchStack.order(forClipIndex: 0) == [.pipeline, .speechToSpeech, .openAIRealtime])
        #expect(VoiceBenchStack.order(forClipIndex: 1) == [.speechToSpeech, .openAIRealtime, .pipeline])
        #expect(VoiceBenchStack.order(forClipIndex: 2) == [.openAIRealtime, .pipeline, .speechToSpeech])
        #expect(VoiceBenchStack.order(forClipIndex: 3) == VoiceBenchStack.order(forClipIndex: 0))
        var firstCounts: [VoiceBenchStack: Int] = [:]
        for clipIndex in 0..<21 {
            firstCounts[VoiceBenchStack.order(forClipIndex: clipIndex)[0], default: 0] += 1
            #expect(Set(VoiceBenchStack.order(forClipIndex: clipIndex)).count == 3)
        }
        #expect(firstCounts == [.pipeline: 7, .speechToSpeech: 7, .openAIRealtime: 7])
    }

    // MARK: Realtime spend

    @Test func usageIsFlattenedToIntegerCountsAndDropsEverythingElse() {
        let flattened = VoiceBenchRealtimeCost.flattenedUsage([
            "input_tokens": 100,
            "input_token_details": ["audio_tokens": 40, "cached_tokens_details": ["text_tokens": 5]],
            "note": "server text",
            "flag": true
        ])
        #expect(flattened == [
            "input_tokens": 100,
            "input_token_details.audio_tokens": 40,
            "input_token_details.cached_tokens_details.text_tokens": 5
        ])
    }

    @Test func costEstimatePricesEachModalityAtItsOwnRate() throws {
        let usage: [String: Int] = [
            "input_tokens": 1_000_000 + 1_000_000 + 1_000_000,
            "input_token_details.text_tokens": 1_000_000,
            "input_token_details.audio_tokens": 1_000_000,
            "input_token_details.image_tokens": 1_000_000,
            "input_token_details.cached_tokens_details.text_tokens": 500_000,
            "input_token_details.cached_tokens_details.audio_tokens": 500_000,
            "output_tokens": 2_000_000,
            "output_token_details.text_tokens": 1_000_000,
            "output_token_details.audio_tokens": 1_000_000
        ]
        // text 0.5*0.60 + 0.5*0.06, audio 0.5*10 + 0.5*0.30, image 0.80, out 2.40 + 20.00
        let expectedUSD = 0.30 + 0.03 + 5.00 + 0.15 + 0.80 + 2.40 + 20.00
        let estimate = try #require(VoiceBenchRealtimeCost.estimatedUSD(flattenedUsage: usage))
        #expect(abs(estimate - expectedUSD) < 1e-9)
    }

    @Test func tokensTheDetailsDoNotExplainArePricedAsAudio() throws {
        let estimate = try #require(VoiceBenchRealtimeCost.estimatedUSD(flattenedUsage: ["input_tokens": 1_000_000, "output_tokens": 1_000_000]))
        #expect(abs(estimate - (10.00 + 20.00)) < 1e-9)
        #expect(VoiceBenchRealtimeCost.estimatedUSD(flattenedUsage: ["input_tokens": 10]) == nil)
    }

    @Test func costGuardChargesTheCeilingForMissingUsageAndTripsOnlyAboveTheCap() {
        var costGuard = VoiceBenchCostGuard(capUSD: 0.10, missingUsageCeilingUSD: 0.05)
        #expect(costGuard.record(flattenedUsage: [:]) == 0.05)
        #expect(!costGuard.isCapReached)
        _ = costGuard.record(flattenedUsage: [:])
        // Exactly at the cap is not over it.
        #expect(!costGuard.isCapReached)
        // 1,000 audio output tokens = US$0.02.
        let charged = costGuard.record(flattenedUsage: ["input_tokens": 0, "output_tokens": 1_000, "output_token_details.audio_tokens": 1_000])
        #expect(abs(charged - 0.02) < 1e-12)
        #expect(costGuard.isCapReached)
        #expect(abs(costGuard.totalUSD - 0.12) < 1e-12)
    }

    @Test func summaryTotalsTheMetredSpendAndOmitsItForUnmetredStacks() {
        var first = VoiceBenchRun(benchID: "bench", stack: .openAIRealtime, clipName: "01", repetition: 1)
        first.estimatedCostUSD = 0.01
        var second = VoiceBenchRun(benchID: "bench", stack: .openAIRealtime, clipName: "02", repetition: 1)
        second.estimatedCostUSD = 0.05
        let summary = VoiceBenchRun.summaryJSONObject(for: [first, second], stack: .openAIRealtime, benchID: "bench")
        #expect(abs((summary["estimatedCostUSD"] as? Double ?? 0) - 0.06) < 1e-12)
        let pipelineSummary = VoiceBenchRun.summaryJSONObject(for: [], stack: .pipeline, benchID: "bench")
        #expect(pipelineSummary["estimatedCostUSD"] is NSNull)
    }
}

/// A speech-to-speech stack would say the tag aloud; the cut must actually happen.
@MainActor
@Test func speechToSpeechPromptCarriesNoPointingProtocol() {
    let prompt = VoiceStackBenchmark.speechToSpeechSystemPrompt
    #expect(!prompt.contains("POINT"))
    #expect(prompt.hasPrefix("you're clicky"))
    #expect(prompt.count < CompanionManager.companionVoiceResponseSystemPrompt.count)
}
