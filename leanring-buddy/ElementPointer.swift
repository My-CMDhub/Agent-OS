//
//  ElementPointer.swift
//  leanring-buddy
//
//  The voice loop's `point_at`, drawn: a blue cursor flies from the mouse to a
//  control's exact frame (resolved from structure by the harness's
//  `highlight`), then marks it in a shape that follows its role, holds, and
//  fades. Read-only: it touches only its own click-through window.
//
//  Beside the legacy buddy cursor, not through it. That cursor is driven by
//  `CompanionManager`'s published `detectedElementScreenLocation` — a POINT
//  that only the legacy `[POINT:x,y]` flow sets, drawn by one view per screen
//  that may be hidden by the cursor toggle and is tied to its speech bubble.
//  Driving it from a frame would mean reaching into that god-object's state.
//
//  The WINDOW itself flies: it starts as a small square at the mouse and is
//  animated to the element's frame plus a margin, so its final frame is the
//  target — which `--point-probe` reads back from the window server.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

/// How the pointer marks an element, by what the owner would do with it.
nonisolated enum ElementPointerShape: Equatable, Sendable {
    /// Icon, button, checkbox, toggle: a pulsing ring around it.
    case ring
    /// Text or a link: a stroke drawn under it, left to right.
    case underline
    /// A field, a group, anything large: a rounded outline traced once.
    case outline
    /// Nothing nameable at the point the model gave: a dashed ring, approximate.
    case approximate

    /// Larger than this either way is an area, not a control.
    static let areaSidePoints: CGFloat = 120

    static func forElement(role: String, size: CGSize) -> ElementPointerShape {
        if size.width > areaSidePoints || size.height > areaSidePoints { return .outline }
        switch role {
        case "AXLink", "AXStaticText": return .underline
        case "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle", "AXImage":
            return .ring
        default: return .outline
        }
    }
}

/// One pointer at a time: a new point cancels the old (the flight, the hold and
/// the fade all check `generation`). Main thread only, like `ElementHighlightOverlay`.
enum ElementPointer {
    static let flightSeconds = 0.4
    static let fadeSeconds = 0.3
    /// Room around the frame for the ring and its pulse.
    static let marginPoints: CGFloat = 8
    private static let startSidePoints: CGFloat = 24

    /// The approximate ring's side, around the point.
    static let approximateSidePoints: CGFloat = 44
    /// After the reply about it stops playing, it lingers this long.
    static let fadeAfterSpeechSeconds = 0.6
    /// Never held longer than this, whatever is still speaking.
    static let maximumHoldSeconds = 30.0

    /// The voice session's "still being talked about": its reply audio plays or
    /// its turn is unfinished (`RealtimeVoiceSession`). Used only for a pointer
    /// shown with `followSpeech` (the voice loop's `speechHold` requests); every
    /// other pointer — a socket caller's — holds for its own `seconds`.
    static var holdWhile: (() -> Bool)?
    /// Shown (true) / hidden (false), with the uptime: the live line's timings.
    static var onVisibilityChange: ((Bool, TimeInterval) -> Void)?

    private static var window: OverlayWindow?
    private static var generation = 0

    /// Pure: hide once `active` has been false for `fadeAfterSpeechSeconds`,
    /// or at `maximumHoldSeconds` after showing.
    static func holdDecision(active: Bool, inactiveSince: TimeInterval?, now: TimeInterval,
                             shownAt: TimeInterval) -> (hide: Bool, inactiveSince: TimeInterval?) {
        if now - shownAt >= maximumHoldSeconds { return (true, inactiveSince) }
        if active { return (false, nil) }
        let since = inactiveSince ?? now
        return (now - since >= fadeAfterSpeechSeconds - 1e-9, since)
    }

    /// The next press or point takes it away at once.
    static func hide() {
        guard window != nil else { return }
        generation += 1
        dismiss(window)
    }

    private static func dismiss(_ overlay: OverlayWindow?) {
        overlay?.orderOut(nil)
        if overlay === window {
            window = nil
            currentTarget = nil
            onVisibilityChange?(false, ProcessInfo.processInfo.systemUptime)
        }
    }

    /// The window now showing and the element frame it marks (AppKit), for
    /// `--point-probe`'s window-server witness. nil when nothing is shown.
    static var current: (windowNumber: Int, target: CGRect)? {
        guard let window, let target = currentTarget else { return nil }
        return (window.windowNumber, target)
    }
    private static var currentTarget: CGRect?

    /// The window's frame once it has arrived: the element plus the margin.
    static func arrivedFrame(for rectInAppKitCoordinates: CGRect) -> CGRect {
        rectInAppKitCoordinates.insetBy(dx: -marginPoints, dy: -marginPoints)
    }

