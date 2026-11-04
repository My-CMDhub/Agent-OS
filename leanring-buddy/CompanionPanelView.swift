//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The menu-bar panel: "Standby" (docs/specs/2026-11-01-jarvis-ui-redesign.md
//  §3.1). Standby and housekeeping only — who it is, what state it is in (the
//  notch's state, mirrored), how to talk to it, the last thing it proved, what
//  it is always allowed to do, and setup when setup is broken. It is not a
//  dashboard and it never asks a question: tickets are answered only on the
//  card at the notch (owner's D2).
//
//  Order is fixed — header, state, conditional rows, settings — and nothing
//  ever renders above the header. Dark glass in both appearances (D1); only
//  the outer edge follows the menu bar.
//

import AVFoundation
import SwiftUI

/// The permissions setup walks through, one at a time, in this order.
enum PanelPermission: CaseIterable, Equatable {
    case microphone, accessibility, screenRecording, screenContent

    var name: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .screenContent: "Screen Content"
        }
    }

    /// The progress chip's word: four fit across the panel.
    var chipName: String {
        switch self {
        case .microphone: "Mic"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen"
        case .screenContent: "Content"
        }
    }

    /// The one-line "why" for THIS permission, in J.A.R.V.I.S.'s voice.
    var reason: String {
        switch self {
        case .microphone: "to hear you while you hold \u{2303} \u{2325}"
        case .accessibility: "to read and press controls, and to check my work"
        case .screenRecording: "to see what you see when you speak \u{2014} reopen me after granting"
        case .screenContent: "to capture the window you ask about"
        }
    }

    /// The rows setup counts. Screen Content exists only once Screen Recording
    /// is granted (its check captures the screen), so "N of M" counts what is
    /// actually there — the old copy said "all four" while three rows showed.
    static func rows(screenRecordingGranted: Bool) -> [PanelPermission] {
        screenRecordingGranted ? allCases : [.microphone, .accessibility, .screenRecording]
    }
}

struct CompanionPanelView: View {
    static let width: CGFloat = 300

    enum Page { case standby, rules, permissions }

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var confirmations: HarnessConfirmations
    @ObservedObject private var notch: JarvisNotch
    @ObservedObject private var permissions: JarvisPermissions
    /// UI snapshots only: the notch state and receipt to draw instead of the live ones.
    private let pinnedState: JarvisNotchState?
    private let pinnedReceipt: JarvisProofReceipt?
    @State private var page: Page
    @State private var hoveringPower = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(companionManager: CompanionManager, confirmations: HarnessConfirmations, notch: JarvisNotch = .shared,
         permissions: JarvisPermissions = .shared, pinnedState: JarvisNotchState? = nil, pinnedReceipt: JarvisProofReceipt? = nil, page: Page = .standby) {
        self.companionManager = companionManager
        self.confirmations = confirmations
        _notch = ObservedObject(wrappedValue: notch)
        _permissions = ObservedObject(wrappedValue: permissions)
        self.pinnedState = pinnedState
        self.pinnedReceipt = pinnedReceipt
        _page = State(initialValue: page)
    }

