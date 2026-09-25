//
//  JarvisNotch.swift
//  leanring-buddy
//
//  The notch: the one place J.A.R.V.I.S. shows state. Contract:
//  docs/specs/2026-09-24-notch-design.md. It hugs the hardware camera notch
//  (black on black, invisible when idle) and grows sideways or down for a
//  state; with no notch, the same pill hangs from top-centre under the menu bar.
//
//  Every state is a real voice or harness event, never an optimistic one: intent
//  only from the model's tool call, proof only from the harness's `ok: true`.
//  Cyan appears for exactly one thing, the proof ring, so it comes to mean proof.
//
//  Manners: a borderless non-activating panel, click-through, never key or main
//  (a key panel once made the focused app read "Clicky" and broke the planner).
//
//  Pure parts first — state machine, reason map, geometry, level, ticks — so a
//  test reaches them; the panel and the SwiftUI drawing after.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import SwiftUI

// MARK: - State machine

nonisolated enum JarvisNotchShape: Equatable, Sendable {
    /// The hardware notch itself, or nothing when there is none.
    case idle
    /// Widened sideways into the menu-bar row; a glyph in the left wing.
    case compact
    /// Widened and dropped one text line below the notch.
    case expanded
}

nonisolated enum JarvisNotchState: Hashable, Sendable {
    case idle
    case listening
    case thinking
    /// Text arrives already made safe (`RealtimeOpenAppTool.captionName`): the
    /// model or the target app wrote the names in it, and a newline must not
    /// forge a second line. `title` is the whole line ("Opening Finder…");
    /// `subject` is what was verified ("Finder", "View › as List").
    case intent(title: String)
    case proof(subject: String)
    case needsYou
    case didntTake(reason: String)

    var name: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .intent: return "intent"
        case .proof: return "proof"
        case .needsYou: return "needsYou"
        case .didntTake: return "didntTake"
        }
    }

    var shape: JarvisNotchShape {
        switch self {
        case .idle: return .idle
        case .listening, .thinking: return .compact
        case .intent, .proof, .needsYou, .didntTake: return .expanded
        }
    }

    /// Seconds before it collapses by itself; nil holds until the next event.
    var holdSeconds: Double? {
        switch self {
        case .proof: return 1.8
        case .didntTake: return 2.5
        default: return nil
        }
    }

    /// The line's two parts: the title at white 92%, the detail at white 64%.
    var title: String? {
        switch self {
        case .intent(let title): return title
        case .proof(let subject): return subject
        case .needsYou: return "Needs you"
        case .didntTake: return "Didn\u{2019}t take"
        default: return nil
        }
    }

    var detail: String? {
        switch self {
        case .proof: return " \u{2014} verified"
        case .needsYou: return " \u{2014} approve on the card"
        case .didntTake(let reason): return " \u{2014} \(reason)"
        default: return nil
        }
    }

    /// VoiceOver hears proof, needs you and didn't take; listening and thinking are silent.
    var announcement: String? {
        switch self {
        case .proof(let subject): return "\(subject) verified"
        case .needsYou: return "Needs you. Approve on the card."
        case .didntTake(let reason): return "Didn\u{2019}t take. \(reason)"
        default: return nil
        }
    }

    func next(on event: JarvisNotchEvent) -> JarvisNotchState? {
        switch event {
        case .hotkeyDown:
            return .listening
        case .hotkeyUp:
            return self == .listening ? .thinking : nil
        case .firstAudioWithoutTool:
            return self == .thinking ? .idle : nil
        case .toolCall(let title):
            // A new press is already listening; its turn owns the notch now.
            return self == .listening ? nil : .intent(title: title)
        case .confirmationRequired:
            if case .intent = self { return .needsYou }
            return nil
        case .harnessAnswered(let ok, let subject, let error):
            switch self {
            case .intent, .needsYou:
                return ok ? .proof(subject: subject) : .didntTake(reason: JarvisNotchReason.plain(forErrorCode: error))
            default:
                return nil
            }
        case .holdElapsed:
            return holdSeconds == nil ? nil : .idle
        case .turnEnded:
            switch self {
            case .thinking, .intent, .needsYou: return .idle
            default: return nil
            }
        }
    }
}

