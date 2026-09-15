//
//  ActionVerifier.swift
//  leanring-buddy
//
//  An action is not successful because the call returned .success. That only
//  means the message was delivered. Success is when the tree says the world
//  changed — so we go and look.
//

import ApplicationServices
import Foundation

enum VerificationOutcome: Equatable {
    case confirmed(afterMilliseconds: Int)
    /// The focused window we acted in stopped existing. See `verify`.
    case windowGone(afterMilliseconds: Int)
    case notObserved(afterMilliseconds: Int)
    case couldNotReadWindow
}

enum ActionVerifier {

    /// A gap must be read this many polls in a row before it counts. A window
    /// switch can leave no focused window for a moment, and one read of a gap
    /// is not evidence.
    static let consecutiveMissingWindowPollsRequired = 2

    /// Re-walks the focused window until `expectation` holds or the budget runs
    /// out, polling rather than sleeping a fixed time and hoping.
    ///
    /// The elapsed time is returned even on success: how long a native app takes
    /// to settle is a number Phase 3 will need for its waits, and we do not have
    /// it yet.
    ///
    /// The contract has always been "the app reacted", never "the intended thing
    /// happened" — a changed fingerprint is that same weak form. The focused
    /// window we acted in disappearing is the same kind of evidence, and it was
    /// being reported as a failure. Measured 2026-09-11: TextEdit `File > Close`
    /// took its window list `['Untitled']` -> `[]`, and the harness answered
    /// `notVerified / couldNotReadWindow` after the full 3 s, because with no
    /// window left every poll threw `.noFocusedWindow`. A success reported as
    /// its opposite. Finder never showed it only because its desktop window
    /// always remains.
    ///
    /// `hadFocusedWindowBefore` must be false when nothing was focused before the
    /// action. A menu can be pressed in an app with no window at all, and then
    /// "no focused window" afterwards is not a window that closed — it is the
    /// same nothing as before, and calling it `.windowGone` would confirm a
    /// no-op. Found in review, 2026-09-11, before it shipped.
    static func verify(
        hadFocusedWindowBefore: Bool = true,
        expectation: (AccessibilityWindowSnapshot) -> Bool,
        timeoutInSeconds: Double = 3.0,
        pollIntervalInSeconds: Double = 0.15
    ) -> VerificationOutcome {
        verifyCountingWalks(
            hadFocusedWindowBefore: hadFocusedWindowBefore, expectation: expectation,
            timeoutInSeconds: timeoutInSeconds, pollIntervalInSeconds: pollIntervalInSeconds
        ).outcome
    }

    /// `verify`, plus how many window walks it spent. The harness reports the
    /// count beside `verifyMs` (2026-09-15): `menu` confirmed at p50 648 ms in
    /// the audit log, and one ms figure cannot say whether that is one slow
    /// walk or four fast ones 150 ms apart — which is the whole question of
    /// whether to speed the walk up or stop polling on a timer.
    ///
    /// `confirmingSnapshot` is the walk that satisfied the expectation — nil for
    /// every other outcome. A caller that wants to describe the change reads it
    /// instead of walking again: measured 2026-09-15, that second walk was 143 ms
    /// of a 599 ms `select` and 172 ms of a 526 ms `type`, outside every phase.
    static func verifyCountingWalks(
        hadFocusedWindowBefore: Bool = true,
        expectation: (AccessibilityWindowSnapshot) -> Bool,
        timeoutInSeconds: Double = 3.0,
        pollIntervalInSeconds: Double = 0.15
    ) -> (outcome: VerificationOutcome, walks: Int, confirmingSnapshot: AccessibilityWindowSnapshot?) {
        poll(
            walk: { try AccessibilityTreeWalker.snapshotFocusedWindow() },
            hadFocusedWindowBefore: hadFocusedWindowBefore, expectation: expectation,
            timeoutInSeconds: timeoutInSeconds, pollIntervalInSeconds: pollIntervalInSeconds
        )
    }

    /// Which walk to describe a confirmed change from. Only a first-look
    /// confirmation is reused: the app had already settled when we first looked.
    /// On a later walk the app was still moving, so walk again as before.
    /// Measured 2026-09-15: T3-1 (`select` Displays) confirmed on 2 walks in all
    /// four planner runs, and reusing that 2-walk snapshot once listed
    /// "Colour profile" where the settled walk listed "Colour LCD" — the pane
    /// was still filling in. A speedup that changes the answer is a bug.
    static func snapshotToDescribe<Snapshot>(
        confirming: Snapshot?, walks: Int, walkAgain: () -> Snapshot?
    ) -> Snapshot? {
        walks == 1 ? confirming : walkAgain()
    }

