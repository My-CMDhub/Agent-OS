//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Darwin
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Measurement only: shortcut transitions, tap disables and Secure Event
    /// Input changes. Never the key codes of any other key.
    static let hotkeyEventLogFileName = "hotkey-events.log"

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// While any app holds Secure Event Input (Terminal's Secure Keyboard Entry,
    /// a password field, 1Password), our tap stops receiving keyboard events.
    /// Nothing tells us when that starts, so it is polled once a second.
    private var secureEventInputPollTimer: Timer?
    private var lastObservedSecureEventInputEnabled: Bool?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)

        recordSecureEventInputChangeIfAny()
        let pollTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // Added to the main run loop below, so this always runs on main.
            MainActor.assumeIsolated { self?.recordSecureEventInputChangeIfAny() }
        }
        RunLoop.main.add(pollTimer, forMode: .common)
        secureEventInputPollTimer = pollTimer
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        secureEventInputPollTimer?.invalidate()
        secureEventInputPollTimer = nil
        lastObservedSecureEventInputEnabled = nil

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Read first, before any work of ours, so the delay is the system's and not this function's.
        let callbackUptimeNanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            Self.appendHotkeyEvent([
                "event": eventType == .tapDisabledByTimeout ? "tapDisabledByTimeout" : "tapDisabledByUserInput"
            ])
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            recordShortcutTransition("pressed", event: event, callbackUptimeNanoseconds: callbackUptimeNanoseconds)
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            recordShortcutTransition("released", event: event, callbackUptimeNanoseconds: callbackUptimeNanoseconds)
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Measurement

    private func recordShortcutTransition(_ transitionName: String, event: CGEvent, callbackUptimeNanoseconds: UInt64) {
        Self.appendHotkeyEvent([
            "event": transitionName,
            "tapDelayMs": Self.tapDelayMilliseconds(
                eventTimestamp: event.timestamp,
                callbackUptimeNanoseconds: callbackUptimeNanoseconds
            ) ?? NSNull(),
            "secureInputEnabled": IsSecureEventInputEnabled()
        ])
    }

    private func recordSecureEventInputChangeIfAny() {
        let isEnabled = IsSecureEventInputEnabled()
        guard isEnabled != lastObservedSecureEventInputEnabled else { return }
        // The first reading is logged too, marked initial: a change can only be
        // read against the state it changed from.
        Self.appendHotkeyEvent([
            "event": lastObservedSecureEventInputEnabled == nil ? "secureInputInitialState" : "secureInputChanged",
            "secureInputEnabled": isEnabled
        ])
        lastObservedSecureEventInputEnabled = isEnabled
    }

    /// How long the event waited between the system stamping it and our callback
    /// running — which includes any time the main thread was busy.
    ///
    /// `CGEventTimestamp` is nanoseconds on `CLOCK_UPTIME_RAW`, NOT mach ticks.
    /// Verified 2026-09-13 on this Apple Silicon machine with a listen-only tap:
    /// a real mouse-moved event read 17 ms behind `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`,
    /// and an impossible 7.3e12 against `mach_absolute_time()` — the timebase here
    /// is 125/3, so ticks and nanoseconds differ by 41.7x. Synthetic events built
    /// with `CGEvent(source:)` carry timestamp 0 until posted, hence the nil.
    nonisolated static func tapDelayMilliseconds(eventTimestamp: CGEventTimestamp, callbackUptimeNanoseconds: UInt64) -> Double? {
        guard eventTimestamp > 0, callbackUptimeNanoseconds >= eventTimestamp else { return nil }
        return (Double(callbackUptimeNanoseconds - eventTimestamp) / 100_000).rounded() / 10
    }

    private static func appendHotkeyEvent(_ fields: [String: Any]) {
        var line = fields
        line["atUptime"] = MeasurementLogFile.roundedUptime(ProcessInfo.processInfo.systemUptime)
        MeasurementLogFile.appendJSONLine(line, toFileNamed: hotkeyEventLogFileName)
    }
}
