//
//  AccessibilityAttributesProbe.swift
//  leanring-buddy
//
//  `--ax-attributes-probe=<bundle id>`: what an app publishes, read only — its application element's attribute names,
//  then two levels of AXChildren, AXExtrasMenuBar and AXMenuBar with each element's role, subrole, identifier,
//  description, title and frame. Written to /private/tmp/clicky-ax-attributes-<bundle>.txt, then the app quits.
//  Built 2026-10-31: on macOS 27 Control Centre's Battery/Wi-Fi icons vanished from AXExtrasMenuBar (4 of 12 icons
//  left), and the shell has no Accessibility grant to look for where they went.
//

import AppKit
import ApplicationServices
import Foundation

enum AccessibilityAttributesProbe {
    static func run(bundleIdentifier: String) {
        var lines: [String] = ["probe \(bundleIdentifier) \(Date())", "trusted \(AXIsProcessTrusted())"]
        defer {
            let url = URL(fileURLWithPath: "/private/tmp/clicky-ax-attributes-\(bundleIdentifier).txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            NSApplication.shared.terminate(nil)
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            lines.append("not running"); return
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        lines.append("pid \(app.processIdentifier) policy \(app.activationPolicy.rawValue)")
        var names: CFArray?
        let namesError = AXUIElementCopyAttributeNames(root, &names)
        lines.append("app attributes (\(namesError.rawValue)): \((names as? [String] ?? []).joined(separator: ", "))")
        for attribute in ["AXChildren", "AXExtrasMenuBar", "AXMenuBar", "AXWindows"] {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(root, attribute as CFString, &value)
            lines.append("== \(attribute) error \(error.rawValue)")
            guard let value else { continue }
            let elements: [AXUIElement]
            if CFGetTypeID(value) == AXUIElementGetTypeID() { elements = [value as! AXUIElement] }
            else { elements = (value as? [AXUIElement]) ?? [] }
            for element in elements { describe(element, depth: 1, into: &lines) }
        }
    }

    private static func describe(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        func text(_ attribute: String) -> String {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            guard error == .success, let value else { return "<\(error.rawValue)>" }
            if let string = value as? String { return "\"\(string.prefix(80))\"" }
            if CFGetTypeID(value) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(value as! AXValue, .cgRect, &rect) { return "\(rect)" }
            }
            return "\(type(of: value))"
        }
        let indent = String(repeating: "  ", count: depth)
        lines.append("\(indent)\(text("AXRole")) sub=\(text("AXSubrole")) id=\(text("AXIdentifier")) desc=\(text("AXDescription")) "
            + "title=\(text("AXTitle")) frame=\(text("AXFrame"))")
        guard depth < 3 else { return }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list.prefix(40) { describe(child, depth: depth + 1, into: &lines) }
    }
}