nonisolated enum JarvisNotchEvent: Equatable, Sendable {
    case hotkeyDown
    case hotkeyUp
    /// The model spoke and no tool was called (yet).
    case firstAudioWithoutTool
    /// Before the harness request; `title` is the intent line.
    case toolCall(title: String)
    /// A ticket is open; the card is waiting on the owner.
    case confirmationRequired
    /// `ok` is the harness's own `ok`, never the model's word.
    case harnessAnswered(ok: Bool, subject: String, error: String?)
    case holdElapsed
    /// The turn failed or was abandoned.
    case turnEnded
}

// MARK: - Reason map

/// Harness error code -> the plain words after "Didn't take —". At most 36
/// characters each (a test holds that), so the line never truncates.
nonisolated enum JarvisNotchReason {
    static let maximumLength = 36
    static let fallback = "it couldn\u{2019}t be verified"

    static let byErrorCode: [String: String] = [
        "notFound": "no app by that name",
        "ambiguous": "more than one app has that name",
        "missingAppName": "no app was named",
        "screenIsLocked": "the screen is locked",
        "targetIsHarnessItself": "it can\u{2019}t act on itself",
        "launchFailed": "macOS wouldn\u{2019}t launch it",
        "launchNotReady": "it never came to the front",
        "notObserved": "no change was seen",
        "frontmostChanged": "another app came forward",
        "killSwitch": "the kill switch is on",
        "kernelRefused": "refused by the safety rules",
        "policyRefused": "your policy blocks that app",
        "policyUnreadable": "the policy file is unreadable",
        "confirmationDenied": "you declined on the card",
        "confirmationExpired": "the card timed out",
        "confirmationStale": "the selection changed",
        "confirmationTicketInvalid": "the approval didn\u{2019}t match",
        "tooManyPendingConfirmations": "too many cards waiting",
        "unknownTool": "that isn\u{2019}t something I can do",
        "tooManyToolCalls": "too many tries in one turn",
        "unreadableHarnessResponse": "the harness didn\u{2019}t answer",
        "dryRun": "dry run, nothing was done",
        // The menu and focus verbs (2026-09-25).
        "notVerified": "no change was seen",
        "targetIsSubmenu": "that item opens a submenu",
        "noMenuBar": "that app has no menu bar",
        "noFrontmostApplication": "nothing is in front",
        "windowListUnreadable": "its windows didn\u{2019}t answer",
        "missingMenuPath": "no menu item was named",
        "privateMenuItem": "that menu item is private",
        // The app check on the menu verbs: the named app, and only it.
        "appMismatch": "a different app is in front",
        "ambiguousApp": "more than one app has that name",
        "appNotInstalled": "no app by that name"
    ]

    static func plain(forErrorCode code: String?) -> String {
        code.flatMap { byErrorCode[$0] } ?? fallback
    }
}

// MARK: - Geometry