    /// `poll` for `menu`, reading the pressed app's window count BEFORE each walk
    /// and confirming on a moved count without walking. Measured 2026-09-15: menu
    /// confirmations cost exactly one walk, and `File > New Finder Window` verified
    /// at a 388 ms median (326-672, n=16) — the walk described a window the count
    /// had already answered for. The walk's preconditions (`locate`) still run
    /// first, so a press that moved focus to another app or closed the last window
    /// throws exactly what the walk would have, and the gap rule sees it unchanged.
    /// When the count held, `expectation` runs on the walk exactly as before.
    static func pollCountingWindowsFirst<Target, Snapshot>(
        locate: () throws -> Target,
        windowCountMoved: () -> Bool,
        walk: (Target) throws -> Snapshot,
        hadFocusedWindowBefore: Bool,
        expectation: (Snapshot) -> Bool,
        timeoutInSeconds: Double = 3.0,
        pollIntervalInSeconds: Double = 0.15
    ) -> (outcome: VerificationOutcome, walks: Int) {
        let (outcome, polls, confirming) = poll(
            walk: { () throws -> Snapshot? in
                let target = try locate()
                if windowCountMoved() { return nil }   // nil: confirmed by the count, not walked
                return try walk(target)
            },
            hadFocusedWindowBefore: hadFocusedWindowBefore,
            expectation: { $0.map(expectation) ?? true },
            timeoutInSeconds: timeoutInSeconds, pollIntervalInSeconds: pollIntervalInSeconds
        )
        if case .some(.none) = confirming { return (outcome, polls - 1) }
        return (outcome, polls)
    }

    /// The loop, generic over what a walk returns so a test can drive it
    /// without a cross-process read.
    static func poll<Snapshot>(
        walk: () throws -> Snapshot,
        hadFocusedWindowBefore: Bool,
        expectation: (Snapshot) -> Bool,
        timeoutInSeconds: Double,
        pollIntervalInSeconds: Double
    ) -> (outcome: VerificationOutcome, walks: Int, confirmingSnapshot: Snapshot?) {
        let startedAt = Date()
        var sawAnyWindow = false
        var pollErrors: [Error?] = []

        func elapsedMilliseconds() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

        while Date().timeIntervalSince(startedAt) < timeoutInSeconds {
            do {
                let snapshot = try walk()
                sawAnyWindow = true
                pollErrors.append(nil)
                if expectation(snapshot) {
                    return (.confirmed(afterMilliseconds: elapsedMilliseconds()), pollErrors.count, snapshot)
                }
            } catch {
                pollErrors.append(error)
                if let gone = outcome(
                    afterPolls: pollErrors, elapsedMilliseconds: elapsedMilliseconds(),
                    hadFocusedWindowBefore: hadFocusedWindowBefore
                ) {
                    return (gone, pollErrors.count, nil)
                }
            }
            Thread.sleep(forTimeInterval: pollIntervalInSeconds)
        }

        // One entry per walk attempt, failed or not — so its count is the walk count.
        return (sawAnyWindow ? .notObserved(afterMilliseconds: elapsedMilliseconds()) : .couldNotReadWindow,
                pollErrors.count, nil)
    }

    /// The gap decision, pure so it can be tested without a cross-process read.
    /// `afterPolls` holds one entry per poll, nil for a successful snapshot.
    ///
    /// Only `.noFocusedWindow` counts. A locked screen, a revoked permission or
    /// no frontmost app is a failure to *look*, never evidence of change.
    static func outcome(
        afterPolls: [Error?],
        elapsedMilliseconds: Int,
        hadFocusedWindowBefore: Bool = true
    ) -> VerificationOutcome? {
        // A window cannot have closed if there was none to begin with.
        guard hadFocusedWindowBefore else { return nil }
        let recent = afterPolls.suffix(consecutiveMissingWindowPollsRequired)
        let allGaps = recent.count == consecutiveMissingWindowPollsRequired
            && recent.allSatisfy { ($0 as? AccessibilitySnapshotError) == .noFocusedWindow }
        return allGaps ? .windowGone(afterMilliseconds: elapsedMilliseconds) : nil
    }
}
