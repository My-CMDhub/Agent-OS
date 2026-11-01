//
//  FrontStateProbe.swift
//  leanring-buddy
//
//  `--front-state-probe`: the "what is in front" line (`OpenApps.contextLineNow`) and
//  list_open_apps' Finder entry, live, across the owner's report (2026-11-01: "When my
//  desktop is frontmost, JARVIS reports that Finder is frontmost"): Finder in front,
//  a Finder window of its own opened, that window minimised, then put back — restored
//  and closed by its unique title, and the app that was in front re-focused. Through
//  this process's harness (policy, kernel, audit). JSON 0600 to
//  ~/Library/Logs/Clicky/front-state-probe.json, then quits.
//

import AppKit
import Foundation

enum FrontStateProbe {
    static let folderName = "JarvisFrontProbe"

    @MainActor
    static func run(harness: HarnessServer) async {
        let answer: @Sendable (String) -> String = { harness.answer(line: $0) }
        var steps: [[String: Any]] = []
        func ask(_ request: [String: Any]) async -> String {
            let response = await VoiceToolProbe.ask(request, answer)
            return response["ok"] as? Bool == true ? "ok" : (response["error"] as? String ?? "unreadable")
        }
        func record(_ step: String, _ outcome: String?) async {
            try? await Task.sleep(for: .milliseconds(1500))
            steps.append(await Task.detached { () -> [String: Any] in
                let started = ProcessInfo.processInfo.systemUptime
                let application = AccessibilityTreeWalker.focusedApplication()
                let line = application.flatMap { OpenApps.contextLineNow($0) }
                let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                let list = OpenApps.toolResult()
                let finder = (list["apps"] as? [[String: Any]])?.first { $0["name"] as? String == "Finder" }
                return ["step": step, "harness": outcome ?? NSNull(), "frontBundle": application?.bundleIdentifier ?? NSNull(),
                        "line": line ?? NSNull(), "lineMs": ms, "desktopInFront": list["desktopInFront"] ?? NSNull(),
                        "finder": finder ?? NSNull()]
            }.value)
        }

        let baseline = await Task.detached { AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier }.value
        await record("baseline", nil)
        await record("finderFocused", await ask(["verb": "focus", "app": "Finder"]))

        // A window of our own, by a title nothing else carries.
        let folder = URL(fileURLWithPath: "/private/tmp/\(folderName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let opened = NSWorkspace.shared.open(folder)
        await record("finderWindowOpened", opened ? "ok" : "openFailed")
        // en-AU menus say "Minimise" (live 2026-11-01: "Minimize" came back notFound).
        var minimised = await ask(["verb": "menu", "path": ["Window", "Minimise"], "expectApp": OpenApps.finderBundleIdentifier])
        if minimised == "notFound" {
            minimised = await ask(["verb": "menu", "path": ["Window", "Minimize"], "expectApp": OpenApps.finderBundleIdentifier])
        }
        await record("finderWindowMinimised", minimised)

        // Put back: un-minimise by title (focus does), close it, re-focus what was in front.
        let restored = await ask(["verb": "focus", "app": "Finder", "title": folderName])
        let closed = restored == "ok"
            ? await ask(["verb": "menu", "path": ["File", "Close Window"], "expectApp": OpenApps.finderBundleIdentifier]) : "notRestored"
        let stillOpen = await Task.detached { () -> Bool in
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: OpenApps.finderBundleIdentifier).first
            else { return false }
            return AccessibilityWindows.liveWindows(for: finder).windows.contains { $0.candidate.title?.raw == folderName }
        }.value
        let refocused = baseline.map { $0 == OpenApps.finderBundleIdentifier ? "ok" : "pending" } ?? "noBaseline"
        await record("restored", "focus \(restored), close \(closed), probeWindowStillOpen \(stillOpen)")
        if refocused == "pending", let baseline {
            await record("baselineRefocused", await ask(["verb": "focus", "app": baseline]))
        }

        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("front-state-probe.json")
        if let data = try? JSONSerialization.data(withJSONObject: ["run": ISO8601DateFormatter().string(from: Date()), "steps": steps],
                                                  options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
