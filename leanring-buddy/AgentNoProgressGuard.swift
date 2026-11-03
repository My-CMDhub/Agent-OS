//
//  AgentNoProgressGuard.swift
//  leanring-buddy
//
//  One task repeating one dead call. `AgentLoop.maximumSameRefusals` counts the same ERROR in a row, any
//  target, and any ok call clears it, so a read between two tries restarts the count: E12 (2026-10-14T23-16-36Z)
//  pressed "Add Reminder" five times, all notVerified, with reads between. This counts by CALL (tool + target,
//  `key`) across the whole task, reads and other calls between included, and never resets: that also covers
//  a cycle with a dead member (E08 2026-10-14T08-33-49Z, rename_item fail / press_menu ok, round and round).
//
//  Evidence only, never model text: `notVerified` or verification `notObserved` is the harness's own witness that
//  no change was seen. A key's `noChangeSeen` does not count: its witnesses are windows, focus and the front app,
//  so an arrow key moving a selection reads the same as a dead key. A call that showed a change is never counted,
//  so scrolling on, pressing Next through a wizard and typing field after field do not touch this.
//
//  Limits from a replay of 1,269 recorded suite tasks (2026-11-03, docs/ops/2026-11-03-verdict-audit.md): these two
//  end 6 of 187 failed tasks and 0 of 793 passed ones. Failures at 4 would have ended 2 passes (E03, whose model
//  changed route on its own after the 4th). All-ok cycles get no rule: 0 tasks reached three rounds.
//

import Foundation

nonisolated struct AgentNoProgressGuard {
    static let hintAt = 2
    static let noChangeLimit = 3
    static let failureLimit = 5

    enum Verdict: Equatable {
        case carryOn
        /// Goes to the model in this call's result.
        case hint(String)
        /// Why the task ends here, as `Outcome.failed` says it.
        case end(String)
    }

    private var counts: [String: Int] = [:]

    /// What makes two calls "the same": the tool and everything that aims it. ponytail: a position to 1% of the
    /// screen, so two clicks on one control a few pixels apart count as one and ones further apart do not.
    static func key(for call: RealtimeToolCall) -> String {
        var parts = [call.name, call.appName ?? "", call.elementName ?? "", call.path?.joined(separator: ">") ?? "", call.url ?? "",
                     call.shortcut ?? "", call.direction ?? "", call.text ?? "", call.words ?? "", call.pointerAction ?? ""]
        for number in [call.x, call.y, call.toX, call.toY] { parts.append(number.map { "\(Int(($0 * 100).rounded()))" } ?? "") }
        return parts.joined(separator: "\u{1F}")
    }

    /// One finished acting call. Nothing is recorded for a call that showed a change.
    mutating func record(key: String, ok: Bool, error: String?, verification: String?) -> Verdict {
        let noChange = error == "notVerified" || verification == "notObserved"
        guard noChange || !ok else { return .carryOn }
        let count = counts[key, default: 0] + 1
        counts[key] = count
        let limit = noChange ? Self.noChangeLimit : Self.failureLimit
        if count >= limit {
            return .end(noChange ? "the same step showed no change \(count) times" : "the same step failed \(count) times (\(error ?? "failed"))")
        }
        guard count >= Self.hintAt else { return .carryOn }
        return .hint("this same call has now \(noChange ? "shown no change" : "failed") \(count) times, so repeating it will not help. Take a "
            + "different route (find_on_screen to see what is there, a menu item from the App verbs, another way in) or ask the owner. "
            + "At \(limit) the task ends")
    }
}
