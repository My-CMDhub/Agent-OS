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
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
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
        overlay.contentView = NSHostingView(rootView: ElementHighlightView(
            rect: rectInAppKitCoordinates, screenFrame: screen.frame, label: label
        ))
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
            Rectangle()
                .stroke(Color.cyan, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX - screenFrame.origin.x, y: top + rect.height / 2)
            if let label {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cyan)
                    .fixedSize()
                    .position(x: rect.midX - screenFrame.origin.x, y: max(top - 12, 12))
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
            overlay.contentView = NSHostingView(rootView: AnnotationView(shapes: here, screenFrame: screen.frame))
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
    private let color = Color.orange

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
            RoundedRectangle(cornerRadius: 5).stroke(color, lineWidth: 3)
                .frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case "circle":
            let ring = rect(shape.frame, margin: 10)
            Ellipse().stroke(color, lineWidth: 3)
                .frame(width: ring.width, height: ring.height).position(x: ring.midX, y: ring.midY)
        case "underline":
            let under = rect(shape.frame, margin: 0)
            Path { path in
                path.move(to: CGPoint(x: under.minX, y: under.maxY + 3))
                path.addLine(to: CGPoint(x: under.maxX, y: under.maxY + 3))
            }.stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
            }.stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        default:
            EmptyView()   // "label": the caption alone
        }
    }

    private func caption(_ text: String, over target: CGRect) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
            .fixedSize()
            .position(x: target.midX, y: max(target.minY - 14, 14))
    }
}