/// All in AppKit coordinates (origin bottom-left, y up). The panel never
/// resizes: it is sized once for the expanded pill and the pill animates inside it.
nonisolated struct JarvisNotchGeometry: Equatable, Sendable {
    static let wingWidth: CGFloat = 34
    static let expandedSideWidth: CGFloat = 150
    static let textBandHeight: CGFloat = 30
    static let noNotchCompactSize = CGSize(width: 68, height: 28)
    static let noNotchExpandedHeight: CGFloat = 32
    /// The no-notch pill hangs this far under the menu bar.
    static let noNotchGap: CGFloat = 6
    /// Room round the widest pill for its shadow (blur 14, y 4) and the shoulders.
    static let margin: CGFloat = 24

    let hasNotch: Bool
    /// With a notch, the hardware notch; without, a zero-size point at
    /// top-centre just under the menu bar, where the pill hangs from.
    let anchor: CGRect

    /// The notch is the gap between the two auxiliary top areas. Only their
    /// WIDTHS are used, so it does not matter whether they are reported in
    /// global or screen-local coordinates.
    static func resolve(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeftWidth: CGFloat?,
                        auxiliaryTopRightWidth: CGFloat?, menuBarHeight: CGFloat) -> JarvisNotchGeometry {
        if safeAreaTop > 0, let left = auxiliaryTopLeftWidth, let right = auxiliaryTopRightWidth {
            let notchWidth = screenFrame.width - left - right
            if notchWidth > 0 {
                return JarvisNotchGeometry(hasNotch: true, anchor: CGRect(
                    x: screenFrame.minX + left, y: screenFrame.maxY - safeAreaTop, width: notchWidth, height: safeAreaTop))
            }
        }
        return JarvisNotchGeometry(hasNotch: false, anchor: CGRect(
            x: screenFrame.midX, y: screenFrame.maxY - menuBarHeight - noNotchGap, width: 0, height: 0))
    }

    func pillSize(_ shape: JarvisNotchShape) -> CGSize {
        switch (hasNotch, shape) {
        case (true, .idle): return anchor.size
        case (true, .compact): return CGSize(width: anchor.width + 2 * Self.wingWidth, height: anchor.height)
        case (true, .expanded):
            return CGSize(width: anchor.width + 2 * Self.expandedSideWidth, height: anchor.height + Self.textBandHeight)
        case (false, .idle): return .zero
        case (false, .compact): return Self.noNotchCompactSize
        case (false, .expanded): return CGSize(width: 2 * Self.expandedSideWidth, height: Self.noNotchExpandedHeight)
        }
    }

    /// Top edge on the anchor's top, centred on it.
    var panelFrame: CGRect {
        let expanded = pillSize(.expanded)
        let width = expanded.width + 2 * Self.margin
        let height = expanded.height + Self.margin
        return CGRect(x: anchor.midX - width / 2, y: anchor.maxY - height, width: width, height: height)
    }

    /// The screen under the cursor — the one the owner is looking at when he presses.
    @MainActor static func forScreen(_ screen: NSScreen) -> JarvisNotchGeometry {
        resolve(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width,
                menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
    }
}

// MARK: - Mic level

nonisolated enum JarvisNotchLevel {
    static let floorDecibels: Float = -50
    static let ceilingDecibels: Float = -10

    /// RMS (0...1 full scale) -> 0...1 for the bars, on a dB scale so speech
    /// at a normal distance moves them and silence leaves them at rest.
    static func normalised(rms: Float) -> CGFloat {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return CGFloat(min(1, max(0, (decibels - floorDecibels) / (ceilingDecibels - floorDecibels))))
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// Little-endian PCM16, as the fixtures and the providers carry it.
    static func rms(pcm16: Data) -> Float {
        let count = pcm16.count / 2
        guard count > 0 else { return 0 }
        let sumOfSquares = pcm16.withUnsafeBytes { raw in
            (0..<count).reduce(Float(0)) { sum, index in
                let sample = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
                return sum + sample * sample
            }
        }
        return (sumOfSquares / Float(count)).squareRoot()
    }
}

// MARK: - Ticks

/// The only two sounds: hotkey down (a rising two-partial tick, a hint of
/// arc-reactor whine) and hotkey up (lighter, falling). Synthesised, not files.
nonisolated enum JarvisNotchTick: CaseIterable, Sendable {
    case press
    case release

    static let sampleRate = 48_000.0

    var durationSeconds: Double { self == .press ? 0.060 : 0.045 }
    /// Peak level: press at the contract's -24 dBFS, release lighter.
    var peakDecibels: Float { self == .press ? -24 : -28 }
    private var startHertz: Double { self == .press ? 1_600 : 2_100 }
    private var endHertz: Double { self == .press ? 2_300 : 1_500 }
    private var upperPartialLevel: Double { self == .press ? 0.5 : 0.35 }

    /// Two partials (f and 1.5 f) gliding together, 4 ms attack, exponential
    /// decay, then scaled so the loudest sample sits exactly at `peakDecibels`.
    var samples: [Float] {
        let count = Int(durationSeconds * Self.sampleRate)
        var phase = 0.0
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let progress = Double(index) / Double(count)
            let frequency = startHertz + (endHertz - startHertz) * progress
            phase += 2 * Double.pi * frequency / Self.sampleRate
            let time = Double(index) / Self.sampleRate
            let envelope = min(1, time / 0.004) * exp(-progress * 5)
            output[index] = Float(envelope * (sin(phase) + upperPartialLevel * sin(1.5 * phase)))
        }
        let peak = output.map(abs).max() ?? 0
        guard peak > 0 else { return output }
        let target = pow(10, peakDecibels / 20)
        return output.map { $0 * target / peak }
    }

    /// The default output device's mute switch. Unreadable counts as not muted.
    static func systemOutputIsMuted() -> Bool {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return false }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    @MainActor func buffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = self.samples
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

// MARK: - The notch

@MainActor
final class JarvisNotch {
    static let shared = JarvisNotch()

    struct Transition {
        let state: String
        let uptime: TimeInterval
        /// Only while `frontmostWitness` is set (the probe).
        let frontmostBefore: String?
        let frontmostAfter: String?
    }

    private let model = JarvisNotchModel()
    private var panel: JarvisNotchPanel?
    private var generation = 0
    private(set) var state: JarvisNotchState = .idle
    /// The last 64, for the live line and the probe.
    private(set) var transitions: [Transition] = []

    /// Probe only: the harness's own frontmost read, taken either side of each
    /// transition. nil in the live loop — an AX read per state is not free.
    var frontmostWitness: (() -> String?)?
    /// Probe only: screenshots.
    var onTransition: ((JarvisNotchState) -> Void)?

    private init() {}

    /// Applies an event; returns the new state, or nil when the event does not
    /// move this state (a late answer after a new press, say).
    @discardableResult
    func handle(_ event: JarvisNotchEvent) -> JarvisNotchState? {
        guard let next = state.next(on: event) else { return nil }
        if event == .hotkeyDown || panel == nil { placeOnScreenUnderCursor() }
        let before = frontmostWitness?()
        state = next
        generation += 1
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if next != .listening { model.level = 0 }
        model.state = next
        let shown = generation
        if next == .idle {
            // After the collapse has played out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.panel?.orderOut(nil)
            }
        } else {
            panel?.orderFrontRegardless()
        }
        if let seconds = next.holdSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.handle(.holdElapsed)
            }
        }
        if let announcement = next.announcement {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
        transitions.append(Transition(state: next.name, uptime: ProcessInfo.processInfo.systemUptime,
                                      frontmostBefore: before, frontmostAfter: frontmostWitness?()))
        if transitions.count > 64 { transitions.removeFirst(transitions.count - 64) }
        onTransition?(next)
        return next
    }

    /// Mic RMS, from the audio thread via main. Moves the bars only while listening.
    func setLevel(rms: Float) {
        guard state == .listening else { return }
        model.level = JarvisNotchLevel.normalised(rms: rms)
    }

    /// Where the panel sits, for the probe's screenshots.
    var panelFrame: CGRect? { panel?.frame }

    private func placeOnScreenUnderCursor() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let geometry = JarvisNotchGeometry.forScreen(screen)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.geometry = geometry
        panel.setFrame(geometry.panelFrame, display: true)
    }

    private func makePanel() -> JarvisNotchPanel {
        let panel = JarvisNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the menu bar (24) and the status items (25); below pop-up menus (101).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        let hostingView = NSHostingView(rootView: JarvisNotchView(model: model))
        // The panel's frame is the geometry's, never the content's.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }
}

