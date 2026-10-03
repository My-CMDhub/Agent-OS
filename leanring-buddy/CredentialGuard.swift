//
//  CredentialGuard.swift
//  leanring-buddy
//
//  Credentials are the owner's alone (owner's ruling 2026-10-02). This file is
//  the net that keeps them out of what Clicky writes to disk and sends to a
//  model: a scanner for text that looks like a secret, the password-manager apps
//  whose windows are never photographed, the system's secure-input flag (a
//  password is being typed somewhere), and the geometry that blacks a secret
//  out of a screenshot. Design: docs/superpowers/specs/2026-10-02-credential-guard-design.md.
//
//  The scanner is a net with holes, not a guarantee: published regex detectors
//  find about a third of on-screen secrets. It catches the shapes that have a
//  shape — vendor prefixes, PEM blocks, JWTs, `NAME=value` where NAME is an
//  existing convention — and nothing else.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit

nonisolated enum SecretScanner {
    /// Most specific first: where two kinds overlap, the earlier one wins.
    enum Kind: String, CaseIterable, Sendable {
        case privateKey, jwt, anthropicKey, openAIKey, stripeKey, githubToken, gitlabToken, slackToken, slackWebhook,
             awsAccessKey, googleAPIKey, npmToken, onePasswordSecretKey, connectionString, namedSecret, highEntropy
    }

    /// `range` is UTF-16 (NSString / CFRange), so it can be handed to
    /// `AXBoundsForRange` as is. For `namedSecret` it covers the value only.
    struct Match: Equatable, Sendable {
        let kind: Kind
        let range: NSRange
    }

    /// A name that by convention holds a secret. "auth" alone, never "author".
    static let secretNamePattern =
        "(?:secret|token|passw(?:or)?d|api[_ -]?key|private[_ -]?key|access[_ -]?key|authorization|auth(?![a-z])|credential)"

    /// Not inside a longer identifier: "task-…" must not read as "sk-…".
    private static let notMidToken = "(?<![A-Za-z0-9_-])"

    private static let patterns: [(kind: Kind, regex: NSRegularExpression, valueGroup: Int)] = {
        func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // A literal pattern that fails to compile is a programming error caught by the first test.
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        let b = notMidToken
        return [
            // An END line off screen still leaves the body: redact to the end.
            // PEM, and PGP's "PRIVATE KEY BLOCK".
            (.privateKey, regex("-----BEGIN[A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\\s\\S]*?(?:-----END[A-Z ]*PRIVATE KEY(?: BLOCK)?-----|\\z)"), 0),
            (.jwt, regex("\(b)eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"), 0),
            (.anthropicKey, regex("\(b)sk-ant-[A-Za-z0-9_-]{20,}"), 0),
            (.openAIKey, regex("\(b)sk-(?:proj-|svcacct-|admin-)?([A-Za-z0-9_-]{20,})"), 0),
            (.stripeKey, regex("\(b)(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"), 0),
            (.githubToken, regex("\(b)(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})"), 0),
            (.gitlabToken, regex("\(b)glpat-[A-Za-z0-9_-]{20,}"), 0),
            (.slackToken, regex("\(b)xox[abprs]-[A-Za-z0-9-]{10,}"), 0),
            // The URL IS the credential: anyone holding it can post.
            (.slackWebhook, regex("hooks\\.slack\\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_-]{20,}"), 0),
            (.awsAccessKey, regex("(?<![A-Za-z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"), 0),
            (.googleAPIKey, regex("\(b)AIza[0-9A-Za-z_-]{35}"), 0),
            (.npmToken, regex("\(b)npm_[A-Za-z0-9]{36}"), 0),
            // 1Password's account Secret Key: A3-XXXXXX-XXXXXX-XXXXX-XXXXX-XXXXX-XXXXX.
            (.onePasswordSecretKey, regex("(?<![A-Za-z0-9])A3-[A-Z0-9]{6}-[A-Z0-9]{6}(?:-[A-Z0-9]{5}){4}(?![A-Za-z0-9])"), 0),
            // scheme://user:PASSWORD@host - postgres, mongodb+srv, redis (empty user), https. The password only.
            (.connectionString, regex("(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^\\s:/@]*:([^\\s:/@]+)@"), 1),
            // The value: a quoted string whole ("correct horse"), else one bare run.
            // Starts only at a run boundary and the name's runs are bounded: unanchored
            // `[...]*` restarted at every character, and 10k chars of "a.b-c_d." took 15 s.
            (.namedSecret, regex(
                "(?<![A-Za-z0-9_.-])[A-Za-z0-9_.-]{0,40}\(secretNamePattern)[A-Za-z0-9_.-]{0,40}[\"']?\\s*[:=]\\s*"
                    + "(?:\"([^\"\\n]{1,200})\"|'([^'\\n]{1,200})'|((?:bearer\\s+|basic\\s+)?[^\\s\"',;}<>]{4,}))",
                .caseInsensitive), 1),
            (.highEntropy, regex("(?<![A-Za-z0-9_+/=-])[A-Za-z0-9_+/=-]{32,}(?![A-Za-z0-9_+/=-])"), 0)
        ]
    }()

    private static let secretNameRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9_. -]*\(secretNamePattern)[A-Za-z0-9_. -]*$", options: .caseInsensitive)

    static let minimumHighEntropyLength = 32
    static let minimumHighEntropyBitsPerCharacter = 4.0

    /// Long text (a terminal's scrollback is one AXValue) is scanned in windows,
    /// so no pattern's worst case can grow with the whole string. The overlap is
    /// longer than any match worth keeping whole (a JWT); matching sees past a
    /// window's edges (`withTransparentBounds`), so a run cut by one is left to
    /// the next window rather than matched short.
    static let scanWindowLength = 8_192
    static let scanWindowOverlap = 2_048

    static func scanWindows(length: Int) -> [NSRange] {
        guard length > scanWindowLength else { return [NSRange(location: 0, length: length)] }
        return stride(from: 0, to: length - scanWindowOverlap, by: scanWindowLength - scanWindowOverlap).map {
            NSRange(location: $0, length: min(scanWindowLength, length - $0))
        }
    }

    /// Every secret-shaped run in `text`, non-overlapping, in reading order.
    static func matches(in text: String) -> [Match] {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        let windows = scanWindows(length: string.length)
        var accepted: [Match] = []
        for (kind, regex, group) in patterns {
            // A PEM block is longer than a window; its pattern starts only at a literal BEGIN.
            for window in kind == .privateKey ? [whole] : windows {
                for result in regex.matches(in: text, options: [.withTransparentBounds, .withoutAnchoringBounds], range: window) {
                    let candidates = kind == .highEntropy
                        ? highEntropyRanges(in: string, candidate: result.range)
                        : [(group..<result.numberOfRanges).lazy.map { result.range(at: $0) }
                            .first { $0.location != NSNotFound } ?? result.range]
                    for range in candidates where range.location != NSNotFound && range.length > 0 {
                        if kind == .openAIKey, !looksLikeKeyBody(string.substring(with: result.range(at: 1))) { continue }
                        if kind == .namedSecret, !looksLikeSecretValue(string.substring(with: range)) { continue }
                        guard !accepted.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
                        accepted.append(Match(kind: kind, range: range))
                    }
                }
            }
        }
        return accepted.sorted { $0.range.location < $1.range.location }
    }

    /// What follows "sk-": a digit, or a run of 20+ letters in both cases that
    /// switches case like random text, not like words. Scenario C1 (run
    /// 2026-10-02T23-56-51Z): the mimic key page draws 32 characters whose only
    /// digits are 2-9, so 1 load in ~127 has none; the guard called that
    /// screenshot clean and the voice read the key aloud. Simulated 2026-10-03:
    /// 1.5% of digit-less random 32-letter runs switch case under 0.3 (a miss
    /// of ~1 in 8,000 keys), camel-case identifiers sit at 0.22-0.24.
    /// ponytail: `highEntropy` (no prefix) still needs a digit; a bare
    /// digit-less key is a hole until a vendor shape covers it.
    static func looksLikeKeyBody(_ body: String) -> Bool {
        body.contains(where: \.isNumber) || body.split(whereSeparator: { $0 == "-" || $0 == "_" }).contains { run in
            run.count >= 20 && run.contains(where: \.isUppercase) && run.contains(where: \.isLowercase)
                && classSwitchRatio(String(run)) >= minimumKeyBodyClassSwitchRatio
        }
    }

    static let minimumKeyBodyClassSwitchRatio = 0.3

    /// A named value that is a label, a number or a reference is not a secret:
    /// `max_tokens: 4096`, `Token: Copy`, `TOKEN=$API_KEY`, `process.env.X`,
    /// `authorization:none`, `password: required`.
    static func looksLikeSecretValue(_ value: String) -> Bool {
        var value = value
        if let scheme = value.range(of: "^(?:bearer|basic)\\s+", options: [.regularExpression, .caseInsensitive]) {
            value.removeSubrange(scheme)
        }
        guard value.count >= 8, !value.allSatisfy(\.isNumber) else { return false }
        let lowercased = value.lowercased()
        if value.hasPrefix("$") || value.hasPrefix("%")
            || ["process.env.", "os.environ", "env."].contains(where: lowercased.hasPrefix) { return false }
        // One plain word, at most capitalised.
        return value.range(of: "^[A-Za-z][a-z]*$", options: .regularExpression) == nil
    }

    /// Not judged at all: a run in a URL or a data: URI (preceded by "." or ":",
    /// or in a word holding "://" / "data:") - a Docs id, a playlist id, an
    /// image's base64 - and an integrity hash (`sha512-…`). A path
    /// ("/Users/…/DerivedData/…") is judged a segment at a time — a whole path is
    /// long, mixed and high-entropy, and is not a secret. "/" is NOT a separator
    /// elsewhere: a bare AWS secret access key contains it.
    /// ponytail: a token in a URL path (a Discord webhook, a Telegram bot token)
    /// is a hole; give it a vendor pattern like `slackWebhook` when one matters.
    private static func highEntropyRanges(in string: NSString, candidate: NSRange) -> [NSRange] {
        let token = string.substring(with: candidate)
        if token.range(of: "^sha[0-9]+-", options: .regularExpression) != nil
            || isInsideURLOrDataURI(string, at: candidate.location) { return [] }
        guard token.hasPrefix("/") else { return looksRandom(token) ? [candidate] : [] }
        var ranges: [NSRange] = []
        var offset = candidate.location
        for segment in token.components(separatedBy: "/") {
            let length = (segment as NSString).length
            if looksRandom(segment) { ranges.append(NSRange(location: offset, length: length)) }
            offset += length + 1
        }
        return ranges
    }

    /// Long; upper AND lower AND digit, interleaved; not a hex digest or a UUID;
    /// and dense. The interleaving is what tells a key from a long identifier:
    /// simulated 2026-10-02, 20,000 random base62/base64 tokens of 32-48 chars
    /// switch character class at >= 0.42 of positions (1st percentile), while
    /// "NSAccessibilityBoundsForRange2Parameterized"-style names sit at 0.24-0.33
    /// — and clear 4.0 bits of entropy just as easily (4.29-4.47).
    static func looksRandom(_ token: String) -> Bool {
        guard token.count >= minimumHighEntropyLength,
              token.contains(where: \.isUppercase), token.contains(where: \.isLowercase), token.contains(where: \.isNumber),
              !token.allSatisfy(\.isHexDigit),
              UUID(uuidString: token) == nil,
              classSwitchRatio(token) >= minimumClassSwitchRatio else { return false }
        return shannonEntropy(token) >= minimumHighEntropyBitsPerCharacter
    }

    static let minimumClassSwitchRatio = 0.4

    private static func isInsideURLOrDataURI(_ string: NSString, at location: Int) -> Bool {
        guard location > 0 else { return false }
        let before = string.character(at: location - 1)
        if before == UInt16(UInt8(ascii: ".")) || before == UInt16(UInt8(ascii: ":")) { return true }
        // The whitespace-delimited word up to here, at most one window back.
        var start = location
        while start > 0, location - start < scanWindowOverlap,
              let scalar = Unicode.Scalar(string.character(at: start - 1)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) { start -= 1 }
        let word = string.substring(with: NSRange(location: start, length: location - start)).lowercased()
        return word.contains("://") || word.contains("data:")
    }

    /// Share of adjacent pairs whose class (upper, lower, digit, other) differs.
    static func classSwitchRatio(_ token: String) -> Double {
        func characterClass(_ character: Character) -> Int {
            character.isUppercase ? 0 : character.isLowercase ? 1 : character.isNumber ? 2 : 3
        }
        let classes = token.map(characterClass)
        guard classes.count > 1 else { return 0 }
        return Double(zip(classes, classes.dropFirst()).filter { $0 != $1 }.count) / Double(classes.count - 1)
    }

    /// Bits per character of `token`'s own character distribution.
    static func shannonEntropy(_ token: String) -> Double {
        let characters = Array(token)
        guard !characters.isEmpty else { return 0 }
        let total = Double(characters.count)
        return Dictionary(characters.map { ($0, 1) }, uniquingKeysWith: +).values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    static func marker(_ kind: Kind) -> String { "[REDACTED:\(kind.rawValue)]" }

    /// `text` with every match replaced by its marker. Never logs what it removed.
    static func redact(_ text: String) -> String {
        let found = matches(in: text)
        guard !found.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in found.reversed() { result.replaceCharacters(in: match.range, with: marker(match.kind)) }
        return result as String
    }

    /// Whether a JSON key, on its own, names a secret ("api_key", "GITHUB_TOKEN").
    static func isSecretName(_ key: String) -> Bool {
        secretNameRegex.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
    }

    /// The one pass every on-disk JSON writer makes before serialising: strings
    /// redacted wherever they sit, and a string under a secret-named key
    /// replaced whole (`"api_key": "abc"` has nothing secret-shaped in "abc").
    static func scrub(_ object: [String: Any]) -> [String: Any] {
        var scrubbed: [String: Any] = [:]
        for (key, value) in object {
            if let string = value as? String, !string.isEmpty, isSecretName(key) {
                scrubbed[key] = marker(.namedSecret)
            } else {
                scrubbed[key] = scrub(value)
            }
        }
        return scrubbed
    }

    static func scrub(_ value: Any) -> Any {
        switch value {
        case let string as String: return redact(string)
        case let dictionary as [String: Any]: return scrub(dictionary)
        case let array as [Any]: return array.map { scrub($0) }
        default: return value
        }
    }
}

