//
//  WorkerSync.swift
//  leanring-buddy
//
//  The voice and the task in step (owner's words 2026-11-03: "in sync always upon failure, retry, waiting etc in any
//  status so it won't die while one is waiting for response or output"). Kept when the Gemini front was discontinued
//  (2026-11-04); it runs on the cascade. Everything the agent loop does maps to a `WorkerStatus`, whose words go straight
//  through TTS with no model between them, so they say what the receipts say and nothing else. One consumer speaks them
//  in order (`RealtimeVoiceSession.enqueueWorkerStatus`); a task that goes quiet is noticed (`WorkerWatchdog`).
//

import Foundation

/// One thing the task wants the owner to know.
/// A kind the owner need not hear is still a status, so the table is whole and the log shows it.
nonisolated struct WorkerStatus: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case progress, retrying, modelFallback, stuck
        case waitingForOwner, done, unconfirmed, failed, cancelled, stalledOut, unheard
    }
    let kind: Kind
    /// Said exactly so.
    let plain: String
    var speaks = true

    /// Latest wins while it waits, and a task's end makes it moot.
    var isTransient: Bool { [.progress, .retrying, .modelFallback, .stuck].contains(kind) }

    /// Every outcome the loop can end with.
    @MainActor static func forOutcome(_ outcome: AgentLoop.Outcome, lastProgress: String?) -> WorkerStatus {
        let progress = lastProgress.map { " I got as far as: \($0)." } ?? ""
        switch outcome {
        case .done(let summary): return WorkerStatus(kind: .done, plain: summary)
        case .askOwner(let question): return WorkerStatus(kind: .waitingForOwner, plain: question)
        case .unconfirmed(let summary, _): return WorkerStatus(kind: .unconfirmed, plain: "\(summary) I couldn't confirm all of that.")
        case .failed(let reason): return WorkerStatus(kind: .failed, plain: "I couldn't finish that: \(AgentLoop.spokenReason(reason)).\(progress)")
        case .stepCap: return WorkerStatus(kind: .failed, plain: "I ran out of steps before finishing.\(progress)")
        case .timeCap: return WorkerStatus(kind: .failed, plain: "That took too long, so I stopped.\(progress)")
        case .refusals: return WorkerStatus(kind: .failed, plain: "I stopped: the same step kept being refused.\(progress)")
        // The owner's own word did this, and the turn that said it answers it (`AgentLoop.stoppedContextLine`).
        case .cancelled: return WorkerStatus(kind: .cancelled, plain: "Stopped, sir.", speaks: false)
        }
    }

    static func progress(_ lastProgress: String?) -> WorkerStatus {
        WorkerStatus(kind: .progress, plain: lastProgress.map { "Still on it, sir. So far I \($0)." } ?? "Still working on it, sir.")
    }

    static let retrying = WorkerStatus(kind: .retrying, plain: "The connection dropped. Trying that again.")

    /// Haiku was slow or missing, so the step went to the stronger model: no news for the owner, who hears one voice.
    static let modelFallback = WorkerStatus(kind: .modelFallback, plain: "", speaks: false)

    static let unheard = WorkerStatus(kind: .unheard, plain: "I didn't catch that, sir.")

    static func stuck(lastProgress: String?) -> WorkerStatus {
        WorkerStatus(kind: .stuck, plain: "This is taking longer than it should, sir. Still trying.")
    }

    static func stalledOut(lastProgress: String?) -> WorkerStatus {
        WorkerStatus(kind: .stalledOut, plain: "That stalled, sir, so I stopped it." + (lastProgress.map { " I got as far as: \($0)." } ?? ""))
    }
}

/// What waits to be said. Pure: one consumer takes `next` when the voice is free.
/// Nothing is dropped but what a later status makes moot: an end replaces whatever was still only progress.
nonisolated struct WorkerStatusQueue: Equatable {
    private(set) var waiting: [WorkerStatus] = []

    mutating func add(_ status: WorkerStatus) {
        guard status.speaks else { return }
        if status.isTransient {
            guard !waiting.contains(where: { !$0.isTransient }) else { return }
            waiting.removeAll(where: \.isTransient)
        } else {
            waiting.removeAll(where: \.isTransient)
        }
        waiting.append(status)
    }

    mutating func next() -> WorkerStatus? { waiting.isEmpty ? nil : waiting.removeFirst() }
    mutating func dropTransient() { waiting.removeAll(where: \.isTransient) }

    /// Progress is said only for a long task, and not often: half of all tasks end inside 13 s and a quarter inside 8.4 s
    /// (623 Haiku runs in agent-loop.log, 2026-11-03), so the acknowledgement then the result is the usual whole conversation.
    static let progressAfterSeconds: TimeInterval = 13
    static let progressGapSeconds: TimeInterval = 15

    static func admitsProgress(now: TimeInterval, started: TimeInterval, lastSpoken: TimeInterval?) -> Bool {
        guard now - started >= progressAfterSeconds else { return false }
        return lastSpoken.map { now - $0 >= progressGapSeconds } ?? true
    }
}

/// A task never dies silently.
nonisolated enum WorkerWatchdog {
    enum Step: Equatable { case none, say, cancel }

    /// 11,516 gaps between a run's log lines in agent-loop.log (2026-11-03, card and owner waits out): p50 0.3 s, p90 2.2, p99 5.7,
    /// p99.9 17.5, worst 75.4. Past this the owner is told; 1.1x the p99.9, so about one quiet line in a thousand speaks needlessly.
    static let sayAfterSeconds: TimeInterval = 20
    /// 1.2x the worst gap on record, and past a model call's own 60 s timeout, so its fallback to the stronger model gets its try first.
    static let cancelAfterSeconds: TimeInterval = 90

    /// `waiting`: on a card or the owner's answer, where quiet is the point. A card's ticket has its own 60 s.
    static func step(quietSeconds: TimeInterval, waiting: Bool, alreadySaid: Bool) -> Step {
        guard !waiting else { return .none }
        if quietSeconds >= cancelAfterSeconds { return .cancel }
        return quietSeconds >= sayAfterSeconds && !alreadySaid ? .say : .none
    }
}

nonisolated enum OneVoiceWords {
    /// To the owner it is one voice. Whole words; the owner's own use of a word is theirs ("the agent panel in Cursor").
    static let handOffWords = ["task runner", "the runner", "background", "agent", "agents", "haiku", "handing over", "hand it over", "handing it",
                               "handing that", "handed it", "handed that", "another model", "other model", "second model", "delegate", "delegated", "delegating"]

    /// Each word a spoken line used that names a hand-off.
    static func namedHandOff(in spoken: String, ownerWords: String = "") -> [String] {
        func spaced(_ text: String) -> String {
            " " + text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
        }
        let said = spaced(spoken), owner = spaced(ownerWords)
        return handOffWords.filter { said.contains(" \($0) ") && !owner.contains(" \($0) ") }
    }
}
