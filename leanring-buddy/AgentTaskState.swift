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
        case .done, .unconfirmed: return .done
        case .askOwner: return .waitingForOwner
        case .cancelled: return .cancelled
        case .timeCap: return .timedOut
        case .failed, .stepCap, .refusals: return .failed
        }
    }

    nonisolated static let waitingTitle = "Waiting for you"
    nonisolated static let approvalTitle = "Needs your approval"

    /// The notch's words for a task; nil when no task needs showing. `tool` is the
    /// call running now, only ever a key into `AgentActivityWord`.
    func notchTitle(tool: String?) -> String? {
        switch self {
        case .planning: return AgentActivityWord.thinking
        case .acting: return AgentActivityWord.word(forTool: tool)
        case .waitingForOwner: return Self.waitingTitle
        case .waitingForCard: return Self.approvalTitle
        case .done, .failed, .cancelled, .timedOut, .interrupted: return nil
        }
    }
}

/// What a running task is doing, in a word, for the notch and the card's tab (owner 2026-11-03,
/// replacing "Doing · N"). From this table only, never from model text: a page steers what the
/// model writes, and the name it calls is a key here that is never itself shown.
nonisolated enum AgentActivityWord {
    /// While the loop waits on the model.
    static let thinking = "Thinking"
    static let fallback = "Working"

    private static let byTool: [String: String] = [
        // The loop's own tools.
        AgentPlan.name: "Planning",
        AgentLoopTools.searchWebName: "Searching", AgentLoopTools.webSearchName: "Searching",
        AgentLoopTools.webFetchName: "Fetching", AgentLoopTools.readPageName: "Reading",
        AgentLoopTools.doneName: "Checking", AgentLoopTools.askOwnerName: "Asking",
        // The voice tools a task also calls.
        RealtimeOpenAppTool.name: "Opening", RealtimeVoiceVerbs.openURLName: "Opening",
        RealtimeVoiceVerbs.goToFolderName: "Opening", SettingsPaneLinks.toolName: "Opening",
        RealtimeVoiceVerbs.focusAppName: "Switching",
        RealtimeVoiceVerbs.findMenuItemsName: "Searching", RealtimeVoiceVerbs.findOnScreenName: "Searching",
        RealtimeVoiceVerbs.findFileName: "Searching", RealtimeVoiceVerbs.searchHelpName: "Searching",
        RealtimeVoiceVerbs.pressMenuName: "Clicking", RealtimeVoiceVerbs.pressElementName: "Clicking",
        RealtimeVoiceVerbs.pressMenuBarItemName: "Clicking", RealtimeVoiceVerbs.pressKeysName: "Pressing",
        RealtimeVoiceVerbs.pointAtName: "Pointing", RealtimeVoiceVerbs.annotateName: "Showing",
        RealtimeVoiceVerbs.scrollName: "Scrolling", RealtimeVoiceVerbs.typeTextName: "Typing",
        RealtimeVoiceVerbs.closeName: "Closing", RealtimeVoiceVerbs.renameItemName: "Renaming",
        RealtimeVoiceVerbs.moveItemsName: "Moving", RealtimeVoiceVerbs.dragItemName: "Dragging",
        RealtimeVoiceVerbs.setValueName: "Adjusting", RealtimeVoiceVerbs.createReminderName: "Scheduling",
        RealtimeVoiceVerbs.createEventName: "Scheduling", RealtimeVoiceVerbs.findMenuBarItemsName: "Reading",
        RealtimeVoiceVerbs.listOpenAppsName: "Checking", RealtimeVoiceVerbs.readCalendarName: "Checking",
        RealtimeVoiceVerbs.briefSessionsName: "Reading",
        // Claude's computer toolset, by member (`AgentComputer.mapped`).
        "screenshot": "Looking", "zoom": "Looking", "cursor_position": "Looking", "wait": "Waiting",
        "left_click": "Clicking", "double_click": "Clicking", "right_click": "Clicking",
        "mouse_move": "Pointing", "left_click_drag": "Dragging", "key": "Pressing", "type": "Typing",
    ]

    static func word(forTool name: String?) -> String { name.flatMap { byTool[$0] } ?? fallback }

    /// Every word the table can show, so the notch knows a task's title from a voice tool's line.
    static let all = Set(byTool.values).union([thinking, fallback])
}

/// One phase change, with the wall time it happened.
struct AgentTaskTransition: Codable, Equatable, Sendable {
    let phase: AgentTaskPhase
    let at: Date
}