nonisolated enum CredentialGuard {
    /// Whose windows are never in a screenshot. Best-effort: an app missing here
    /// is still covered by the secure-field blackout and the hand-over.
    static let passwordManagerBundleIdentifiers: Set<String> = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.apple.Passwords",
        "com.apple.Passwords.MenuBarExtra", "com.apple.keychainaccess", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "org.keepassxc.keepassxc", "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop",
        // Verified 2026-10-02 (vendor FAQ / app catalogues): Strongbox, Strongbox Pro, MacPass.
        "com.markmcguill.strongbox", "com.markmcguill.strongbox.pro", "com.markmcguill.strongbox.mac",
        "com.hicknhacksoftware.MacPass",
        // UNVERIFIED (none installed here, no published id found) - check with
        // `defaults read /Applications/X.app/Contents/Info CFBundleIdentifier`.
        "me.proton.pass.electron", "com.nordsec.nordpass", "com.callpod.keepermac.lite", "com.keepersecurity.passwordmanager"
    ]

    static func isPasswordManager(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return passwordManagerBundleIdentifiers.contains { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }

    /// An AppKit-global rect (bottom-left origin) as a TOP-LEFT pixel rect of an
    /// image of `displayFrame` (AppKit) captured at `imageSize`, clipped to the
    /// image; nil when it misses the image.
    static func imagePixelRect(forAppKitRect rect: CGRect, displayFrame: CGRect, imageSize: CGSize) -> CGRect? {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let scaleX = imageSize.width / displayFrame.width
        let scaleY = imageSize.height / displayFrame.height
        let mapped = CGRect(x: (rect.minX - displayFrame.minX) * scaleX,
                            y: (displayFrame.maxY - rect.maxY) * scaleY,
                            width: rect.width * scaleX, height: rect.height * scaleY)
        let clipped = mapped.intersection(CGRect(origin: .zero, size: imageSize))
        return clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? nil : clipped
    }

    /// The same for a rect in AX coordinates (top-left of the PRIMARY display,
    /// y down) — what `AXBoundsForRange` returns.
    static func imagePixelRect(forAXRect rect: CGRect, primaryDisplayHeight: CGFloat, displayFrame: CGRect,
                               imageSize: CGSize) -> CGRect? {
        imagePixelRect(forAppKitRect: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
            rect, primaryDisplayHeightInPoints: primaryDisplayHeight), displayFrame: displayFrame, imageSize: imageSize)
    }
}

