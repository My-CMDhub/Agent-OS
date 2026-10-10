//
//  SettingsPaneLinks.swift
//  leanring-buddy
//
//  `open_settings_pane`: a System Settings pane opened by its own deep link,
//  never by clicking down the sidebar. Only panes on `verified` — each opened
//  live by docs/superpowers/wip/deeplinks.py on 2026-10-10 and proven by its
//  window title through the harness's `windows` — become a link; the model's
//  words never form a URL. Opening a pane changes nothing, so no card.
//

import AppKit
import Foundation

nonisolated enum SettingsPaneLinks {
    static let toolName = "open_settings_pane"
    static let settingsBundle = "com.apple.systempreferences"

    /// Pane name (as its window is titled) -> extension id. 13/13 landed live 2026-10-10.
    static let verified: [String: String] = [
        "Wi-Fi": "com.apple.wifi-settings-extension", "Bluetooth": "com.apple.BluetoothSettings",
        "Lock Screen": "com.apple.Lock-Screen-Settings.extension", "Screen Saver": "com.apple.ScreenSaver-Settings.extension",
        "Displays": "com.apple.Displays-Settings.extension", "Battery": "com.apple.Battery-Settings.extension",
        "Sound": "com.apple.Sound-Settings.extension", "Wallpaper": "com.apple.Wallpaper-Settings.extension",
        "Notifications": "com.apple.Notifications-Settings.extension",
        "Privacy & Security": "com.apple.settings.PrivacySecurity.extension",
        "Keyboard": "com.apple.Keyboard-Settings.extension", "Trackpad": "com.apple.Trackpad-Settings.extension",
        "About": "com.apple.SystemProfiler.AboutExtension"
    ]

    /// Lowercased, hyphens of any kind (Settings writes U+2011) and spaces dropped: "Wi‑Fi" == "wifi".
    private static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !"-\u{2010}\u{2011} ".unicodeScalars.contains($0) }.map(Character.init))
    }

    static func pane(named name: String) -> String? {
        let wanted = key(name.trimmingCharacters(in: .whitespacesAndNewlines))
        return wanted.isEmpty ? nil : verified.keys.first { key($0) == wanted }
    }

    static func url(forPane name: String) -> URL? {
        pane(named: name).flatMap { verified[$0] }.flatMap { URL(string: "x-apple.systempreferences:" + $0) }
    }

    /// The pane's window title, exactly; Battery's also carries its charge state after " – ".
    static func titleMatches(_ title: String, pane: String) -> Bool {
        key(title) == key(pane) || (pane == "Battery" && title.hasPrefix("Battery \u{2013} "))
    }

    /// Opens the pane and waits up to 5 s for System Settings to show a window titled for it.
    static func open(paneName: String?, answer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        guard let paneName, let pane = pane(named: paneName), let url = url(forPane: pane) else {
            return ["ok": false, "error": "paneNotVerified",
                    "message": "only these System Settings panes open directly: " + verified.keys.sorted().joined(separator: ", ")
                        + ". For any other, open System Settings with open_app and find it on screen."]
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { return ["ok": false, "error": "openFailed", "message": "macOS did not open the \(pane) pane"] }
        let line = #"{"verb":"windows","app":"System Settings","expectApp":"\#(settingsBundle)"}"#
        let deadline = Date().addingTimeInterval(5)
        var titles: [String] = []
        while Date() < deadline {
            let response = (try? JSONSerialization.jsonObject(with: Data(answer(line).utf8))) as? [String: Any]
            titles = ((response?["windows"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
            if titles.contains(where: { titleMatches($0, pane: pane) }) {
                return ["ok": true, "pane": pane, "verified": "windowTitle"]
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return ["ok": false, "error": "notObserved", "pane": pane,
                "message": "asked System Settings to open \(pane), but no window titled \(pane) appeared within 5 seconds"]
    }
}
