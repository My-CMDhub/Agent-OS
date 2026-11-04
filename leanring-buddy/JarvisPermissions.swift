//
//  JarvisPermissions.swift
//  leanring-buddy
//
//  What the panel's Permissions page shows, and asking macOS for what is missing.
//
//  macOS never lets an app grant itself anything. An app can raise the system's own prompt, once
//  per state, and after an answer the only path left is the exact Settings pane. So every row is
//  one of: on, "Allow" (macOS asks right there), "Open Settings" (with what to flip).
//
//  Reading never prompts. Mic, Accessibility, Screen Recording and EventKit have status calls that
//  cannot raise one. Files & Folders has none (any read of Desktop fires the prompt), so it reads
//  only on the owner's click and otherwise says "macOS asks on first use".
//
//  **A signature change orphans a grant while Settings still shows it on** (2026-11-04, tccd: "Failed
//  to match existing code requirement for subject com.dhruvpatel.jarvis.agent and service
//  kTCCServiceCalendar" at each refusal, printing the stored certificate 2K8329BH5J against the running
//  X77Z9NF9Y5). The row is keyed on the bundle id, so Settings lists it and its switch flips; its stored
//  code requirement names the old certificate, so to the running binary
//  there is no row and EventKit answers notDetermined (0), on every call since the 2026-10-30 signing
//  change. Hence: notDetermined is asked at the moment of need, never refused, and "already on in
//  Settings" is never read as granted.
//

import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import EventKit
import Foundation

/// One row on the page, essentials first.
nonisolated enum JarvisPermission: CaseIterable, Hashable, Sendable {
    case microphone, accessibility, screenRecording, screenContent, calendars, reminders, filesAndFolders

    static let essentials: [JarvisPermission] = [.microphone, .accessibility, .screenRecording, .screenContent]
    static let onDemand: [JarvisPermission] = [.calendars, .reminders, .filesAndFolders]

    var name: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .screenContent: "Screen Content"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .filesAndFolders: "Files & Folders"
        }
    }

    /// The exact pane; all six landed by window title on macOS 27.2 (2026-11-04). Accessibility's list of switches
    /// is titled "Device Control and Data Access" there. nil: Screen Content has no pane (a capture picker's answer).
    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .screenContent: return nil
        case .calendars: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .filesAndFolders: anchor = "Privacy_FilesAndFolders"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor)
    }
}

/// What macOS says right now, in the terms the page acts on.
nonisolated enum PermissionReading: Equatable, Sendable {
    case granted
    /// The system prompt can still appear.
    case neverAsked
    /// Answered no, or no prompt exists: only Settings can change it.
    case off
    /// EventKit write-only: events can be added but never read back, so nothing could be verified.
    case addOnly
    /// A device profile decides; nobody on this Mac can change it from here.
    case blocked
    /// EventKit was asked and came back still notDetermined: no prompt showed, an orphaned row holds it.
    case askedWithNoAnswer
    /// Files & Folders before the owner has asked: no API reads it without firing the prompt.
    case unknownUntilUsed
}

nonisolated enum PermissionAction: Equatable, Sendable {
    case ask, askAgain, openSettings, reopen

    var title: String {
        switch self {
        case .ask: "Allow"
        case .askAgain: "Ask again"
        case .openSettings: "Open Settings"
        case .reopen: "Reopen"
        }
    }
}