    static func show(_ rectInAppKitCoordinates: CGRect, role: String, seconds: Double, approximate: Bool = false, followSpeech: Bool = false) {
        dismiss(window)
        generation += 1
        let shown = generation
        let target = arrivedFrame(for: rectInAppKitCoordinates)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rectInAppKitCoordinates) }) ?? NSScreen.main else { return }

        // Same manners as the highlight outline: click-through, never key or
        // main, every Space including full-screen ones.
        let overlay = OverlayWindow(screen: screen)
        overlay.collectionBehavior.insert(.ignoresCycle)
        let model = ElementPointerModel()
        let hostingView = NSHostingView(rootView: ElementPointerView(
            shape: approximate ? .approximate : ElementPointerShape.forElement(role: role, size: rectInAppKitCoordinates.size),
            still: reduceMotion, model: model
        ))
        // The window's frame is the flight's, never the content's.
        hostingView.sizingOptions = []
        overlay.contentView = hostingView
        // From the mouse; on another display, from the target display's nearest point.
        let mouse = NSEvent.mouseLocation
        let start = CGPoint(x: min(max(mouse.x, screen.frame.minX), screen.frame.maxX),
                            y: min(max(mouse.y, screen.frame.minY), screen.frame.maxY))
        overlay.setFrame(reduceMotion ? target
                         : CGRect(x: start.x - startSidePoints / 2, y: start.y - startSidePoints / 2, width: startSidePoints, height: startSidePoints),
                         display: true)
        overlay.orderFrontRegardless()
        window = overlay
        currentTarget = rectInAppKitCoordinates
        let shownAt = ProcessInfo.processInfo.systemUptime
        onVisibilityChange?(true, shownAt)

        func arrived() {
            guard generation == shown else { return }
            model.arrived = true
        }
        if reduceMotion {
            arrived()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = flightSeconds
                // An overshoot curve: the spring's feel, on a window frame.
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.64, 1)
                overlay.animator().setFrame(target, display: true)
            }, completionHandler: { DispatchQueue.main.async { arrived() } })
        }
        func fadeOut() {
            guard generation == shown else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = reduceMotion ? 0.01 : fadeSeconds
                overlay.animator().alphaValue = 0
            }, completionHandler: {
                DispatchQueue.main.async {
                    guard generation == shown else { return }
                    dismiss(overlay)
                }
            })
        }
        guard followSpeech, let holdWhile else {
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : flightSeconds) + seconds) { fadeOut() }
            return
        }
        // Held while its turn is spoken about; polled, because the reply's audio
        // is scheduled arithmetic in the session, not an event.
        var inactiveSince: TimeInterval?
        func poll() {
            guard generation == shown else { return }
            let decision = holdDecision(active: holdWhile(), inactiveSince: inactiveSince,
                                        now: ProcessInfo.processInfo.systemUptime, shownAt: shownAt)
            inactiveSince = decision.inactiveSince
            if decision.hide { fadeOut() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : flightSeconds)) { poll() }
    }
}

private final class ElementPointerModel: ObservableObject {
    @Published var arrived = false
}

/// Fills its window. In flight: the buddy's blue triangle at the centre. On
/// arrival: the role's shape. Blue, never the notch's proof cyan — pointing
/// shows where, it verifies nothing.
private struct ElementPointerView: View {
    let shape: ElementPointerShape
    let still: Bool
    @ObservedObject var model: ElementPointerModel
    @State private var drawn: CGFloat = 0
    @State private var pulse = false

    private let color = DS.Colors.overlayCursorBlue
    private let inset = ElementPointer.marginPoints / 2

    var body: some View {
        ZStack {
            Triangle()
                .fill(color)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(-35))
                .shadow(color: color, radius: 8)
                .opacity(model.arrived ? 0 : 1)
            if model.arrived { mark }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: model.arrived)
        .onChange(of: model.arrived) { _, arrived in
            guard arrived else { return }
            if still { drawn = 1; return }
            withAnimation(.easeOut(duration: 0.35)) { drawn = 1 }
            if shape == .ring { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }

    @ViewBuilder private var mark: some View {
        if still, shape == .approximate {
            Circle().stroke(color, style: StrokeStyle(lineWidth: 2.5, dash: [5, 5])).padding(inset)
        } else if still {
            // Reduce Motion: one static outline, whatever the role.
            RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 2.5).padding(inset)
        } else {
            switch shape {
            case .ring:
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    RoundedRectangle(cornerRadius: side / 2)
                        .stroke(color, lineWidth: 2.5)
                        .shadow(color: color.opacity(0.6), radius: pulse ? 6 : 2)
                        .padding(inset)
                        .scaleEffect(pulse ? 1.06 : 0.96)
                        .opacity(drawn)
                }
            case .underline:
                GeometryReader { proxy in
                    Path { path in
                        let y = proxy.size.height - inset
                        path.move(to: CGPoint(x: inset, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width - inset, y: y))
                    }
                    .trim(from: 0, to: drawn)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            case .approximate:
                Circle()
                    .trim(from: 0, to: drawn)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 5]))
                    .padding(inset)
            case .outline:
                RoundedRectangle(cornerRadius: 6)
                    .trim(from: 0, to: drawn)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(inset)
            }
        }
    }
}
