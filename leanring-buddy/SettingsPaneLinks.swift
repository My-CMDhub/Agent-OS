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
        "Lock Screen": "com.apple.Lock-Screen-Settings.extension", "Screen Saver": "com.apple.Wallpaper-Settings.extension",
        "Displays": "com.apple.Displays-Settings.extension", "Battery": "com.apple.Battery-Settings.extension",
        "Sound": "com.apple.Sound-Settings.extension", "Wallpaper": "com.apple.Wallpaper-Settings.extension",
        "Notifications": "com.apple.Notifications-Settings.extension",
        "Privacy & Security": "com.apple.settings.PrivacySecurity.extension",
        "Keyboard": "com.apple.Keyboard-Settings.extension", "Trackpad": "com.apple.Trackpad-Settings.extension",
        "About": "com.apple.SystemProfiler.AboutExtension",
        // 20/20 landed live 2026-10-24 by window title (Mouse, with no mouse attached, stayed put; General opened nothing).
        "Appearance": "com.apple.Appearance-Settings.extension", "Desktop & Dock": "com.apple.Desktop-Settings.extension",
        "Control Centre": "com.apple.ControlCenter-Settings.extension", "Focus": "com.apple.Focus-Settings.extension",
        "Login Items & Extensions": "com.apple.LoginItems-Settings.extension", "Software Update": "com.apple.Software-Update-Settings.extension",
        "Storage": "com.apple.settings.Storage", "Network": "com.apple.Network-Settings.extension",
        "Accessibility": "com.apple.Accessibility-Settings.extension", "Users & Groups": "com.apple.Users-Groups-Settings.extension",
        "Date & Time": "com.apple.Date-Time-Settings.extension", "Sharing": "com.apple.Sharing-Settings.extension",
        "Printers & Scanners": "com.apple.Print-Scan-Settings.extension", "Language & Region": "com.apple.Localization-Settings.extension",
        "Screen Time": "com.apple.Screen-Time-Settings.extension", "Internet Accounts": "com.apple.Internet-Accounts-Settings.extension",
        "Spotlight": "com.apple.Spotlight-Settings.extension", "Apple Intelligence & Siri": "com.apple.Siri-Settings.extension",
        "Touch ID & Password": "com.apple.Touch-ID-Settings.extension", "Family": "com.apple.Family-Settings.extension"
    ]

    /// Lowercased, hyphens of any kind (Settings writes U+2011) and spaces dropped: "Wi‑Fi" == "wifi".
    private static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !"-\u{2010}\u{2011} ".unicodeScalars.contains($0) }.map(Character.init))
    }

    /// Exactly, else the one pane whose title holds the name ("Siri", "Login Items", "Control Center").
    static func pane(named name: String) -> String? {
        let wanted = key(name.trimmingCharacters(in: .whitespacesAndNewlines)).replacingOccurrences(of: "center", with: "centre")
        guard !wanted.isEmpty else { return nil }
        if let exact = verified.keys.first(where: { key($0) == wanted }) { return exact }
        let holding = verified.keys.filter { wanted.count >= 4 && key($0).contains(wanted) }
        return holding.count == 1 ? holding[0] : nil
    }

    static func url(forPane name: String) -> URL? {
        pane(named: name).flatMap { verified[$0] }.flatMap { URL(string: "x-apple.systempreferences:" + $0) }
    }

    /// The pane's window title, exactly; Battery's also carries its charge state after " – ".
    static func titleMatches(_ title: String, pane: String) -> Bool {
        key(title) == key(pane) || (pane == "Battery" && title.hasPrefix("Battery \u{2013} "))
            || renamedOn27[pane].map { key(title) == key($0) } == true
    }

    /// macOS 27 (toolchain review 2026-10-30): Control Centre's pane is titled "Menu Bar", and screen savers moved into
    /// Wallpaper (the Screen Saver extension is gone, so its link opens Wallpaper).
    static let renamedOn27: [String: String] = ["Control Centre": "Menu Bar", "Screen Saver": "Wallpaper"]

    /// System Settings at whatever it shows, for a pane with no verified link; ok once a window is readable.
    static func openSettingsItself(asked: String?, answer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        let opened = await MainActor.run { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!) }
        let line = #"{"verb":"windows","app":"System Settings","expectApp":"\#(settingsBundle)"}"#
        let deadline = Date().addingTimeInterval(5)
        while opened, Date() < deadline {
            // `answer` blocks on the harness queue: never on main (toolchain review 2026-10-30 — under Swift 6.4's
            // approachable concurrency this async func ran on its @MainActor caller and could deadlock with the queue).
            let answered = await Task.detached { answer(line) }.value
            let response = (try? JSONSerialization.jsonObject(with: Data(answered.utf8))) as? [String: Any]
            if !((response?["windows"] as? [[String: Any]]) ?? []).isEmpty {
                return ["ok": true, "pane": NSNull(), "verified": "settingsWindow",
                        "message": "System Settings is open; \(UntrustedText(asked ?? "that pane").forDisplay) has no direct link, so find it "
                            + "in the sidebar or with the search field at its top. Panes that open directly: "
                            + verified.keys.sorted().joined(separator: ", ")]
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return ["ok": false, "error": "paneNotVerified", "message": "System Settings did not open within 5 seconds"]
    }

    /// Opens the pane and waits up to 5 s for System Settings to show a window titled for it.
    static func open(paneName: String?, answer: @escaping @Sendable (String) -> String) async -> [String: Any] {
        guard let paneName, let pane = pane(named: paneName), let url = url(forPane: pane) else {
            // Unseen N16 2026-10-24: "open System Settings with open_app" was then refused appNotNamed, a catch-22.
            // Opening Settings itself changes nothing: open it here, and the model finds the pane in its sidebar.
            return await openSettingsItself(asked: paneName, answer: answer)
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { return ["ok": false, "error": "openFailed", "message": "macOS did not open the \(pane) pane"] }
        let line = #"{"verb":"windows","app":"System Settings","expectApp":"\#(settingsBundle)"}"#
        let deadline = Date().addingTimeInterval(5)
        var titles: [String] = []
        while Date() < deadline {
            // `answer` blocks on the harness queue: never on main (toolchain review 2026-10-30 — under Swift 6.4's
            // approachable concurrency this async func ran on its @MainActor caller and could deadlock with the queue).
            let answered = await Task.detached { answer(line) }.value
            let response = (try? JSONSerialization.jsonObject(with: Data(answered.utf8))) as? [String: Any]
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