/// Never key, never main, and allowed into the menu-bar band.
private final class JarvisNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class JarvisNotchModel: ObservableObject {
    @Published var state: JarvisNotchState = .idle
    @Published var level: CGFloat = 0
    @Published var reduceMotion = false
    @Published var geometry = JarvisNotchGeometry(hasNotch: false, anchor: .zero)
}

// MARK: - Drawing

private enum JarvisNotchStyle {
    /// Arc reactor. The proof ring and its glow, nothing else.
    static let proofCyan = Color(red: 0x3F / 255, green: 0xE0 / 255, blue: 0xFF / 255)
    static let strokeWidth: CGFloat = 1.5
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

private struct JarvisNotchView: View {
    @ObservedObject var model: JarvisNotchModel

    var body: some View {
        let geometry = model.geometry
        let panelSize = geometry.panelFrame.size
        ZStack(alignment: .top) {
            if model.reduceMotion {
                // No spring: each state's pill crossfades in whole.
                pill.id(model.state.shape).transition(.opacity)
            } else {
                pill
            }
        }
        .animation(model.reduceMotion ? .easeInOut(duration: 0.15) : JarvisNotchStyle.spring, value: model.state.shape)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var pill: some View {
        let geometry = model.geometry
        let size = geometry.pillSize(model.state.shape)
        let shoulder: CGFloat = geometry.hasNotch && model.state.shape != .idle ? 6 : 0
        let bottomRadius: CGFloat = model.state.shape == .expanded ? 14 : min(10, size.height / 2)
        let outline = NotchPillShape(shoulder: shoulder, bottomRadius: bottomRadius, topRadius: geometry.hasNotch ? 0 : bottomRadius)
        return outline
            .fill(Color.black)
            .overlay {
                // No black hardware to blend into: the one case with a border.
                if !geometry.hasNotch { outline.stroke(Color.white.opacity(0.08), lineWidth: 1) }
            }
            .overlay {
                if model.state == .needsYou { NeedsYouPulse(outline: outline, still: model.reduceMotion) }
            }
            .overlay { content(size: size, shoulder: shoulder) }
            .overlay(alignment: .bottom) {
                if case .proof = model.state, !model.reduceMotion {
                    ProofGlow(width: size.width).padding(.horizontal, shoulder)
                }
            }
            .clipShape(outline)
            .frame(width: size.width + 2 * shoulder, height: size.height)
            .shadow(color: geometry.hasNotch ? .clear : .black.opacity(0.35), radius: 7, x: 0, y: 4)
            .opacity(!geometry.hasNotch && model.state == .idle ? 0 : 1)
    }

    @ViewBuilder
    private func content(size: CGSize, shoulder: CGFloat) -> some View {
        let geometry = model.geometry
        switch model.state.shape {
        case .idle:
            EmptyView()
        case .compact:
            HStack(spacing: 0) {
                glyph.frame(width: geometry.hasNotch ? JarvisNotchGeometry.wingWidth : size.width)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, shoulder)
        case .expanded:
            VStack(spacing: 0) {
                if geometry.hasNotch { Color.clear.frame(height: geometry.anchor.height) }
                HStack(spacing: 8) {
                    glyph.frame(width: 16, height: 16)
                    line
                }
                .padding(.horizontal, 16 + shoulder)
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// One identity for intent and proof, so the open arc can close into the ring.
    @ViewBuilder
    private var glyph: some View {
        switch model.state {
        case .listening:
            ListeningBars(level: model.level)
        case .thinking:
            ThinkingDot(still: model.reduceMotion)
        case .intent, .proof:
            ArcRing(closed: { if case .proof = model.state { return true }; return false }(), still: model.reduceMotion)
        case .needsYou:
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
        case .didntTake:
            Image(systemName: "circle.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
        case .idle:
            EmptyView()
        }
    }

    private var line: some View {
        (Text(model.state.title ?? "").foregroundColor(.white.opacity(0.92))
            + Text(model.state.detail ?? "").foregroundColor(.white.opacity(0.64)))
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .id(model.state)
            .transition(.opacity)
            .animation(.easeInOut(duration: model.reduceMotion ? 0.15 : 0.12), value: model.state)
    }
}

/// The pill: flat top, rounded bottom. With a notch the top corners flow out
/// into the menu bar as concave shoulders, like the hardware notch's own.
private struct NotchPillShape: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        let bottom = min(bottomRadius, (right - left) / 2, rect.height / 2)
        let top = min(topRadius, (right - left) / 2, rect.height / 2)
        var path = Path()
        // Down the left: from the shoulder's outer tip, or from a rounded corner.
        if top > 0 {
            path.move(to: CGPoint(x: left + top, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + top), control: CGPoint(x: left, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder), control: CGPoint(x: left, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - bottom), control: CGPoint(x: right, y: rect.maxY))
        // Up the right, mirrored; closing runs back along the top edge.
        if top > 0 {
            path.addLine(to: CGPoint(x: right, y: rect.minY + top))
            path.addQuadCurve(to: CGPoint(x: right - top, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

private struct ListeningBars: View {
    let level: CGFloat
    /// The middle bar leads; the outer ones follow at a fraction, so one level reads as a voice, not a meter.
    private static let weights: [CGFloat] = [0.5, 0.8, 1, 0.75, 0.45]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: 3 + 11 * level * Self.weights[index])
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: level)
    }
}

private struct ThinkingDot: View {
    let still: Bool
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.7))
            .frame(width: 5, height: 5)
            .opacity(still ? 0.85 : (bright ? 1.0 : 0.6))
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// The signature: an open arc turning slowly while the harness works, which
/// closes into a full ring and fills cyan when it has verified. Authored, not borrowed.
private struct ArcRing: View {
    let closed: Bool
    let still: Bool

    var body: some View {
        TimelineView(.animation(paused: closed || still)) { context in
            let degrees = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360
            ZStack {
                Circle()
                    .fill(JarvisNotchStyle.proofCyan)
                    .scaleEffect(closed ? 0.62 : 0.2)
                    .opacity(closed ? 1 : 0)
                Circle()
                    .trim(from: 0, to: closed ? 1 : 0.72)
                    .stroke(closed ? JarvisNotchStyle.proofCyan : Color.white.opacity(0.7),
                            style: StrokeStyle(lineWidth: JarvisNotchStyle.strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(closed || still ? -90 : degrees))
            }
            .frame(width: 14, height: 14)
        }
        .animation(still ? nil : .easeOut(duration: 0.45), value: closed)
    }
}

/// One cyan glow travelling the bottom edge once, 600 ms.
private struct ProofGlow: View {
    let width: CGFloat
    @State private var progress: CGFloat = 0

    var body: some View {
        Capsule()
            .fill(JarvisNotchStyle.proofCyan)
            .frame(width: 56, height: 2)
            .blur(radius: 2.5)
            .modifier(TravelAlongEdge(progress: progress, width: width))
            .onAppear { withAnimation(.easeInOut(duration: 0.6)) { progress = 1 } }
    }
}

private struct TravelAlongEdge: ViewModifier, Animatable {
    var progress: CGFloat
    let width: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: (progress - 0.5) * (width - 40))
            .opacity(Double(sin(progress * .pi)))
    }
}

/// A slow white-40% outline pulse while the card waits; static under Reduce Motion.
private struct NeedsYouPulse: View {
    let outline: NotchPillShape
    let still: Bool
    @State private var bright = false

    var body: some View {
        outline
            .stroke(Color.white.opacity(0.4), lineWidth: 1)
            .opacity(still ? 1 : (bright ? 1 : 0.25))
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}
