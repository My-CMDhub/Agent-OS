//
//  AgentTaskState.swift
//  leanring-buddy
//
//  Where a do_task task stands (2026-10-10, owner: "the timeline feels rigid").
//  One value, `AgentLoop.phase`, that the voice status line, the notch and
//  do_task's reply all read — before this, each derived its own answer from
//  isRunning / a press flag / the last outcome, and they could disagree.
//

import Foundation

enum AgentTaskPhase: String, Codable, CaseIterable, Sendable {
    case planning, acting, waitingForOwner, waitingForCard, done, failed, cancelled, timedOut
    /// Found mid-task in a checkpoint at launch: the app quit while it ran.
    case interrupted

    /// A quit in one of these leaves the task `interrupted`.
    var isMidTask: Bool { [.planning, .acting, .waitingForOwner, .waitingForCard].contains(self) }

    /// Every move the loop and the session make. A terminal phase goes nowhere.
    static let legalMoves: [AgentTaskPhase: Set<AgentTaskPhase>] = [
        .planning: [.acting, .waitingForOwner, .done, .failed, .cancelled, .timedOut, .interrupted],
        .acting: [.planning, .waitingForCard, .waitingForOwner, .done, .failed, .cancelled, .timedOut, .interrupted],
        .waitingForCard: [.acting, .failed, .cancelled, .timedOut, .interrupted],
        // The owner's answer resumes it; set aside, it is cancelled.
        .waitingForOwner: [.planning, .cancelled, .interrupted],
        // Resumed (re-observes first), or set aside.
        .interrupted: [.planning, .cancelled],
        .done: [], .failed: [], .cancelled: [], .timedOut: [],
    ]

    /// nil is a task that has not begun: it may only begin planning.
    static func canMove(from: AgentTaskPhase?, to: AgentTaskPhase) -> Bool {
        guard let from else { return to == .planning }
        return legalMoves[from]?.contains(to) == true
    }

    static func ended(_ outcome: AgentLoop.Outcome) -> AgentTaskPhase {
        switch outcome {
        case .done: return .done
        case .askOwner: return .waitingForOwner
        case .cancelled: return .cancelled
        case .timeCap: return .timedOut
        case .failed, .stepCap, .refusals: return .failed
        }
    }

    nonisolated static let waitingTitle = "Waiting for you"
    nonisolated static let approvalTitle = "Needs your approval"

    /// The notch's words for a task; nil when no task needs showing.
    func notchTitle(step: Int) -> String? {
        switch self {
        case .planning, .acting: return JarvisNotch.doingTitle(step)
        case .waitingForOwner: return Self.waitingTitle
        case .waitingForCard: return Self.approvalTitle
        case .done, .failed, .cancelled, .timedOut, .interrupted: return nil
        }
    }
}

/// One phase change, with the wall time it happened.
struct AgentTaskTransition: Codable, Equatable, Sendable {
    let phase: AgentTaskPhase
    let at: Date
}