    private var notchState: JarvisNotchState { pinnedState ?? notch.state }
    private var receipt: JarvisProofReceipt? { pinnedReceipt ?? notch.lastProof }
    private var isReady: Bool { companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted }

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .standby:
                standby.transition(pageTransition(edge: .leading))
            case .rules:
                AlwaysRulesPage(confirmations: confirmations, back: { show(.standby) })
                    .transition(pageTransition(edge: .trailing))
            case .permissions:
                PermissionsPage(permissions: permissions, back: { show(.standby) },
                                requestScreenContent: { companionManager.requestScreenContentPermission() })
                    .transition(pageTransition(edge: .trailing))
            }
        }
        .frame(width: Self.width, alignment: .top)
        // Every control inside draws dark (a system Menu follows the appearance);
        // the edge below reads the REAL appearance, outside this override.
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: JV.panelRadius, style: .continuous))
        .jvGlass(radius: JV.panelRadius)
        .onReceive(NotificationCenter.default.publisher(for: .jarvisPanelWillShow)) { _ in
            if !(page == .permissions && permissions.keepsPageOnReopen) { page = .standby }
        }
    }

    private func pageTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private func show(_ next: Page) {
        withAnimation(reduceMotion ? JV.reduceMotionFade : .easeOut(duration: 0.15)) { page = next }
    }

    // MARK: Standby

    private var standby: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                if isReady {
                    stateBlock
                    if let receipt { receiptRow(receipt) }
                    if confirmations.pendingCount() > 0, notchState != .needsYou { approvalRow }
                } else {
                    setupBlock
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            if companionManager.hasCompletedOnboarding {
                Rectangle().fill(JV.hairline).frame(height: 1)
                VStack(spacing: 0) {
                    permissionsRow
                    alwaysAllowedRow
                    voiceRow
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("J.A.R.V.I.S.")
                .font(JV.wordmark)
                .tracking(JV.wordmarkTracking)
                .foregroundStyle(JV.ink2)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hoveringPower ? JV.ink : JV.ink3)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringPower = $0 }
            .help("Quit J.A.R.V.I.S.")
            .accessibilityLabel("Quit J.A.R.V.I.S.")
            .pointerCursor()
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    // MARK: State

    /// What the notch is doing, in the panel's words. Pure, so a test holds the mapping.
    static func stateLine(_ state: JarvisNotchState, pendingApprovals: Int) -> (glyph: JVGlyphKind, text: String) {
        switch state {
        case .idle, .noReply, .proof: return (.openArc, "Standing by")
        case .listening: return (.openArc, "Listening")
        case .thinking: return (.orbit, "Thinking")
        case .speaking: return (.openArc, "Speaking")
        case .intent(let title): return (.openArc, title)
        case .needsYou: return (.arcDown, approvalsWaiting(max(1, pendingApprovals)))
        case .didntTake: return (.brokenRing, "Didn\u{2019}t take")
        case .unconfirmed: return (.openArc, "Sent, couldn\u{2019}t confirm")
        case .unspoken(let text): return (.openArc, text)
        case .focus(let name): return (.orbit, "Focus: \(name)")
        }
    }

    static func glyphTurns(_ state: JarvisNotchState) -> Bool {
        switch state {
        case .thinking, .intent, .focus: return true
        default: return false
        }
    }

    static func approvalsWaiting(_ count: Int) -> String {
        count == 1 ? "Approval waiting \u{00B7} at the notch" : "\(count) approvals waiting \u{00B7} at the notch"
    }

    /// "Wi‑Fi off · verified 2 min ago".
    static func receiptText(_ receipt: JarvisProofReceipt, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(receipt.at))
        let when: String
        if seconds < 60 { when = "just now" }
        else if seconds < 3600 { when = "\(Int(seconds / 60)) min ago" }
        else { when = "\(Int(seconds / 3600)) h ago" }
        return "\(receipt.subject) \u{00B7} verified \(when)"
    }

    private var stateBlock: some View {
        let line = Self.stateLine(notchState, pendingApprovals: confirmations.pendingCount())
        return HStack(alignment: .top, spacing: 10) {
            // Only work in progress turns (thinking, acting); standing by is still.
            JVGlyph(kind: line.glyph, animated: Self.glyphTurns(notchState))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(line.text)
                    .font(JV.title)
                    .foregroundStyle(JV.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(reduceMotion ? nil : JV.textFade, value: line.text)
                hotkeyHint
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var hotkeyHint: some View {
        HStack(spacing: 4) {
            Text("Hold")
            keycap("\u{2303}")
            keycap("\u{2325}")
            Text("to speak")
        }
        .font(JV.body)
        .foregroundStyle(JV.ink2)
        .accessibilityLabel("Hold Control and Option to speak")
    }

    private func keycap(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(JV.ink)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: JV.keycapRadius, style: .continuous).fill(JV.raised))
            .overlay(RoundedRectangle(cornerRadius: JV.keycapRadius, style: .continuous).strokeBorder(JV.hairline, lineWidth: 1))
    }

    /// The last thing proven, this session only (D9) — the one cyan on the panel.
    private func receiptRow(_ receipt: JarvisProofReceipt) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                JVGlyph(kind: .ring, size: 10)
                    .frame(width: 16)
                Text(Self.receiptText(receipt, now: context.date))
                    .font(JV.caption)
                    .foregroundStyle(JV.ink2)
                    .lineLimit(2)
            }
        }
    }

    /// One row, no answer controls. Shown only when the notch has moved on
    /// while a ticket still waits; when the notch says "needs you" the state
    /// line already is this row. The clock catches a ticket that expires.
    @ViewBuilder
    private var approvalRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let waiting = confirmations.pendingCount(now: context.date)
            if waiting > 0 {
                HStack(spacing: 10) {
                    JVGlyph(kind: .arcDown)
                    Text(Self.approvalsWaiting(waiting))
                        .font(JV.body)
                        .foregroundStyle(JV.ink)
                }
            }
        }
    }

    // MARK: Setup — one action at a time

    private func granted(_ permission: PanelPermission) -> Bool {
        switch permission {
        case .microphone: companionManager.hasMicrophonePermission
        case .accessibility: companionManager.hasAccessibilityPermission
        case .screenRecording: companionManager.hasScreenRecordingPermission
        case .screenContent: companionManager.hasScreenContentPermission
        }
    }

    @ViewBuilder
    private var setupBlock: some View {
        let rows = PanelPermission.rows(screenRecordingGranted: companionManager.hasScreenRecordingPermission)
        let missing = rows.filter { !granted($0) }
        VStack(alignment: .leading, spacing: 12) {
            if !companionManager.hasCompletedOnboarding {
                VStack(alignment: .leading, spacing: 6) {
                    // "Sir" on glass exactly once, here (D8).
                    Text("At your service, sir.")
                        .font(JV.title)
                        .foregroundStyle(JV.ink)
                    Text("I act only while you hold \u{2303} \u{2325} and speak. I\u{2019}ll show what I\u{2019}m about to do, ask before anything that matters, and check every result before I call it done.")
                        .font(JV.body)
                        .foregroundStyle(JV.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let current = missing.first {
                HStack(alignment: .top, spacing: 10) {
                    JVGlyph(kind: .openArc).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Setup \u{00B7} \(missing.count) of \(rows.count) left")
                            .font(JV.title)
                            .foregroundStyle(JV.ink)
                        Text("I need \(current.name) \(current.reason).")
                            .font(JV.body)
                            .foregroundStyle(JV.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        primaryButton(actionTitle(for: current)) { act(on: current) }
                            .disabled(current == .screenContent && companionManager.isRequestingScreenContent)
                        if current == .accessibility {
                            Button {
                                // Unsigned dev builds sometimes never appear in the list.
                                WindowPositionManager.revealAppInFinder()
                                WindowPositionManager.openAccessibilitySettings()
                            } label: {
                                Text("Not in the list? Show the app")
                                    .font(JV.caption)
                                    .underline()
                                    .foregroundStyle(JV.ink2)
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                        progressChips(rows)
                            .padding(.top, 4)
                    }
                }
            } else if !companionManager.hasCompletedOnboarding {
                primaryButton("Begin") { companionManager.triggerOnboarding() }
            }
        }
    }

    private func actionTitle(for permission: PanelPermission) -> String {
        switch permission {
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined ? "Allow Microphone" : "Open Microphone settings"
        case .accessibility: "Open Accessibility settings"
        case .screenRecording: "Open Screen Recording settings"
        case .screenContent: "Allow Screen Content"
        }
    }

    private func act(on permission: PanelPermission) {
        switch permission {
        case .microphone:
            // The system prompt the first time; Settings once it has been answered.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .accessibility:
            // The system prompt on the first attempt, System Settings after.
            WindowPositionManager.requestAccessibilityPermission()
        case .screenRecording:
            WindowPositionManager.requestScreenRecordingPermission()
        case .screenContent:
            companionManager.requestScreenContentPermission()
        }
    }

    private func progressChips(_ rows: [PanelPermission]) -> some View {
        HStack(spacing: 8) {
            ForEach(rows, id: \.self) { permission in
                HStack(spacing: 4) {
                    Circle()
                        .fill(granted(permission) ? JV.ink : Color.clear)
                        .overlay(Circle().strokeBorder(granted(permission) ? Color.clear : JV.ink3, lineWidth: JV.stroke))
                        .frame(width: 8, height: 8)
                    Text(permission.chipName)
                        .font(JV.meta)
                        .foregroundStyle(granted(permission) ? JV.ink2 : JV.ink3)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(permission.name) \(granted(permission) ? "granted" : "missing")")
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(JV.bodySemibold)
                .foregroundStyle(JV.glass)
                .frame(maxWidth: .infinity)
                .frame(height: JV.buttonHeight)
                .background(RoundedRectangle(cornerRadius: JV.buttonRadius, style: .continuous).fill(JV.ink))
                .contentShape(RoundedRectangle(cornerRadius: JV.buttonRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: Settings rows

    private var permissionsRow: some View {
        let missing = permissions.missingCount
        return Button { show(.permissions) } label: {
            HStack(spacing: 8) {
                Text("Permissions")
                    .font(JV.bodyMedium)
                    .foregroundStyle(JV.ink)
                Spacer()
                Text(PermissionRowModel.summary(missing: missing))
                    .font(JV.meta)
                    .foregroundStyle(missing > 0 ? JV.ink : JV.ink3)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JV.ink3)
            }
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var alwaysAllowedRow: some View {
        let problem = confirmations.alwaysRulesProblem
        let unreadable = problem == HarnessConfirmations.unreadableRulesMessage
        return Button { show(.rules) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Always allowed")
                        .font(JV.bodyMedium)
                        .foregroundStyle(JV.ink)
                    Spacer()
                    Text(unreadable ? "Unreadable" : "\(confirmations.alwaysRules.count)")
                        .font(JV.meta)
                        .foregroundStyle(unreadable ? JV.ink : JV.ink3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(JV.ink3)
                }
                if let problem {
                    Text(problem)
                        .font(JV.caption)
                        .foregroundStyle(JV.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var voiceRow: some View {
        HStack {
            Text("Voice")
                .font(JV.bodyMedium)
                .foregroundStyle(JV.ink)
            Spacer()
            Menu {
                ForEach(VoiceStackChoice.allCases, id: \.self) { stack in
                    Button(stack.pickerLabel) { companionManager.setSelectedVoiceStack(stack) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(companionManager.selectedVoiceStack.pickerLabel)
                        .font(JV.body)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(JV.ink2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
        }
        .frame(height: 36)
    }
}

// MARK: - Permissions (a page inside the panel)

/// One compact row per permission, essentials first. "Allow" raises macOS's own prompt right here;
/// "Open Settings" lands on the exact pane once a prompt cannot return. Only the owner can answer
/// either, so the page says so once and each row says only what to flip.
struct PermissionsPage: View {
    @ObservedObject var permissions: JarvisPermissions
    let back: () -> Void
    let requestScreenContent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Permissions")
                        .font(JV.bodySemibold)
                }
                .foregroundStyle(JV.ink)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.horizontal, 16)

            Text("Only you can grant these. I raise macOS\u{2019}s prompt, or open the exact switch.")
                .font(JV.caption)
                .foregroundStyle(JV.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            section(PermissionRowModel.visible(JarvisPermission.essentials, readings: permissions.readings))
            Rectangle().fill(JV.hairline).frame(height: 1)
            section(JarvisPermission.onDemand)
        }
        .padding(.bottom, 6)
    }

    private func section(_ rows: [JarvisPermission]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.self) { row($0) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// One filled button on the page, the first thing to do; the rest stay quiet, so it never reads as a bill.
    private var firstAction: JarvisPermission? {
        (PermissionRowModel.visible(JarvisPermission.essentials, readings: permissions.readings) + JarvisPermission.onDemand)
            .first { model($0).button != nil }
    }

    private func model(_ permission: JarvisPermission) -> PermissionRowModel {
        PermissionRowModel.make(permission, permissions.readings[permission] ?? .unknownUntilUsed,
                                visitedSettings: permissions.visitedSettings.contains(permission))
    }

    private func row(_ permission: JarvisPermission) -> some View {
        let isOn = permissions.readings[permission] == .granted
        let model = model(permission)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOn ? JV.ink : Color.clear)
                    .overlay(Circle().strokeBorder(isOn ? Color.clear : JV.ink3, lineWidth: JV.stroke))
                    .frame(width: 8, height: 8)
                Text(permission.name)
                    .font(JV.bodyMedium)
                    .foregroundStyle(isOn ? JV.ink2 : JV.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let button = model.button { actionButton(button, on: permission, filled: permission == firstAction) }
                if isOn {
                    Text("On")
                        .font(JV.meta)
                        .foregroundStyle(JV.ink3)
                }
            }
            .frame(minHeight: 28)
            if model.detail != nil || model.secondary != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let detail = model.detail {
                        Text(detail)
                            .font(JV.caption)
                            .foregroundStyle(JV.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let secondary = model.secondary {
                        Button {
                            permissions.perform(secondary, on: permission, requestScreenContent: requestScreenContent)
                        } label: {
                            Text(secondary == .reopen ? "Reopen J.A.R.V.I.S." : secondary.title)
                                .font(JV.caption)
                                .underline()
                                .foregroundStyle(JV.ink)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(permission.name + (isOn ? ", on" : ", \(model.detail ?? "off")"))
    }

    private func actionButton(_ action: PermissionAction, on permission: JarvisPermission, filled: Bool) -> some View {
        Button {
            permissions.perform(action, on: permission, requestScreenContent: requestScreenContent)
        } label: {
            Text(action.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filled ? JV.glass : JV.ink)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: JV.bandRadius, style: .continuous).fill(filled ? JV.ink : JV.raised))
                .contentShape(RoundedRectangle(cornerRadius: JV.bandRadius, style: .continuous))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(action.title), \(permission.name)")
        .pointerCursor()
    }
}

// MARK: - Always allowed (a page inside the panel, not a window)

/// The rules an "Always" answer created. They live in the data-protection
/// keychain, which the `security` CLI cannot reach, so this page is the only
/// way to revoke one. Grouped by app; every row wraps its scope in full, never
/// cut ("exac…" hid what a consent covered). Remove takes effect at once and
/// needs no hardware click — it only narrows — and there is deliberately no
/// Undo: undo would recreate a rule without one.
struct AlwaysRulesPage: View {
    @ObservedObject var confirmations: HarnessConfirmations
    let back: () -> Void
    @State private var hoveredRemove: Int?
    @State private var listHeight: CGFloat = 0

    /// The app's name from the local install, never from the rule.
    static func installedAppName(_ bundleIdentifier: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) }
    }

    /// Rules by app, case-insensitive bundle id, in the order first saved.
    static func groups(_ rules: [HarnessConfirmations.ApprovalRule]) -> [[(index: Int, rule: HarnessConfirmations.ApprovalRule)]] {
        var order: [String] = []
        var byApp: [String: [(index: Int, rule: HarnessConfirmations.ApprovalRule)]] = [:]
        for (index, rule) in rules.enumerated() {
            let key = rule.bundleIdentifier.lowercased()
            if byApp[key] == nil { order.append(key) }
            byApp[key, default: []].append((index, rule))
        }
        return order.compactMap { byApp[$0] }
    }

    /// The card's question without "in "App"" — the group header names the app.
    static func rowTitle(_ summary: HarnessConfirmations.RuleSummary, appLabel: String) -> String {
        let suffix = " in " + UntrustedText(appLabel).forDisplayInFull
        return summary.title.hasSuffix(suffix) ? String(summary.title.dropLast(suffix.count)) : summary.title
    }

    /// Under the title, wrapping and never truncated: the typed text, where,
    /// and the scope — "exactly this" or "whole app".
    static func rowDetail(_ summary: HarnessConfirmations.RuleSummary) -> String {
        let place = summary.place == "any target" ? nil : summary.place
        let line = [summary.preview, place, summary.scope].compactMap { $0 }.joined(separator: " \u{00B7} ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Everything, qualifiers too, for the tooltip and the accessibility label.
    static func detailLine(_ summary: HarnessConfirmations.RuleSummary) -> String {
        ([summary.preview, summary.place, summary.scope].compactMap { $0 } + summary.qualifiers)
            .joined(separator: "  \u{00B7}  ")
    }

    /// The page scrolls inside the panel once it would pass this.
    private var maximumListHeight: CGFloat {
        max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 200)
    }

    var body: some View {
        let rules = confirmations.alwaysRules
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Always allowed")
                        .font(JV.bodySemibold)
                }
                .foregroundStyle(JV.ink)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 12) {
                Text("These run without a card. Removing one makes me ask again.")
                    .font(JV.caption)
                    .foregroundStyle(JV.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = confirmations.alwaysRulesProblem {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem)
                            .font(JV.body)
                            .foregroundStyle(JV.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = confirmations.alwaysRulesProblemDetail {
                            // The raw error never draws; it goes to the pasteboard on request.
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(detail, forType: .string)
                            } label: {
                                Text("Copy details").font(JV.caption).underline().foregroundStyle(JV.ink2)
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                } else if rules.isEmpty {
                    Text("Nothing is always allowed. Every risky action asks first.")
                        .font(JV.body)
                        .foregroundStyle(JV.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if !rules.isEmpty {
                Rectangle().fill(JV.hairline).frame(height: 1)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Self.groups(rules).enumerated()), id: \.offset) { position, group in
                            if position > 0 { Rectangle().fill(JV.hairline).frame(height: 1) }
                            appGroup(group)
                        }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in listHeight = height }
                    })
                }
                .scrollIndicators(listHeight > maximumListHeight ? .visible : .hidden)
                .frame(height: min(listHeight > 0 ? listHeight : CGFloat(rules.count) * 56, maximumListHeight))
            }
        }
        .onAppear { confirmations.refreshAlwaysRules() }
    }

    private func appGroup(_ group: [(index: Int, rule: HarnessConfirmations.ApprovalRule)]) -> some View {
        let bundle = group[0].rule.bundleIdentifier
        let installed = Self.installedAppName(bundle)
        let appLabel = installed ?? bundle
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                appIcon(bundle)
                Text(appLabel)
                    .font(JV.bodySemibold)
                    .foregroundStyle(JV.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(group, id: \.index) { item in
                ruleRow(item.rule, index: item.index, summary: HarnessConfirmations.ruleSummary(for: item.rule, appName: installed),
                        appLabel: appLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func appIcon(_ bundleIdentifier: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14))
                .foregroundStyle(JV.ink3)
                .frame(width: 20, height: 20)
        }
    }

    private func ruleRow(_ rule: HarnessConfirmations.ApprovalRule, index: Int, summary: HarnessConfirmations.RuleSummary,
                         appLabel: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.rowTitle(summary, appLabel: appLabel))
                    .font(JV.bodyMedium)
                    .foregroundStyle(JV.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.rowDetail(summary))
                    .font(JV.caption)
                    .foregroundStyle(JV.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { confirmations.removeAlwaysRule(rule) } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(hoveredRemove == index ? JV.ink : JV.ink3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredRemove = $0 ? index : (hoveredRemove == index ? nil : hoveredRemove) }
            .help("Remove \u{2014} I\u{2019}ll ask again next time")
            .accessibilityLabel("Remove")
            .pointerCursor()
        }
        .padding(.leading, 28)
        .help(summary.title + "\n" + Self.detailLine(summary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary.title + ", " + Self.detailLine(summary))
    }
}
