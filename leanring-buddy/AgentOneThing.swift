//
//  AgentOneThing.swift
//  leanring-buddy
//
//  One thing asked for is one thing done. K05 2026-11-03 (both runs, E5DB3F75, 5E77C7AD): "get rid of this" with three TextEdit
//  windows ran close, close, close, each verified ok, each followed by a fresh screenshot in which TextEdit was still in front with a
//  window: to the model the goal still looked unmet, and prompt lines did not move it. So the loop counts: a task may not repeat a
//  close, quit, delete or move-to-Bin on a further target unless the owner's words name several or say "all". A second one ends the task,
//  saying what was done and that the rest is the owner's to ask for.
//
//  Judged from the owner's words and the call's own fields, never from anything the model wrote about what it wants.
//

import Foundation

nonisolated enum AgentOneThing {
    enum Kind: String { case close, quit, delete }

    static let error = "oneThingAsked"

    /// What a call would take away, by the tool and the name it aims at. A position names nothing: a click on an unnamed X is not seen here,
    /// and the window commands go through the menu (`de70a2f`), so the way a close really happens is. ponytail: add the harness's resolved name if a position ever repeats.
    static func kind(of call: RealtimeToolCall) -> Kind? {
        switch call.name {
        case RealtimeVoiceVerbs.closeName:
            return call.what == "app" ? .quit : .close
        case RealtimeVoiceVerbs.moveItemsName:
            return call.text.map(namesTheBin) == true ? .delete : nil
        case RealtimeVoiceVerbs.dragItemName:
            return call.toName.map(namesTheBin) == true ? .delete : nil
        case RealtimeVoiceVerbs.pressKeysName, RealtimeVoiceVerbs.pressMenuName, RealtimeVoiceVerbs.pressElementName:
            if let keys = call.shortcut.map(foldedShortcut), let kind = shortcutKinds[keys] { return kind }
            return (call.path?.last ?? call.elementName).flatMap(kind(ofName:))
        default:
            return nil
        }
    }

    private static func namesTheBin(_ name: String) -> Bool {
        let words = RealtimeVoiceVerbs.foldedTokens(name)
        return words.contains("bin") || words.contains("trash")
    }

    private static func foldedShortcut(_ keys: String) -> String {
        keys.lowercased().replacingOccurrences(of: "command", with: "cmd").replacingOccurrences(of: " ", with: "")
    }

    private static let shortcutKinds: [String: Kind] = [
        "cmd+w": .close, "cmd+shift+w": .close, "cmd+q": .quit, "cmd+delete": .delete, "cmd+backspace": .delete]

    static func kind(ofName name: String) -> Kind? {
        let words = RealtimeVoiceVerbs.foldedTokens(name)
        if words.contains("close") { return .close }
        if words.contains("quit") { return .quit }
        if !Set(words).isDisjoint(with: ["delete", "remove", "trash", "bin"]) { return .delete }
        return nil
    }

    /// A menu item that takes many at one press ("Close All", "Quit and Close All Windows").
    static func takesMany(_ call: RealtimeToolCall) -> Bool {
        guard kind(of: call) != nil, let name = call.path?.last ?? call.elementName else { return false }
        return !Set(RealtimeVoiceVerbs.foldedTokens(name)).isDisjoint(with: ["all", "others"])
    }

    // MARK: What the owner asked for

    private static let takingVerbs: Set<String> = ["close", "quit", "exit", "delete", "remove", "trash", "bin", "kill", "dismiss", "discard"]
    private static let severalWords: Set<String> = [
        "all", "every", "everything", "both", "each", "rest", "others", "them", "these", "those", "several", "many",
        "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    /// Plurals that are not also app names: "close notes" is one app, "delete my files" is not.
    private static let severalNouns: Set<String> = ["windows", "tabs", "files", "drafts", "documents", "docs", "apps", "applications", "emails", "mails",
                                                    "folders", "items", "pictures", "screenshots", "images", "pages", "reminders", "events"]
    private static let restatingWords: Set<String> = ["it", "that", "this", "one", "thing", "please", "just", "now", "you", "can", "could", "would", "will",
                                                      "yeah", "sir", "for", "me", "right", "away"]

    /// How many things the owner's words ask to take away. nil: as many as there are.
    static func thingsAsked(heard: String) -> Int? {
        let spaced = heard.lowercased().replacingOccurrences(of: "get rid of", with: "close")
        let tokens = RealtimeVoiceVerbs.foldedTokens(spaced)
        if tokens.contains(where: { severalWords.contains($0) || severalNouns.contains($0) || (Int($0) ?? 0) > 1 }) { return nil }
        // Clauses, because "and" joins two things or two actions: "close calculator and notes" is two, "close this and open safari" is one.
        var count = 0
        let clauses = spaced.replacingOccurrences(of: #"\b(and|then|also|plus)\b|[,;.]"#, with: "|", options: .regularExpression).split(separator: "|")
        for clause in clauses {
            let words = RealtimeVoiceVerbs.foldedTokens(String(clause)).filter { !RealtimeHeardCheck.spokenFillers.contains($0) && !FrontRouter.leadIns.contains($0) }
            guard !words.isEmpty else { continue }
            let verbs = words.filter { takingVerbs.contains($0) }.count
            if verbs > 0 {
                // "could you close that calculator, yeah, just, close it": the same thing said twice (K09).
                let restates = count > 0 && words.allSatisfy { takingVerbs.contains($0) || restatingWords.contains($0) }
                if !restates { count += verbs }
            } else if count > 0, words.contains("other") || !words.contains(where: { RealtimeHeardCheck.actionVerbs.contains($0) || restatingWords.contains($0) }) {
                // A further name after a taking verb: "close calculator and notes", "close this and the other one".
                count += 1
            }
        }
        return max(count, 1)
    }

    // MARK: The ruling

    /// The loop's check before running `call`: nil lets it run. Otherwise what to tell the owner, which ends the task.
    static func refusal(call: RealtimeToolCall, heard: String, receipts: [AgentLoop.Receipt]) -> String? {
        guard let kind = kind(of: call), let asked = thingsAsked(heard: heard) else { return nil }
        let acting = receipts.filter { $0.ok && RealtimeVoiceVerbs.isActingTool($0.toolName) && $0.toolName != RealtimeVoiceVerbs.pointAtName }
        var thingsDone = 0
        var previousTook = false, previousWasConfirmation = false
        for receipt in acting {
            guard receipt.takesAway != nil else { previousTook = false; previousWasConfirmation = false; continue }
            // The app's own question about the thing just taken (a save sheet's Delete, a dialog's Move to Bin) is the same thing.
            let confirms = previousTook && !previousWasConfirmation && receipt.toolName == RealtimeVoiceVerbs.pressElementName
            if !confirms { thingsDone += 1 }
            previousTook = true
            previousWasConfirmation = confirms
        }
        if takesMany(call) { return line(kind, thingsDone: thingsDone) }
        // ponytail: two named Delete icons pressed in a row read as a question and its answer; a card still guards each delete.
        if previousTook, !previousWasConfirmation, call.name == RealtimeVoiceVerbs.pressElementName { return nil }
        return thingsDone >= asked ? line(kind, thingsDone: thingsDone) : nil
    }

    private static func line(_ kind: Kind, thingsDone: Int) -> String {
        let verb = kind == .close ? "close" : kind == .quit ? "quit" : "remove"
        guard thingsDone > 0 else { return "I didn't \(verb) anything: that would take several, and you asked for one. Tell me if you meant all of them." }
        switch kind {
        case .close: return "Closed that one. Tell me if you meant the others."
        case .quit: return "Quit that one. Tell me if you meant the others."
        case .delete: return "Removed that one. Tell me if you meant the others."
        }
    }
}
