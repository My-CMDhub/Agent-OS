//
//  PushToTalkSpeechGateTests.swift
//  leanring-buddyTests
//
//  Owner 2026-11-01: a push-to-talk press with no words must never reach the
//  model. The gate is pure arithmetic over PCM16, so it is proven here; that the
//  live session sends nothing for a silent press is proven by a live run.
//

import Foundation
import Testing
@testable import Clicky

struct PushToTalkSpeechGateTests {

    /// A sine whose RMS sits at `decibels` dBFS, as little-endian PCM16.
    private func tone(decibels: Float, milliseconds: Int, sampleRate: Int = 16_000, hertz: Float = 220) -> Data {
        let amplitude = 2.0.squareRoot() * pow(10, Double(decibels) / 20)
        let count = sampleRate * milliseconds / 1000
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let value = Int16((amplitude * sin(2 * Double.pi * Double(hertz) * Double(index) / Double(sampleRate)) * 32_767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func silence(milliseconds: Int, sampleRate: Int = 16_000) -> Data {
        Data(count: sampleRate * milliseconds / 1000 * 2)
    }

    private func gate(_ audio: Data, sampleRate: Int = 16_000, chunkBytes: Int = 2_560) -> PushToTalkSpeechGate {
        var gate = PushToTalkSpeechGate(sampleRate: sampleRate)
        var offset = 0
        while offset < audio.count {
            let end = min(audio.count, offset + chunkBytes)
            gate.add(pcm16: audio.subdata(in: offset..<end))
            offset = end
        }
        return gate
    }

    @Test func digitalSilenceIsNoSpeech() {
        let gate = gate(silence(milliseconds: 2_000))
        #expect(!gate.heardSpeech)
        #expect(gate.summary == .init(voicedMilliseconds: 0, loudestDecibels: -120, quietestDecibels: -120))
    }

    @Test func quietRoomNoiseHeldForSecondsIsNoSpeech() {
        #expect(!gate(tone(decibels: -55, milliseconds: 3_000)).heardSpeech)
    }

    /// The worst case for the press itself: its own tick at full level straight into the mic, at
    /// 48 kHz like the tap, then a 40 ms key click at -20 dBFS, then nothing said.
    @Test func thePressOwnTickAndKeyClickAreNoSpeech() {
        var pcm = Data()
        for sample in JarvisNotchTick.press.samples {
            withUnsafeBytes(of: Int16((sample * 32_767).rounded()).littleEndian) { pcm.append(contentsOf: $0) }
        }
        pcm += tone(decibels: -20, milliseconds: 40, sampleRate: 48_000) + silence(milliseconds: 1_500, sampleRate: 48_000)
        let gate = gate(pcm, sampleRate: 48_000)
        #expect(!gate.heardSpeech)
        #expect(gate.voicedMilliseconds < PushToTalkSpeechGate.minimumVoicedMilliseconds)
    }

    @Test func oneShortQuietWordIsSpeech() {
        // "no": ~250 ms voiced, 10 dB over the threshold, after the owner's half-second pause.
        #expect(gate(silence(milliseconds: 500) + tone(decibels: -35, milliseconds: 250)).heardSpeech)
    }

    @Test func chunkSizesDoNotChangeTheAnswer() {
        let audio = silence(milliseconds: 300) + tone(decibels: -30, milliseconds: 170) + silence(milliseconds: 300)
        let whole = gate(audio, chunkBytes: audio.count).summary
        #expect(gate(audio).summary == whole)
        #expect(gate(audio, chunkBytes: 322).summary == whole)
        #expect(whole.voicedMilliseconds >= 160 && whole.voicedMilliseconds <= 180)
    }

    /// Every committed recording of a spoken request passes, and still does 20 dB quieter.
    @Test func everyCommittedVoiceFixtureIsSpeechEvenTwentyDecibelsQuieter() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/voice-fixtures", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        #expect(urls.count == 18)
        for url in urls {
            let clip = try #require(VoiceBenchPCMClip.parseWAV(try Data(contentsOf: url)))
            #expect(gate(clip.pcmData, sampleRate: clip.sampleRate).heardSpeech, "\(url.lastPathComponent)")
            var quieter = Data(capacity: clip.pcmData.count)
            clip.pcmData.withUnsafeBytes { raw in
                for index in 0..<(raw.count / 2) {
                    let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    withUnsafeBytes(of: Int16(Float(sample) / 10).littleEndian) { quieter.append(contentsOf: $0) }
                }
            }
            #expect(gate(quieter, sampleRate: clip.sampleRate).heardSpeech, "\(url.lastPathComponent) -20 dB")
        }
    }

    @Test func aTapGoesIdleAndALongSilentHoldSaysNoReply() {
        #expect(RealtimeVoiceSession.silentPressNotchEvent(holdSeconds: 0.2) == .turnEnded)
        #expect(RealtimeVoiceSession.silentPressNotchEvent(holdSeconds: 0.99) == .turnEnded)
        #expect(RealtimeVoiceSession.silentPressNotchEvent(holdSeconds: 1.0) == .noReply)
        #expect(RealtimeVoiceSession.silentPressNotchEvent(holdSeconds: 4) == .noReply)
    }

    @Test func theTurnLineCarriesTheGateNumbersOrNulls() {
        var line = RealtimeLiveTurnLine(stack: "geminiLive", turnID: "t", sessionWasWarm: true)
        #expect(line.jsonObject["speechVoicedMs"] is NSNull)
        #expect(line.jsonObject["speechQuietestDb"] is NSNull)
        line.speech = .init(voicedMilliseconds: 40, loudestDecibels: -31, quietestDecibels: -72)
        #expect(line.jsonObject["speechVoicedMs"] as? Int == 40)
        #expect(line.jsonObject["speechLoudestDb"] as? Int == -31)
        #expect(line.jsonObject["speechQuietestDb"] as? Int == -72)
    }
}
