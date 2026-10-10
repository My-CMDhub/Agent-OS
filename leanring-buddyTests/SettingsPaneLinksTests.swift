//
//  SettingsPaneLinksTests.swift
//  leanring-buddyTests
//
//  open_settings_pane's pure half: only a pane on the verified list becomes a
//  link, the window title that proves it landed, and the tool's wiring. That
//  each link opens its pane is the live run's claim (deeplinks.py, 2026-10-10).
//

import Foundation
import Testing
@testable import Clicky

struct SettingsPaneLinksTests {

    @Test func aVerifiedPaneIsItsDeepLink() {
        #expect(SettingsPaneLinks.url(forPane: "Lock Screen")?.absoluteString
                == "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")
        #expect(SettingsPaneLinks.url(forPane: "about")?.absoluteString
                == "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension")
        #expect(SettingsPaneLinks.verified.count == 13)
    }

    @Test func wifiMatchesHoweverItIsSpelled() {
        let link = "x-apple.systempreferences:com.apple.wifi-settings-extension"
        for spelling in ["Wi-Fi", "Wi\u{2011}Fi", "wifi", "WiFi", " wi-fi "] {
            #expect(SettingsPaneLinks.url(forPane: spelling)?.absoluteString == link)
        }
    }

    @Test func anythingElseIsNoLink() {
        for name in ["Terminal", "", "General", "com.apple.Lock-Screen-Settings.extension",
                     "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension", "https://example.com"] {
            #expect(SettingsPaneLinks.url(forPane: name) == nil)
        }
    }

    @Test func theWindowTitleProvesThePane() {
        #expect(SettingsPaneLinks.titleMatches("Wi\u{2011}Fi", pane: "Wi-Fi"))
        #expect(SettingsPaneLinks.titleMatches("Lock Screen", pane: "Lock Screen"))
        // Live 2026-10-10: Battery's title carries the charge state.
        #expect(SettingsPaneLinks.titleMatches("Battery \u{2013} \u{FFFC} Charging: 93%", pane: "Battery"))
        #expect(!SettingsPaneLinks.titleMatches("Bluetooth", pane: "Wi-Fi"))
        #expect(!SettingsPaneLinks.titleMatches("Lock Screen Settings", pane: "Lock Screen"))
    }

    @Test func theToolIsOfferedToVoiceAndLoop() {
        #expect(RealtimeVoiceVerbs.allToolNames.contains(SettingsPaneLinks.toolName))
        #expect(AgentLoop.appChangingTools.contains(SettingsPaneLinks.toolName))
        #expect(AgentPlan.requiredArguments[SettingsPaneLinks.toolName] == [["name"]])
        let names = RealtimeVoiceVerbs.anthropicDeclarations().compactMap { $0["name"] as? String }
        #expect(names.contains(SettingsPaneLinks.toolName))
    }
}