/// The state table: reading -> what the row says and offers. Pure, so a test holds it and nothing
/// prompts to check it. The list in Settings shows the app as "Clicky" (PRODUCT_NAME), so the copy does too.
nonisolated struct PermissionRowModel: Equatable, Sendable {
    /// nil when on: the dot says it.
    let detail: String?
    let button: PermissionAction?
    /// Under a Settings row macOS applies only on reopen.
    let secondary: PermissionAction?

    static func make(_ permission: JarvisPermission, _ reading: PermissionReading, visitedSettings: Bool) -> PermissionRowModel {
        func row(_ detail: String, _ button: PermissionAction?, _ secondary: PermissionAction? = nil) -> PermissionRowModel {
            PermissionRowModel(detail: detail, button: button, secondary: secondary)
        }
        let olderBuild = " Already on? An older build holds it: remove it with \u{2212}, then reopen me."
        switch (permission, reading) {
        case (_, .granted):
            return PermissionRowModel(detail: nil, button: nil, secondary: nil)
        case (_, .blocked):
            return row("Blocked by a device profile.", nil)
        case (.accessibility, _):
            // The prompt only points at Settings, and only the first press raises it. AX flips live; a stale row needs the reopen.
            return visitedSettings ? row("Turn on Clicky." + olderBuild, .openSettings, .reopen)
                : row("macOS sends you to Settings: turn on Clicky.", .ask)
        case (.screenRecording, _):
            // ponytail: "reopen" is the safe claim; whether the preflight flips live was not measured (needs the owner's switch).
            return visitedSettings ? row("Turn on Clicky, then reopen me." + olderBuild, .openSettings, .reopen)
                : row("Turn on Clicky, then reopen me.", .openSettings)
        case (.filesAndFolders, .off):
            return row("Off for at least one folder. Turn them on for Clicky.", .openSettings)
        case (.filesAndFolders, _):
            return row("macOS asks when I first open Desktop, Documents or Downloads.", .ask)
        case (.calendars, .off), (.reminders, .off):
            return row("Off. Turn on Clicky, with Full Access.", .openSettings)
        case (_, .addOnly):
            return row("Add only. I can\u{2019}t read back what I make: choose Full Access for Clicky.", .openSettings)
        case (_, .askedWithNoAnswer):
            return row("macOS kept an older build\u{2019}s entry and didn\u{2019}t ask. Asking again clears it.", .askAgain)
        case (_, .off):
            return row("Off. Turn on Clicky in Settings.", .openSettings)
        case (.calendars, _), (.reminders, _):
            return row("Not asked yet, even if Settings shows it on.", .ask)
        case (_, .neverAsked), (_, .unknownUntilUsed):
            return row("Not asked yet.", .ask)
        }
    }

    /// Screen Content exists only once Screen Recording is on (its check captures the screen).
    static func visible(_ permissions: [JarvisPermission], readings: [JarvisPermission: PermissionReading]) -> [JarvisPermission] {
        permissions.filter { $0 != .screenContent || readings[.screenRecording] == .granted }
    }

    /// What the Standby row counts. Files & Folders before use is not missing: nothing can say so.
    static func missingCount(_ readings: [JarvisPermission: PermissionReading]) -> Int {
        visible(JarvisPermission.allCases.filter { $0 != .filesAndFolders }, readings: readings)
            .filter { readings[$0] != .granted }.count + (readings[.filesAndFolders] == .off ? 1 : 0)
    }

    static func summary(missing: Int) -> String { missing == 0 ? "All on" : "\(missing) missing" }
}

// MARK: - EventKit access