/// The system-wide secure-input flag: on while a password field (or a password
/// manager, or a terminal's secure keyboard entry) has the keyboard. Measured
/// 2026-10-02: OFF at rest, ON with a Chrome password field focused, OFF after;
/// an email field left it OFF. No AX IPC.
nonisolated struct SecureInputState: Equatable, Sendable {
    let isOn: Bool
    /// The process holding it, from the IORegistry, when readable.
    let holderPID: pid_t?
    let holderName: String?
    /// False when the holder is not the app in front — a flag left on by
    /// something else. Still a hand-over; reported so a stuck flag is visible.
    let holderIsFrontmost: Bool?

    static let off = SecureInputState(isOn: false, holderPID: nil, holderName: nil, holderIsFrontmost: nil)

    static func current() -> SecureInputState {
        guard IsSecureEventInputEnabled() else { return .off }
        let pid = holderPID(consoleUsers: consoleUsers(), userID: getuid())
        let holder = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        return SecureInputState(isOn: true, holderPID: pid, holderName: holder?.localizedName,
                                holderIsFrontmost: pid.map { $0 == NSWorkspace.shared.frontmostApplication?.processIdentifier })
    }

    /// `IOConsoleUsers` on the registry root: one dictionary per console
    /// session; `kCGSSessionSecureInputPID` appears only while the flag is on
    /// (absent at rest, checked with `ioreg` 2026-10-02). Ours only: another
    /// user's session is not this keyboard.
    static func holderPID(consoleUsers: [[String: Any]], userID: uid_t) -> pid_t? {
        consoleUsers.lazy
            .filter { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == userID }
            .compactMap { ($0["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value }
            .first { $0 > 0 }
    }

    private static func consoleUsers() -> [[String: Any]] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let property = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)
        return (property?.takeRetainedValue() as? [[String: Any]]) ?? []
    }

    /// Counts and names only — never what was typed.
    var jsonObject: [String: Any] {
        ["on": isOn, "holderPid": holderPID.map { Int($0) as Any } ?? NSNull(),
         "holder": holderName ?? NSNull(), "holderIsFrontmost": holderIsFrontmost ?? NSNull()]
    }
}

/// The outgoing-screenshot half: walk every window of the app in front beside
/// the capture, black out password boxes and every scanner match on the image
/// before it is encoded, and WITHHOLD the image when that check could not be
/// completed in time. Fail closed: a picture nobody could check is not sent.
/// Limit: other apps' windows on the same display are not text-scanned; a
/// display holding none of the checked app's windows is not sent at all.
nonisolated enum ScreenSecretGuard {
    /// ponytail: one fixed 600 ms from the start of a capture, which it runs beside
    /// (capture ~230-350 ms). Walks measured 2026-09: System Settings ~360 ms,
    /// Finder 112-786 ms, Mail ~1.8 s - so Mail, and a cold Finder, go out blind.
    /// Read `walkMs` and `withheld` in secret-guard.log before moving it.
    static let walkDeadlineSeconds: Double = 0.6
    static let logFileName = "secret-guard.log"
    /// Points added around every blackout, for anti-aliased edges and a caret.
    static let paddingPoints: CGFloat = 2

    struct Redaction: Equatable, Sendable {
        /// A `SecretScanner.Kind` raw value, or `secureField`.
        let kind: String
        let appKitRect: CGRect
        /// `range` when the app answered AXBoundsForRange, else `frame` (the element's).
        let source: String
    }

    /// What the walk found. Rects and counts only - never an element's text.
    struct Inspection: Sendable {
        var app: String?
        /// `frontmost`, or the app behind Clicky's own panel / a password manager
        /// (`behindOwnApp` / `behindPasswordManager`): both are left out of the
        /// capture, so the window under them is what the picture shows; or
        /// `frontmostHasNoWindowHere` (the app in front has no window on this Space).
        var appSource: String?
        /// The walk threw or could not start: `noAppToCheck`, `screenIsLocked`, ...
        var failure: String?
        var stopReasons: [String] = []
        var subtreesLostToFailedReads = 0
        /// Failed AXValue reads: text nobody read is not text with no secret.
        var valueReadErrors = 0
        var focusChangedDuringWalk = false
        /// Browser windows showing a page that gave no text to scan (`webPageUnread`).
        var unreadWebPages = 0
        /// A secret was read in an element whose frame read FAILED: it may be on
        /// screen and cannot be covered.
        var unlocatedSecrets = 0
        var redactions: [Redaction] = []
        var nodeCount = 0
        /// UTF-16 units of text scanned: a "clean" over 0 characters (Monaco,
        /// a canvas) is a different claim from a clean over 40,000.
        var scannedTextCharacters = 0
        /// AppKit frames of the windows walked. A display none of them touches
        /// was not checked and is not sent.
        var windowFrames: [CGRect] = []
        var milliseconds = 0

        /// One window's walk folded in. Pure over the snapshot, so a test can
        /// fail if a field stops reaching `withholdReason`.
        mutating func record(_ snapshot: AccessibilityWindowSnapshot, windowFrame: CGRect, primaryDisplayHeight: CGFloat,
                             boundsForRange: (AXUIElement, NSRange) -> CGRect? = ScreenSecretGuard.axBounds(of:range:)) {
            stopReasons += snapshot.walkStopReasons.map { String(describing: $0) }
            subtreesLostToFailedReads += snapshot.subtreesLostToFailedReads
            valueReadErrors += snapshot.valueReadErrors
            focusChangedDuringWalk = focusChangedDuringWalk || snapshot.focusChangedDuringWalk
            if ScreenSecretGuard.webPageUnread(snapshot.rootNode, bundleIdentifier: app) { unreadWebPages += 1 }
            nodeCount += snapshot.nodeCount
            windowFrames.append(windowFrame)
            let found = ScreenSecretGuard.redactions(in: snapshot.rootNode?.flattenedDescendants() ?? [],
                                                     primaryDisplayHeight: primaryDisplayHeight, boundsForRange: boundsForRange)
            redactions += found.redactions
            unlocatedSecrets += found.unlocated
            scannedTextCharacters += found.scannedCharacters
        }

        func scanned(_ displayFrame: CGRect) -> Bool {
            windowFrames.contains { $0.intersects(displayFrame) }
        }
    }

    struct Drawn: Sendable {
        let kind: String
        /// Top-left image pixels.
        let rect: CGRect
    }

    struct Report: Sendable {
        /// `clean`, `redacted` or `withheld`.
        var outcome: String
        var reason: String?
        var inspection: Inspection?
        var excludedWindowCount = 0
        var drawn: [Drawn] = []
        var secureInput: SecureInputState?

        /// Counts only - what secret-guard.log carries.
        var jsonObject: [String: Any] {
            var line: [String: Any] = [
                "kind": "capture", "outcome": outcome, "reason": reason ?? NSNull(),
                "app": inspection?.app ?? NSNull(), "walkMs": inspection.map { $0.milliseconds as Any } ?? NSNull(),
                "nodeCount": inspection?.nodeCount ?? 0, "excludedWindowCount": excludedWindowCount,
                "appSource": inspection?.appSource ?? NSNull(), "windowsWalked": inspection?.windowFrames.count ?? 0,
                "scannedTextCharacters": inspection?.scannedTextCharacters ?? 0,
                "valueReadErrors": inspection?.valueReadErrors ?? 0,
                "unreadWebPages": inspection?.unreadWebPages ?? 0,
                "redactionsFound": inspection?.redactions.count ?? 0,
                // How often the app answered AXBoundsForRange (`range`) vs the element frame.
                "foundBySource": Dictionary((inspection?.redactions ?? []).map { ($0.source, 1) }, uniquingKeysWith: +),
                "unlocatedSecrets": inspection?.unlocatedSecrets ?? 0, "drawnRectCount": drawn.count,
                "drawnByKind": Dictionary(drawn.map { ($0.kind, 1) }, uniquingKeysWith: +)
            ]
            if let secureInput { line["secureInput"] = secureInput.jsonObject }
            return line
        }
    }

    struct Withheld: Error {
        let report: Report
    }

    // MARK: Pure

    /// The fail-closed table: why the screenshot may not go out, or nil when it
    /// may. nil inspection = the walk missed `walkDeadlineSeconds`.
    static func withholdReason(_ inspection: Inspection?) -> String? {
        guard let inspection else { return "walkDeadline" }
        if let failure = inspection.failure { return failure }
        if let stop = inspection.stopReasons.sorted().first { return stop }
        if inspection.subtreesLostToFailedReads > 0 { return "subtreesLost" }
        if inspection.valueReadErrors > 0 { return "valueUnreadable" }
        if inspection.focusChangedDuringWalk { return "focusChanged" }
        if inspection.unreadWebPages > 0 { return webPageNotReadable }
        if inspection.unlocatedSecrets > 0 { return "unlocatedSecret" }
        return nil
    }

    static let webPageNotReadable = "webPageNotReadable"

    /// Browsers and web-app hosts (owner's call 2026-10-02): a page is drawn
    /// from text the page publishes, so a page that published none was not
    /// checked. Electron apps are deliberately not on it.
    static let browserBundleIdentifiers: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev", "com.microsoft.edgemac.canary",
        "com.brave.browser", "com.brave.browser.beta", "com.brave.browser.nightly", "company.thebrowser.browser",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.apple.safari", "com.apple.safaritechnologypreview"
    ]
    static let safariWebAppPrefix = "com.apple.safari.webapp."

    static func isBrowser(_ bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier?.lowercased() else { return false }
        return browserBundleIdentifiers.contains(id) || id.hasPrefix(safariWebAppPrefix)
    }

    /// A browser window that should show a page but whose `AXWebArea`s hold no
    /// text-bearing descendant (or that has no `AXWebArea` at all). Measured
    /// 2026-10-02: normal pages gave 2,820-5,692 chars (Chrome) and 8,758 (a
    /// Safari web app), web areas present; the same web app then read clean
    /// over 44 nodes / 333 chars.
    /// ponytail: "should show a page" is a role heuristic - an AXWebArea, a tab
    /// strip (AXTabGroup: Chromium and Safari tab bars), or any standard window
    /// of a Safari web app (no tab strip there). Misses a web-area-less page in
    /// a window with neither (Safari with its tab bar hidden, Arc's sidebar,
    /// a Chrome app window) - those pass as before. Wrongly withholds a native
    /// browser window holding an NSTabView, or a web app's Settings window: a
    /// missed picture, never a leak. Upgrade: key on AXDocument (the page URL).
    static func webPageUnread(_ window: AccessibilityElementNode?, bundleIdentifier: String?) -> Bool {
        guard let window, isBrowser(bundleIdentifier) else { return false }
        let nodes = window.flattenedDescendants()
        let webAreas = nodes.filter { $0.role == "AXWebArea" }
        let showsPage = !webAreas.isEmpty || nodes.contains { $0.role == "AXTabGroup" }
            || (bundleIdentifier?.lowercased().hasPrefix(safariWebAppPrefix) == true && window.subrole == "AXStandardWindow")
        guard showsPage else { return false }
        let hasText = { (node: AccessibilityElementNode) in
            [node.title, node.elementDescription, node.value].contains { $0.map { !$0.raw.allSatisfy(\.isWhitespace) } ?? false }
        }
        return !webAreas.contains { $0.children.contains { $0.flattenedDescendants().contains(where: hasText) } }
    }

    /// How far a glyph rect may stray outside its element's frame (a caret, a
    /// descender) before it is taken for a wrong answer and the frame is used.
    static let boundsToleranceInPoints: CGFloat = 4

    /// What to black out among `nodes`: every on-screen box that might be a
    /// password box, and every scanner match in a name or value - at the exact
    /// glyph rect when `boundsForRange` answers (AX coordinates) INSIDE the
    /// element's frame, else that frame. A successful zero frame is scrolled out
    /// (nothing on screen to cover); only a match in an element whose frame read
    /// FAILED is unlocated.
    static func redactions(
        in nodes: [AccessibilityElementNode], primaryDisplayHeight: CGFloat,
        boundsForRange: (AXUIElement, NSRange) -> CGRect? = axBounds(of:range:)
    ) -> (redactions: [Redaction], unlocated: Int, scannedCharacters: Int) {
        var found: [Redaction] = []
        var unlocated = 0
        var scannedCharacters = 0
        for node in nodes {
            let frame = node.frameInAppKitCoordinates
            let onScreen = frame.width > 0 && frame.height > 0
            // Its value is bullets, never the password; a zero-frame one is scrolled out.
            if node.mightBeSecure {
                if onScreen { found.append(Redaction(kind: "secureField", appKitRect: frame, source: "frame")) }
                continue
            }
            for (text, isValue) in [(node.title, false), (node.elementDescription, false), (node.value, true)] {
                guard let text else { continue }
                scannedCharacters += (text.raw as NSString).length
                for match in SecretScanner.matches(in: text.raw) {
                    guard onScreen else {
                        if node.frameReadFailed { unlocated += 1 }
                        continue
                    }
                    // An app's glyph rect is trusted only inside its own element.
                    if isValue, let element = node.accessibilityElement, let bounds = boundsForRange(element, match.range) {
                        let rect = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                            bounds, primaryDisplayHeightInPoints: primaryDisplayHeight)
                        if rect.width > 0, rect.height > 0,
                           frame.insetBy(dx: -boundsToleranceInPoints, dy: -boundsToleranceInPoints).contains(rect) {
                            found.append(Redaction(kind: match.kind.rawValue, appKitRect: rect, source: "range"))
                            continue
                        }
                    }
                    found.append(Redaction(kind: match.kind.rawValue, appKitRect: frame, source: "frame"))
                }
            }
        }
        return (found, unlocated, scannedCharacters)
    }

    /// The redactions that land on an image of `displayFrame`, padded, in pixels.
    static func drawn(_ redactions: [Redaction], displayFrame: CGRect, imageSize: CGSize) -> [Drawn] {
        redactions.compactMap { redaction in
            CredentialGuard.imagePixelRect(
                forAppKitRect: redaction.appKitRect.insetBy(dx: -paddingPoints, dy: -paddingPoints),
                displayFrame: displayFrame, imageSize: imageSize
            ).map { Drawn(kind: redaction.kind, rect: $0.integral) }
        }
    }

    /// `image` with `rects` (top-left pixels) filled black; nil if it cannot be redrawn.
    static func blackedOut(_ image: CGImage, pixelRects: [CGRect]) -> CGImage? {
        guard !pixelRects.isEmpty else { return image }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // CGContext is bottom-left; the rects are top-left.
        for rect in pixelRects { context.fill(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)) }
        return context.makeImage()
    }

    // MARK: Live

    /// The exact on-screen rect of `range` inside `element`'s text, in AX
    /// coordinates; nil when the app does not answer.
    static func axBounds(of element: AXUIElement, range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// Whose windows the picture shows and the guard must read: the app in front,
    /// unless that is Clicky or a password manager (both left out of the capture)
    /// - then the owner of the frontmost ordinary window behind them, from the
    /// window server's front-to-back list (layer 0). The same when the app in
    /// front has no window on this Space (`frontmostShowsNoWindow`): measured
    /// 2026-10-02, Chrome frontmost with its full-screen Space not the one
    /// showing read 0 windows and withheld a picture of Finder's window. With
    /// no ordinary window on screen the picture is the desktop, so its owner
    /// (Finder, desktop-icon level; its kAXWindows lists the desktop as a
    /// display-sized AXScrollArea) is checked: live 2026-10-02 19:28, a Safari
    /// web app's last window closed on a Space holding nothing else, and two
    /// captures withheld `displayNotScanned` with appSource `frontmost`.
    /// nil (withhold) when there is no app in front or nothing behind it.
    static func appToCheck(frontmost: (pid: pid_t, bundleIdentifier: String?)?, windowList: [[String: Any]],
                           ownPID: pid_t, bundleForPID: (pid_t) -> String?,
                           frontmostShowsNoWindow: Bool = false) -> (pid: pid_t, source: String)? {
        guard let frontmost else { return nil }
        let source = frontmost.pid == ownPID ? "behindOwnApp"
            : CredentialGuard.isPasswordManager(frontmost.bundleIdentifier) ? "behindPasswordManager"
            : frontmostShowsNoWindow ? "frontmostHasNoWindowHere" : nil
        guard let source else { return (frontmost.pid, "frontmost") }
        func owner(atLayer layer: Int) -> pid_t? {
            windowList.lazy
                .filter { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == layer }
                .compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
                .first { $0 != ownPID && $0 != frontmost.pid && !CredentialGuard.isPasswordManager(bundleForPID($0)) }
        }
        let behind = owner(atLayer: 0) ?? owner(atLayer: Int(CGWindowLevelForKey(.desktopIconWindow)))
        return behind.map { ($0, source) }
    }

    /// Desktop elements included: the desktop is what shows when no window does (`appToCheck`).
    static let windowListOptions: CGWindowListOption = [.optionOnScreenOnly]

    /// Blocking cross-process walk of every window of the app the picture shows
    /// (`appToCheck`), main window first, inside one shared deadline. Call off
    /// main: `inspectWithinDeadline` gives it a thread of its own.
    static func inspectFrontmostApp(timeLimitSeconds: Double) -> Inspection {
        let startedAt = Date()
        var inspection = Inspection()
        func finished() -> Inspection {
            inspection.milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            return inspection
        }
        guard AXIsProcessTrusted() else {
            inspection.failure = "accessibilityPermissionNotGranted"
            return finished()
        }
        // Bounded before the first cross-process read.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let front = AccessibilityTreeWalker.focusedApplication()
        let windowList = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID)
            as? [[String: Any]] ?? []
        let bundleForPID = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        guard var choice = appToCheck(frontmost: front.map { ($0.processIdentifier, $0.bundleIdentifier) },
                                      windowList: windowList, ownPID: getpid(), bundleForPID: bundleForPID),
              var application = NSRunningApplication(processIdentifier: choice.pid) else {
            inspection.failure = "noAppToCheck"
            return finished()
        }
        var read = AccessibilityWindows.liveWindows(for: application)
        // kAXWindows is Space-scoped: none here means the picture shows other apps' windows.
        if choice.source == "frontmost", read.readSucceeded, read.windows.allSatisfy(\.candidate.isMinimized),
           let behind = appToCheck(frontmost: (choice.pid, application.bundleIdentifier), windowList: windowList,
                                   ownPID: getpid(), bundleForPID: bundleForPID, frontmostShowsNoWindow: true),
           let behindApplication = NSRunningApplication(processIdentifier: behind.pid) {
            choice = behind
            application = behindApplication
            read = AccessibilityWindows.liveWindows(for: application)
        }
        inspection.app = application.bundleIdentifier
        inspection.appSource = choice.source
        guard read.readSucceeded else {
            inspection.failure = "windowListUnreadable"
            return finished()
        }
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let windows = read.windows.filter { !$0.candidate.isMinimized }
            .sorted { $0.candidate.isMain && !$1.candidate.isMain }
        for window in windows {
            let remaining = timeLimitSeconds - Date().timeIntervalSince(startedAt)
            guard remaining > 0.02 else {
                inspection.stopReasons.append(String(describing: WalkStopReason.timeLimit))
                break
            }
            do {
                let snapshot = try AccessibilityTreeWalker.snapshotWindow(window.element, of: application,
                                                                          timeLimitInSeconds: remaining)
                inspection.record(snapshot, windowFrame: window.candidate.frameInAppKitCoordinates,
                                  primaryDisplayHeight: primaryDisplayHeight)
            } catch {
                inspection.failure = (error as? AccessibilitySnapshotError).map { String(describing: $0) } ?? "walkFailed"
                break
            }
        }
        return finished()
    }

    /// The walk on its own thread, or nil once `walkDeadlineSeconds` pass.
    static func inspectWithinDeadline() async -> Inspection? {
        await RealtimeVoiceSession.value(within: walkDeadlineSeconds) {
            inspectFrontmostApp(timeLimitSeconds: walkDeadlineSeconds)
        }
    }

    /// `image` of `displayFrame` made safe to send, or `Withheld`. Logs one
    /// counts-only line either way.
    static func guarded(_ image: CGImage, displayFrame: CGRect, inspection: Inspection?,
                        excludedWindowCount: Int) throws -> (image: CGImage, report: Report) {
        var report = Report(outcome: "clean", inspection: inspection, excludedWindowCount: excludedWindowCount)
        // A display none of the checked windows touches shows only unchecked apps.
        if let reason = withholdReason(inspection) ?? (inspection?.scanned(displayFrame) == false ? displayNotScanned : nil) {
            report.outcome = "withheld"
            report.reason = reason
            log(report)
            throw Withheld(report: report)
        }
        report.drawn = drawn(inspection?.redactions ?? [], displayFrame: displayFrame,
                             imageSize: CGSize(width: image.width, height: image.height))
        guard let safe = blackedOut(image, pixelRects: report.drawn.map(\.rect)) else {
            report.outcome = "withheld"
            report.reason = "redactionFailed"
            log(report)
            throw Withheld(report: report)
        }
        if !report.drawn.isEmpty { report.outcome = "redacted" }
        log(report)
        return (safe, report)
    }

    /// The harness `look` / escalation photograph's check: the inspected windows'
    /// secrets to black out, or why nothing may be photographed (a secret whose
    /// frame read failed). Failed AXValue reads do NOT refuse here yet - that
    /// would blind escalation photographs the planner relies on; owner's call.
    static func secretsBeforeShutter(in inspection: CaptureInspection, primaryDisplayHeight: CGFloat)
        -> (redactions: [Redaction], refusal: String?) {
        let found = redactions(in: inspection.windows.flatMap(\.nodes), primaryDisplayHeight: primaryDisplayHeight)
        guard found.unlocated == 0 else {
            return (found.redactions, "\(found.unlocated) secret-shaped text(s) in this app have no readable frame, "
                + "so they could not be blacked out — nothing was photographed")
        }
        return (found.redactions, nil)
    }

    /// The one per-display reason: the caller skips that display and sends the others.
    static let displayNotScanned = "displayNotScanned"

    /// The capture's first line: while secure input is on, nothing is photographed.
    static func refuseWhileSecureInput(_ state: SecureInputState) throws {
        guard !state.isOn else { throw withheldForSecureInput(state) }
    }

    /// The hand-over: nothing is photographed while a password is being typed.
    static func withheldForSecureInput(_ state: SecureInputState) -> Withheld {
        let report = Report(outcome: "withheld", reason: "secureInput", secureInput: state)
        log(report)
        return Withheld(report: report)
    }

    static func log(_ report: Report) {
        MeasurementLogFile.appendJSONLine(report.jsonObject, toFileNamed: logFileName)
    }
}
