//
//  OverlayWindow.swift
//  leanring-buddy
//
//  The click-through, full-screen window J.A.R.V.I.S.'s own marks are drawn
//  on — `ElementPointer`, the harness's `highlight`, `annotate` — one per
//  screen, never key or main. The legacy buddy cursor that used to live here
//  (and its speech bubble, onboarding video and music) was retired 2026-11-01
//  (owner's D6): the notch carries voice state and `ElementPointer` points.
//

import AppKit
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }

    /// SwiftUI inside a plain container, never AS the contentView: on macOS 27 a
    /// hosting view that is its window's contentView resizes that window to its
    /// root on every layout (b7631a7), and these windows' frames are ours — the
    /// pointer's even flies.
    func host<Content: View>(_ view: Content) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        contentView = container
    }
}

/// J.A.R.V.I.S.'s marks on other apps' pixels — the pointer, the highlight, the
/// annotations — in the ink of the glass (spec §3.6), never cyan (pointing is
/// not proof) and never Clicky's blue. Ink alone vanishes on a white page, so
/// every mark rides on a thin dark keyline: legible on any content, still one ink.
enum JVReticle {
    static let ink = JV.ink
    static let stroke = JV.stroke
    static let keyline = Color.black.opacity(0.45)
    static let keylineWidth: CGFloat = JV.stroke + 2
    static let radius: CGFloat = 6
}

extension Shape {
    /// The mark's stroke: ink over its dark keyline.
    func reticleStroke(_ style: StrokeStyle = StrokeStyle(lineWidth: JVReticle.stroke, lineCap: .round, lineJoin: .round)) -> some View {
        var keyline = style
        keyline.lineWidth = style.lineWidth + 2
        return ZStack {
            stroke(JVReticle.keyline, style: keyline)
            stroke(JVReticle.ink, style: style)
        }
    }
}

/// A caption on glass: ink text, the glass the card and panel are made of.
private struct ReticleCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(JV.bodyMedium)
            .foregroundStyle(JV.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: JV.keycapRadius, style: .continuous).fill(JV.glass))
            .overlay(RoundedRectangle(cornerRadius: JV.keycapRadius, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .fixedSize()
    }
}

/// The harness's `highlight`: one outline at a time, on its own `OverlayWindow`
/// (click-through, never key or main), so the cursor overlay's shown or hidden
/// state is never touched and there is nothing to restore. A second highlight
/// REPLACES the first — two outlines would not say which request drew which.
enum ElementHighlightOverlay {
    private static var window: OverlayWindow?
    private static var generation = 0

    static func show(_ rectInAppKitCoordinates: CGRect, label: String?, onScreenAt screenIndex: Int, seconds: Double) {
        window?.orderOut(nil)
        window = nil
        generation += 1
        guard NSScreen.screens.indices.contains(screenIndex) else { return }
        let screen = NSScreen.screens[screenIndex]
        let overlay = OverlayWindow(screen: screen)
        overlay.host(ElementHighlightView(rect: rectInAppKitCoordinates, screenFrame: screen.frame, label: label))
        overlay.orderFrontRegardless()
        window = overlay
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard generation == shown else { return }
            window?.orderOut(nil)
            window = nil
        }
    }
}

private struct ElementHighlightView: View {
    let rect: CGRect
    let screenFrame: CGRect
    let label: String?

