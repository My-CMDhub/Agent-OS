//
//  OpenRequest.swift
//  leanring-buddy
//
//  A request stays alive until it is done (owner's live test 2026-11-04: eleven turns to book one meeting: "Try to add
//  it again" lost the day and time said one turn earlier, and every retry judged only the newest words). Pure: what was
//  asked across the turns, and whether new words carry it on. Only ever the owner's transcribed words: never a model's, never a page's.
//

import Foundation

nonisolated struct OpenRequest: Equatable {
    /// The owner's words, turn by turn, oldest first.
    private(set) var turns: [String]
    private(set) var lastUptime: TimeInterval

    /// As long as a question's answer may come (`RealtimeVoiceSession.askOwnerAnswerWindowSeconds`).
    static let windowSeconds: TimeInterval = 300

    /// `words`: a task's heard words, which may already hold several turns.
    init(words: String, uptime: TimeInterval) {
        turns = words.components(separatedBy: ReminderDue.answerSeparator)
        lastUptime = uptime
    }

    func isAlive(now: TimeInterval) -> Bool { now - lastUptime <= Self.windowSeconds }

    /// What guards and the date parser judge. `ReminderDue.parse` reads the newest turn first, then back.
    func words(adding heard: String) -> String { (turns + [heard]).joined(separator: ReminderDue.answerSeparator) }

    /// What the task is told it is doing: all of it, in order.
    func goal(adding heard: String) -> String { (turns + [heard]).joined(separator: ". ") }

    /// Said to carry on, whatever else the words hold ("I already said", "I have given you access", "try again").
    static let carryOnPhrases = ["try again", "again", "retry", "yes", "yeah", "yep", "ok", "okay", "sure", "do it", "go ahead", "please do", "carry on", "keep going", "you have access",
                                 "i gave you", "i have given", "i've given", "i said", "i told you", "i already", "i just", "you have to", "yourself", "you can now", "should work", "it should"]
    /// A plain request of its own, unless it leans on the open one. Questions are answered, never treated as more of the request.
    private static let questionWords: Set<String> = ["what", "who", "when", "where", "which", "how", "is", "are", "did", "does", "do", "can", "could"]
    /// Too common to tie two requests together.
    private static let plainWords: Set<String> = ["with", "this", "that", "them", "from", "have", "your", "want", "need", "please", "there", "here", "just", "like", "right", "about", "some", "thing"]

    /// New words carry the open request on, by what they say and not by a model's reading: "try again", "yes do it", "you have access now",
    /// a day or a time on its own, or a word of the request itself ("add the meeting"). "open safari" and "what's the time" are their own.
    /// ponytail: a word list. A miss is a new task on its own words, which asks for what it lacks; a false hit gives one request's words to another of the owner's own.
    func continued(by heard: String) -> Bool {
        let tokens = RealtimeVoiceVerbs.foldedTokens(heard).filter { !RealtimeHeardCheck.spokenFillers.contains($0) }
        guard !tokens.isEmpty, !RealtimeVoiceSession.ownerWordsStopTask(heard) else { return false }
        let spaced = " " + tokens.joined(separator: " ") + " "
        if Self.carryOnPhrases.contains(where: { spaced.contains(" \($0) ") }) { return true }
        if Self.questionWords.contains(tokens[0]) { return false }
        if !ReminderDue.matches(in: heard).isEmpty { return true }
        let earlier = Set(turns.flatMap(RealtimeVoiceVerbs.foldedTokens))
        return tokens.contains { $0.count >= 4 && !Self.plainWords.contains($0) && earlier.contains($0) }
    }
}

/// A title is the owner's, as heard. The live test's event was typed as "Meeting with Tim today at 7pm" for "test meeting with Jarvis": the model's own ear.
nonisolated enum OwnerWordsTitle {
    private static let glue: Set<String> = ["a", "an", "the", "with", "for", "to", "of", "my", "at", "on", "in", "and", "by", "from"]

    /// Each word of `title` the owner never said. A word with a digit is a time or a number, which local code reads for itself; a shared
    /// four-letter start allows a plural or a tense. Empty: the title is theirs.
    static func strangeWords(_ title: String, heard: String) -> [String] {
        let said = RealtimeVoiceVerbs.foldedTokens(heard)
        func wasSaid(_ word: String) -> Bool { said.contains { $0 == word || ($0.count >= 4 && word.count >= 4 && $0.prefix(4) == word.prefix(4)) } }
        return RealtimeVoiceVerbs.foldedTokens(title).filter { word in
            !glue.contains(word) && !word.contains(where: \.isNumber) && !wasSaid(word)
        }
    }

    static func refusalMessage(_ strange: [String], heard: String) -> String {
        "nothing was done: \(strange.joined(separator: ", ")) is not in what the owner said. A title is the owner's words as heard, verbatim: <<\(SecretScanner.redact(heard))>>"
    }
}