/// Asking macOS for Calendars and Reminders. `status` reads live (the class method reaches tccd on
/// every call: 8 tccd lines per refusal, 2026-11-04), so no store has to be refreshed after a grant.
nonisolated enum EventKitAccess {
    static func status(_ entity: EKEntityType) -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: entity) }

    static func word(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .fullAccess: "fullAccess"
        case .writeOnly: "writeOnly"
        @unknown default: "unknown"
        }
    }

    static func reading(_ status: EKAuthorizationStatus, askedWithNoAnswer: Bool) -> PermissionReading {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .addOnly
        case .restricted: .blocked
        case .denied: .off
        case .notDetermined: askedWithNoAnswer ? .askedWithNoAnswer : .neverAsked
        @unknown default: .off
        }
    }

    /// Anything launched with a `--` argument (the harness, a suite, a probe, the dry run) and the unit-test
    /// host never prompt: a system prompt nobody answers stalled a suite for 3 h. The owner's normal launch does.
    static func isOwnerSession(arguments: [String], environment: [String: String]) -> Bool {
        !arguments.contains { $0.hasPrefix("--") } && environment["XCTestConfigurationFilePath"] == nil
    }

    static var isOwnerSession: Bool {
        isOwnerSession(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    }

    static func shouldAskAtMomentOfNeed(_ status: EKAuthorizationStatus, ownerSession: Bool) -> Bool {
        status == .notDetermined && ownerSession
    }

    /// Whether a task should plan on the EventKit tool: it works, or using it raises the prompt.
    private static func isUsable(_ entity: EKEntityType) -> Bool {
        let now = status(entity)
        return now == .fullAccess || shouldAskAtMomentOfNeed(now, ownerSession: isOwnerSession)
    }
    static var calendarsUsable: Bool { isUsable(.event) }
    static var remindersUsable: Bool { isUsable(.reminder) }

    private final class Asks: @unchecked Sendable {
        let lock = NSLock()
        var inFlight: [UInt: Task<EKAuthorizationStatus, Never>] = [:]
        var unanswered: Set<UInt> = []
    }
    private static let asks = Asks()

    static func wasAskedWithNoAnswer(_ entity: EKEntityType) -> Bool {
        asks.lock.withLock { asks.unanswered.contains(entity.rawValue) }
    }

    private static func isAsking(_ entity: EKEntityType) -> Bool {
        asks.lock.withLock { asks.inFlight[entity.rawValue] != nil }
    }

    /// Raises the system prompt (no-op once answered). One at a time per entity: a second caller joins the first.
    private static func startAsking(_ entity: EKEntityType) -> Task<EKAuthorizationStatus, Never> {
        asks.lock.withLock {
            if let running = asks.inFlight[entity.rawValue] { return running }
            let started = Task.detached { () -> EKAuthorizationStatus in
                let store = EKEventStore()
                var failure = "none"
                do {
                    _ = entity == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
                } catch { failure = "\((error as NSError).code)" }
                withExtendedLifetime(store) {}
                let after = status(entity)
                asks.lock.withLock {
                    asks.inFlight[entity.rawValue] = nil
                    if after == .notDetermined { asks.unanswered.insert(entity.rawValue) } else { asks.unanswered.remove(entity.rawValue) }
                }
                log("asked", entity, after, detail: "error: \(failure)")
                return after
            }
            asks.inFlight[entity.rawValue] = started
            return started
        }
    }

    /// The owner pressed Allow: the status after their answer.
    @discardableResult
    static func ask(_ entity: EKEntityType) async -> EKAuthorizationStatus { await startAsking(entity).value }

    /// For a tool about to touch Calendars or Reminders: notDetermined raises the prompt and waits for
    /// the owner's answer (the OS prompt is their consent); anything else returns the status at once.
    /// A prompt left unanswered stays up, and the tool goes on after `waitSeconds` with the honest refusal.
    @discardableResult
    static func requestIfAskable(_ entity: EKEntityType, waitSeconds: TimeInterval = 60) async -> EKAuthorizationStatus {
        guard shouldAskAtMomentOfNeed(status(entity), ownerSession: isOwnerSession) else { return status(entity) }
        _ = startAsking(entity)
        let deadline = Date().addingTimeInterval(waitSeconds)
        while isAsking(entity), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        return status(entity)
    }

    /// The dispatcher's one line: whichever entity this tool touches, asked if askable. Other tools return at once.
    static func requestIfAskable(forTool name: String) async {
        if let entity = entity(forTool: name) { await requestIfAskable(entity) }
    }

    /// Which tool needs which entity; nil for every other tool.
    static func entity(forTool name: String) -> EKEntityType? {
        switch name {
        case RealtimeVoiceVerbs.createEventName, RealtimeVoiceVerbs.readCalendarName: .event
        case RealtimeVoiceVerbs.createReminderName: .reminder
        default: nil
        }
    }

    /// The refusal the model reads out. Logs the real status, because every refusal once looked the same.
    static func notAuthorizedMessage(_ entity: EKEntityType, outcome: String, fallback: String, at site: String) -> String {
        let now = status(entity)
        log("refused", entity, now, detail: site)
        let app = entity == .event ? "Calendar" : "Reminders"
        return "J.A.R.V.I.S. has no full access to \(app) (status \(now.rawValue) \(word(now))); \(outcome). \(fallback). "
            + "To grant it the owner opens the menu bar panel, Permissions, \(entity == .event ? "Calendars" : "Reminders")"
    }

    /// `~/Library/Logs/Clicky/permissions.log`: one JSON line per ask and refusal, statuses only.
    private static func log(_ kind: String, _ entity: EKEntityType, _ status: EKAuthorizationStatus, detail: String) {
        let line: [String: Any] = ["wall": ISO8601DateFormatter().string(from: Date()), "kind": kind, "entity": entity == .event ? "calendars" : "reminders",
                                   "status": status.rawValue, "word": word(status), "detail": detail, "pid": ProcessInfo.processInfo.processIdentifier]
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("permissions.log").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

// MARK: - The page's state

/// Live readings while the panel is open: on open, every 1.5 s, and after a prompt answers.
@MainActor
final class JarvisPermissions: ObservableObject {
    static let shared = JarvisPermissions()

    @Published private(set) var readings: [JarvisPermission: PermissionReading]
    @Published private(set) var visitedSettings: Set<JarvisPermission>
    /// Files & Folders: nil until the owner's click has actually read the folders.
    private var filesReading: PermissionReading?
    private let isPinned: Bool
    private var watch: Timer?
    private var askingCount = 0
    private var settingsVisitedAt: Date?
    private var answeredAt: Date?

    init() {
        readings = [:]
        visitedSettings = []
        isPinned = false
    }

    /// UI snapshots: fixed readings, nothing is read and no button acts.
    init(pinned: [JarvisPermission: PermissionReading], visitedSettings: Set<JarvisPermission> = []) {
        readings = pinned
        self.visitedSettings = visitedSettings
        isPinned = true
    }

    var missingCount: Int { PermissionRowModel.missingCount(readings) }

    /// The panel is open: keep the rows live. Back from Settings the switch has already been read.
    func startWatching() {
        guard !isPinned else { return }
        refresh()
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in JarvisPermissions.shared.refresh() }
        }
    }

    func stopWatching() {
        watch?.invalidate()
        watch = nil
    }

    func refresh() {
        guard !isPinned else { return }
        let files = filesReading
        // Off main: EventKit's first read took 523 ms, its later ones 76 ms (harness audit, 2026-11-04).
        Task.detached {
            let read = Self.liveReadings(files: files)
            await MainActor.run { if self.readings != read { self.readings = read } }
        }
    }

    /// Never raises a prompt: every call here is a status read.
    nonisolated static func liveReadings(files: PermissionReading?) -> [JarvisPermission: PermissionReading] {
        let microphone: PermissionReading
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .neverAsked
        case .restricted: microphone = .blocked
        default: microphone = .off
        }
        return [
            .microphone: microphone,
            .accessibility: AXIsProcessTrusted() ? .granted : .off,
            .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .off,
            .screenContent: UserDefaults.standard.bool(forKey: "hasScreenContentPermission") ? .granted : .neverAsked,
            .calendars: EventKitAccess.reading(EventKitAccess.status(.event), askedWithNoAnswer: EventKitAccess.wasAskedWithNoAnswer(.event)),
            .reminders: EventKitAccess.reading(EventKitAccess.status(.reminder), askedWithNoAnswer: EventKitAccess.wasAskedWithNoAnswer(.reminder)),
            .filesAndFolders: files ?? .unknownUntilUsed
        ]
    }

    /// A system dialog is up or just answered: its click must not dismiss the panel behind it.
    var holdsPanelOpen: Bool {
        askingCount > 0 || answeredAt.map { Date().timeIntervalSince($0) < 1 } == true
    }

    /// Back from a Settings trip: reopening the panel lands on the same page, not Standby.
    var keepsPageOnReopen: Bool {
        settingsVisitedAt.map { Date().timeIntervalSince($0) < 300 } == true
    }

    func perform(_ action: PermissionAction, on permission: JarvisPermission, requestScreenContent: () -> Void) {
        guard !isPinned else { return }
        switch action {
        case .openSettings:
            // Screen Recording: the request lists the app in the pane (its dialog shows only the first time ever, and its
            // later no-ops are silent, so asking alone could look like a dead button).
            if permission == .screenRecording { _ = CGRequestScreenCaptureAccess() }
            openSettings(permission)
        case .reopen:
            Self.reopen()
        case .ask:
            switch permission {
            case .microphone: asking { await AVCaptureDevice.requestAccess(for: .audio) }
            case .accessibility:
                // The system alert the first time, Settings after: the row becomes Open Settings either way.
                WindowPositionManager.requestAccessibilityPermission()
                markVisited(permission)
            case .screenRecording: perform(.openSettings, on: permission, requestScreenContent: requestScreenContent)
            case .screenContent: requestScreenContent()
            case .calendars: asking { await EventKitAccess.ask(.event) }
            case .reminders: asking { await EventKitAccess.ask(.reminder) }
            case .filesAndFolders:
                asking {
                    let read = await Task.detached { Self.readFolders() }.value
                    await MainActor.run { JarvisPermissions.shared.filesReading = read }
                }
            }
        case .askAgain:
            let entity: EKEntityType = permission == .reminders ? .reminder : .event
            let service = permission == .reminders ? "Reminders" : "Calendar"
            asking {
                await Task.detached { Self.forgetOwnEntry(service: service) }.value
                await EventKitAccess.ask(entity)
            }
        }
    }

    private func openSettings(_ permission: JarvisPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
        markVisited(permission)
    }

    private func markVisited(_ permission: JarvisPermission) {
        visitedSettings.insert(permission)
        settingsVisitedAt = Date()
    }

    private func asking<Result: Sendable>(_ work: @escaping @Sendable () async -> Result) {
        askingCount += 1
        Task {
            _ = await work()
            askingCount -= 1
            answeredAt = Date()
            refresh()
        }
    }

    /// Listing a folder is what fires its prompt; counts are read, names never kept. Blocks until answered.
    nonisolated private static func readFolders() -> PermissionReading {
        let readable = ["Desktop", "Documents", "Downloads"].filter {
            (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/" + $0)) != nil
        }
        return readable.count == 3 ? .granted : .off
    }

    /// The owner's click only, and only this app's own row in one service: removes the entry an older
    /// signature left, so the next ask can prompt. Never run on anyone else's behalf.
    nonisolated private static func forgetOwnEntry(service: String) {
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundle]
        try? process.run()
        process.waitUntilExit()
    }

    /// A fresh copy of this app, then this one quits: Screen Recording applies on the next launch.
    static func reopen() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