    var body: some View {
        // SwiftUI's y grows downward, so the AppKit rect is flipped within the screen.
        let top = screenFrame.height - (rect.maxY - screenFrame.origin.y)
        ZStack(alignment: .topLeading) {
            // The element's own rect, framed at the reticle's radius, 4 pt outside it.
            RoundedRectangle(cornerRadius: JVReticle.radius, style: .continuous)
                .reticleStroke()
                .frame(width: rect.width + 8, height: rect.height + 8)
                .position(x: rect.midX - screenFrame.origin.x, y: top + rect.height / 2)
            if let label {
                ReticleCaption(text: label)
                    .position(x: rect.midX - screenFrame.origin.x, y: max(top - 18, 14))
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Draws one outline per accessibility element, in AppKit coordinates.
/// A box that appears vertically mirrored means the coordinate conversion
/// in AccessibilityTreeWalker was skipped somewhere.
struct AccessibilityElementBoxesView: View {
    let elementNodes: [AccessibilityElementNode]
    let screenFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(elementNodes.enumerated()), id: \.offset) { _, elementNode in
                let frame = elementNode.frameInAppKitCoordinates

                Rectangle()
                    .stroke(Color.cyan.opacity(0.7), lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .position(
                        x: frame.midX - screenFrame.origin.x,
                        // SwiftUI's y grows downward like AX does, so the
                        // AppKit frame is flipped back one final time here.
                        y: screenFrame.height - (frame.midY - screenFrame.origin.y)
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Where an `annotate` arrow runs: from 80 pt up and to the left of its
/// target to just short of the target's left edge — or from the right when the
/// left would leave the screen. AppKit coordinates.
nonisolated enum AnnotationGeometry {
    static let arrowReach: CGFloat = 80
    static let arrowGap: CGFloat = 4

    static func arrow(to target: CGRect, on screen: CGRect) -> (start: CGPoint, tip: CGPoint) {
        let fromLeft = target.minX - arrowGap - arrowReach >= screen.minX
        let tip = CGPoint(x: fromLeft ? target.minX - arrowGap : target.maxX + arrowGap, y: target.midY)
        let rise = min(arrowReach * 0.6, max(0, screen.maxY - tip.y - 2))
        let start = CGPoint(x: tip.x + (fromLeft ? -arrowReach : arrowReach), y: tip.y + rise)
        return (CGPoint(x: min(max(start.x, screen.minX + 2), screen.maxX - 2), y: start.y), tip)
    }
}

/// `annotate`'s drawing: every shape of one call on click-through windows
/// (one per screen it touches), never key or main, cleared after
/// `RealtimeAnnotate.holdSeconds` or by the next press (`hide`). A new call
/// replaces the last. Main thread only, like `ElementHighlightOverlay`.
enum AnnotationOverlay {
    private static var windows: [OverlayWindow] = []
    private static var generation = 0

    static func hide() {
        generation += 1
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    static func show(_ shapes: [RealtimeAnnotate.Drawn], seconds: Double = RealtimeAnnotate.holdSeconds) {
        hide()
        let shown = generation
        for screen in NSScreen.screens {
            let here = shapes.filter { screen.frame.intersects($0.frame) }
            guard !here.isEmpty else { continue }
            let overlay = OverlayWindow(screen: screen)
            overlay.collectionBehavior.insert(.ignoresCycle)
            overlay.host(AnnotationView(shapes: here, screenFrame: screen.frame))
            overlay.orderFrontRegardless()
            windows.append(overlay)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard generation == shown else { return }
            hide()
        }
    }

    /// The windows now showing, for the live probe's window-server witness.
    static var windowNumbers: [Int] { windows.map(\.windowNumber) }
}

private struct AnnotationView: View {
    let shapes: [RealtimeAnnotate.Drawn]
    let screenFrame: CGRect

    /// AppKit point to this view's top-left space.
    private func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.height - (point.y - screenFrame.minY))
    }

    private func rect(_ frame: CGRect, margin: CGFloat) -> CGRect {
        let grown = frame.insetBy(dx: -margin, dy: -margin)
        let origin = flipped(CGPoint(x: grown.minX, y: grown.maxY))
        return CGRect(origin: origin, size: grown.size)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(shapes.enumerated()), id: \.offset) { _, shape in
                mark(shape)
                if let label = shape.label {
                    caption(label, over: rect(shape.frame, margin: 6))
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func mark(_ shape: RealtimeAnnotate.Drawn) -> some View {
        switch shape.kind {
        case "box":
            let box = rect(shape.frame, margin: 4)
            RoundedRectangle(cornerRadius: JVReticle.radius, style: .continuous).reticleStroke()
                .frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case "circle":
            let ring = rect(shape.frame, margin: 10)
            Ellipse().reticleStroke()
                .frame(width: ring.width, height: ring.height).position(x: ring.midX, y: ring.midY)
        case "underline":
            let under = rect(shape.frame, margin: 0)
            Path { path in
                path.move(to: CGPoint(x: under.minX, y: under.maxY + 3))
                path.addLine(to: CGPoint(x: under.maxX, y: under.maxY + 3))
            }.reticleStroke()
        case "arrow":
            let geometry = AnnotationGeometry.arrow(to: shape.frame, on: screenFrame)
            let start = flipped(geometry.start), tip = flipped(geometry.tip)
            let angle = atan2(tip.y - start.y, tip.x - start.x)
            Path { path in
                path.move(to: start)
                path.addLine(to: tip)
                for side in [-1.0, 1.0] {
                    path.move(to: tip)
                    path.addLine(to: CGPoint(x: tip.x - 14 * cos(angle + side * .pi / 7), y: tip.y - 14 * sin(angle + side * .pi / 7)))
                }
            }.reticleStroke()
        default:
            EmptyView()   // "label": the caption alone
        }
    }

    private func caption(_ text: String, over target: CGRect) -> some View {
        ReticleCaption(text: text).position(x: target.midX, y: max(target.minY - 16, 14))
    }
}

extension ElementHighlightOverlay {
    /// UI snapshots only: the highlight as drawn on a `screenFrame`-sized screen.
    static func snapshotView(_ rect: CGRect, label: String?, screenFrame: CGRect) -> AnyView {
        AnyView(ElementHighlightView(rect: rect, screenFrame: screenFrame, label: label))
    }
}

extension AnnotationOverlay {
    /// UI snapshots only: one `annotate` call's shapes on a `screenFrame`-sized screen.
    static func snapshotView(_ shapes: [RealtimeAnnotate.Drawn], screenFrame: CGRect) -> AnyView {
        AnyView(AnnotationView(shapes: shapes, screenFrame: screenFrame))
    }
}
