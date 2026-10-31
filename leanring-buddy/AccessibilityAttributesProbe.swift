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
        // `--ax-attributes-role=AXSlider`: every element of that role in the app's windows, with ALL its attributes' values.
        if let role = CommandLine.arguments.first(where: { $0.hasPrefix("--ax-attributes-role=") }).map({ String($0.dropFirst("--ax-attributes-role=".count)) }) {
            var windows: AnyObject?
            AXUIElementCopyAttributeValue(root, "AXWindows" as CFString, &windows)
            for window in (windows as? [AXUIElement]) ?? [] { dumpRole(role, in: window, depth: 0, into: &lines) }
            return
        }
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

    private static func dumpRole(_ role: String, in element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth < 40 else { return }
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleValue)
        if roleValue as? String == role {
            var names: CFArray?
            AXUIElementCopyAttributeNames(element, &names)
            lines.append("== \(role)")
            for name in (names as? [String]) ?? [] {
                var value: AnyObject?
                let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                let shown: String
                if let value, CFGetTypeID(value) == AXUIElementGetTypeID() { shown = "<element>" }
                else if let value, let array = value as? [AnyObject] { shown = "<array \(array.count)>" }
                else { shown = value.map { "\(type(of: $0)) \(String(describing: $0).prefix(80))" } ?? "nil" }
                lines.append("  \(name) [\(error.rawValue)] \(shown)")
            }
        }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children) == .success else { return }
        for child in (children as? [AXUIElement]) ?? [] { dumpRole(role, in: child, depth: depth + 1, into: &lines) }
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
