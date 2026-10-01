//
//  RealtimeScreenHitTest.swift
//  leanring-buddy
//
//  "What is at this point?" for point_at / press_element (a position in the
//  key-down screenshot) and for the key-down pointer line (the owner's mouse).
//  One system-wide `AXUIElementCopyElementAtPosition`, then up the AXParent
//  chain to the first element worth naming (`RealtimeScreenVerbs.snap`).
//
//  Coordinates: the hit test takes GLOBAL TOP-LEFT points against the primary
//  display, like every AX frame; the caller's point is AppKit (bottom-left,
//  y up). The flip is `RealtimeScreenVerbs.topLeftPoint` — the same trap as
//  WindowPositionManager.swift:235, where a skipped conversion mirrors silently.
//
//  Blocking cross-process IPC: call it off main, under a deadline
//  (`RealtimeVoiceSession.value(within:)`). Every element read here gets a
//  0.25 s messaging timeout first — the SDK scopes a timeout to the object it
//  is set on, so the system-wide element's does not cover what it returns.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum RealtimeScreenHitTest {
    static let messagingTimeoutSeconds: Float = 0.25
    /// A control sits a few wrappers deep even in Chromium; past this it is page
    /// structure, read only for its role and subrole on the way to the window
    /// (whose frame caps a snap, and whose depth is 29-38 in Electron).
    static let maximumAncestors = 12
    static let maximumDepthToWindow = 48

    static func hit(atAppKitPoint point: CGPoint, primaryDisplayHeight: CGFloat, screens: [CGRect]) -> RealtimeScreenHit {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeoutSeconds)
        let topLeft = RealtimeScreenVerbs.topLeftPoint(point, primaryDisplayHeight: primaryDisplayHeight)
        var landed: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(topLeft.x), Float(topLeft.y), &landed) == .success,
              let landed else { return .nothing }
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(landed, &processIdentifier)
        let application = NSRunningApplication(processIdentifier: processIdentifier)
        if processIdentifier == ProcessInfo.processInfo.processIdentifier
            || HarnessServer.isHarnessItself(bundleIdentifier: application?.bundleIdentifier) {
            return .refused(error: "targetIsHarnessItself")
        }

        var chain: [RealtimeSnapNode] = []
        var windowFrame: CGRect?
        var current: AXUIElement? = landed
        var depth = 0
        while let element = current, depth < maximumDepthToWindow {
            depth += 1
            AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
            let role = string(element, kAXRoleAttribute) ?? ""
            if chain.count >= maximumAncestors, role != kAXWindowRole, role != kAXApplicationRole {
                // Past the snap depth: a password box above still refuses; nothing else is read.
                var subrole: CFTypeRef?
                let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                if AccessibilityElementNode.mightBeSecure(role: role, subrole: subrole as? String,
                                                          subroleReadFailed: AccessibilityElementNode.subroleReadFailed(subroleError),
                                                          namedByValue: false) {
                    return .refused(error: "secureField")
                }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                current = (parent as! AXUIElement)
                continue
            }
            let frame = AccessibilityTreeWalker.copyFrame(from: element).frame.map {
                AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame($0, primaryDisplayHeightInPoints: primaryDisplayHeight)
            }
            if role == kAXWindowRole { windowFrame = frame; break }
            if role == kAXApplicationRole { break }
            var subroleValue: CFTypeRef?
            let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
            // A text field's AXValue is what the owner typed: never its name.
            let value = RealtimeScreenVerbs.textInputRoles.contains(role) ? nil : string(element, kAXValueAttribute)
            let label = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
            chain.append(RealtimeSnapNode(
                name: label ?? value,
                role: role, subrole: subroleValue as? String, frame: frame ?? .zero,
                subroleReadFailed: AccessibilityElementNode.subroleReadFailed(subroleError),
                pressable: publishesPress(element), namedByValue: label == nil && value != nil))
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }

        switch RealtimeScreenVerbs.snap(chain, windowFrame: windowFrame) {
        case .secure: return .refused(error: "secureField")
        case .nothing: return .nothing
        case .element(let index):
            let node = chain[index]
            guard let name = node.name else { return .nothing }
            // A label: press the nearest named ancestor that publishes an action and holds it.
            // Capped like `snap`: a whole pane is no press target.
            let windowArea = windowFrame.map { $0.width * $0.height } ?? .infinity
            let ancestor = node.pressable ? nil : chain[(index + 1)...].first {
                $0.pressable && $0.name != nil && $0.frame.contains(CGPoint(x: node.frame.midX, y: node.frame.midY))
                    && $0.frame.width * $0.frame.height <= windowArea / 3
            }.map { RealtimeScreenPressTarget(name: $0.name!, role: $0.role, frame: $0.frame) }
            let display = screens.filter { $0.contains(point) }
            return .element(RealtimeScreenCandidate(name: name, role: node.role, frame: node.frame,
                                                    position: RealtimeScreenVerbs.positionPhrase(of: node.frame, neighbours: [],
                                                                                                 screens: display.isEmpty ? screens : display),
                                                    subrole: node.subrole, pressable: node.pressable, pressAncestor: ancestor),
                            app: application?.bundleIdentifier)
        }
    }

    /// AXPress specifically: Chromium publishes AXScrollToVisible / AXShowMenu everywhere.
    private static func publishesPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success && ((names as? [String])?.contains(kAXPressAction) == true)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
