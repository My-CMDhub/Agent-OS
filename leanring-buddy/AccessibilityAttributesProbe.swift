//
//  AccessibilityAttributesProbe.swift
//  leanring-buddy
//
//  `--ax-attributes-probe=<bundle id>`: what an app publishes, read only — its application element's attribute names,
//  then two levels of AXChildren, AXExtrasMenuBar and AXMenuBar with each element's role, subrole, identifier,
//  description, title and frame. Written to ~/Library/Logs/Clicky/ax-attributes-<bundle>.txt (0600), then the app quits.
//  Never a value of a password box (skipped whole, as is a text field whose subrole could not be read), and of text
//  attributes (AXValue, AXSelectedText, AXAttributed*) only the type and length. Every failed read prints its AXError.
//  Built 2026-10-31: on macOS 27 Control Centre's Battery/Wi-Fi icons vanished from AXExtrasMenuBar (4 of 12 icons
//  left), and the shell has no Accessibility grant to look for where they went.
//

import AppKit
import ApplicationServices
import Foundation

enum AccessibilityAttributesProbe {
    /// Children listed per element by `describe`; the rest are counted, never silently dropped.
    static let childPrefix = 40

    static func run(bundleIdentifier: String) {
        var lines: [String] = ["probe \(bundleIdentifier) \(Date())", "trusted \(AXIsProcessTrusted())"]
        defer {
            write(lines, bundleIdentifier: bundleIdentifier)
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
            let windowsError = AXUIElementCopyAttributeValue(root, "AXWindows" as CFString, &windows)
            lines.append("== AXWindows error \(windowsError.rawValue)")
            var budget = AccessibilityWalkBudget(maximumDepth: 40, maximumNodeCount: 5_000)
            for window in (windows as? [AXUIElement]) ?? [] { dumpRole(role, in: window, depth: 0, budget: &budget, into: &lines) }
            let stops = budget.stopReasons.map(\.rawValue).sorted()
            // Above the findings, loud: a truncated dump is a floor, not a measurement.
            lines.insert(stops.isEmpty ? "walk complete, \(budget.nodesVisited) nodes"
                         : "!! TRUNCATED (\(stops.joined(separator: ", "))) after \(budget.nodesVisited) nodes: these are a floor, not a measurement",
                         at: min(2, lines.count))
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

    /// The owner's log folder, never /private/tmp: the dump can name what is on screen.
    private static func write(_ lines: [String], bundleIdentifier: String) {
        let directory = MeasurementLogFile.directoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("ax-attributes-\(bundleIdentifier.replacingOccurrences(of: "/", with: "_")).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data(lines.joined(separator: "\n").utf8), attributes: [.posixPermissions: 0o600])
    }

    /// Attributes that can hold what the owner typed or a document's text: shown as type and length only.
    static func masksValue(of attribute: String) -> Bool {
        attribute == "AXValue" || attribute == "AXSelectedText" || attribute.hasPrefix("AXAttributed")
    }

    /// One attribute's value as the dump prints it. A number stays (a slider's AXValue is why this probe exists); text in a
    /// masked attribute becomes its type and length; anything else masked is withheld.
    static func shown(attribute: String, value: AnyObject?) -> String {
        guard let value else { return "nil" }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "<element>" }
        if let array = value as? [AnyObject] { return "<array \(array.count)>" }
        if masksValue(of: attribute) {
            if let text = value as? NSAttributedString { return "NSAttributedString <\(text.length) chars>" }
            if let text = value as? String { return "String <\(text.count) chars>" }
            if let number = value as? NSNumber { return "\(type(of: value)) \(number)" }
            return "\(type(of: value)) <withheld>"
        }
        return "\(type(of: value)) \(String(describing: value).prefix(80))"
    }

    private static func dumpRole(_ role: String, in element: AXUIElement, depth: Int, budget: inout AccessibilityWalkBudget,
                                 into lines: inout [String]) {
        guard budget.claimSlot(atDepth: depth) else { return }
        var roleValue: AnyObject?
        let roleError = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleValue)
        var subrole: AnyObject?
        let subroleError = AXUIElementCopyAttributeValue(element, "AXSubrole" as CFString, &subrole)
        let elementRole = roleValue as? String ?? "AXUnknown"
        if roleError != .success { lines.append("  AXRole error \(roleError.rawValue) at depth \(depth)") }
        // A password box, or a text field whose subrole could not be read, is never dumped — nor anything inside it.
        if AccessibilityElementNode.mightBeSecure(role: elementRole, subrole: subrole as? String,
                                                  subroleReadFailed: AccessibilityElementNode.subroleReadFailed(subroleError), namedByValue: false) {
            lines.append("  (skipped \(elementRole) at depth \(depth): a password box, or its subrole read failed \(subroleError.rawValue))")
            return
        }
        if elementRole == role {
            var names: CFArray?
            let namesError = AXUIElementCopyAttributeNames(element, &names)
            lines.append("== \(role) (attribute names \(namesError.rawValue))")
            for name in (names as? [String]) ?? [] {
                var value: AnyObject?
                let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                lines.append("  \(name) [\(error.rawValue)] \(shown(attribute: name, value: value))")
            }
        }
        var children: AnyObject?
        let childrenError = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children)
        guard childrenError == .success else {
            if childrenError != .noValue, childrenError != .attributeUnsupported {
                lines.append("  AXChildren error \(childrenError.rawValue) under \(elementRole) at depth \(depth): subtree not read")
            }
            return
        }
        for child in (children as? [AXUIElement]) ?? [] { dumpRole(role, in: child, depth: depth + 1, budget: &budget, into: &lines) }
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
        let childrenError = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children)
        guard childrenError == .success, let list = children as? [AXUIElement] else {
            if childrenError != .noValue, childrenError != .attributeUnsupported {
                lines.append("\(indent)  AXChildren error \(childrenError.rawValue)")
            }
            return
        }
        for child in list.prefix(childPrefix) { describe(child, depth: depth + 1, into: &lines) }
        if list.count > childPrefix { lines.append("\(indent)  ... \(list.count - childPrefix) more children not listed (prefix cap \(childPrefix))") }
    }
}
