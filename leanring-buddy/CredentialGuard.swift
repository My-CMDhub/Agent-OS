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
        case privateKey, jwt, anthropicKey, openAIKey, stripeKey, githubToken, gitlabToken, slackToken,
             awsAccessKey, googleAPIKey, npmToken, namedSecret, highEntropy
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
            (.privateKey, regex("-----BEGIN[A-Z ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END[A-Z ]*PRIVATE KEY-----|\\z)"), 0),
            (.jwt, regex("\(b)eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"), 0),
            (.anthropicKey, regex("\(b)sk-ant-[A-Za-z0-9_-]{20,}"), 0),
            (.openAIKey, regex("\(b)sk-(?:proj-|svcacct-|admin-)?([A-Za-z0-9_-]{20,})"), 0),
            (.stripeKey, regex("\(b)(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"), 0),
            (.githubToken, regex("\(b)(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})"), 0),
            (.gitlabToken, regex("\(b)glpat-[A-Za-z0-9_-]{20,}"), 0),
            (.slackToken, regex("\(b)xox[abprs]-[A-Za-z0-9-]{10,}"), 0),
            (.awsAccessKey, regex("(?<![A-Za-z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"), 0),
            (.googleAPIKey, regex("\(b)AIza[0-9A-Za-z_-]{35}"), 0),
            (.npmToken, regex("\(b)npm_[A-Za-z0-9]{36}"), 0),
            // The value: a quoted string whole ("correct horse"), else one bare run.
            (.namedSecret, regex(
                "(?<![A-Za-z0-9])[A-Za-z0-9_.-]*\(secretNamePattern)[A-Za-z0-9_.-]*[\"']?\\s*[:=]\\s*"
                    + "(?:\"([^\"\\n]{1,200})\"|'([^'\\n]{1,200})'|((?:bearer\\s+|basic\\s+)?[^\\s\"',;}<>]{4,}))",
                .caseInsensitive), 1),
            (.highEntropy, regex("(?<![A-Za-z0-9_+/=-])[A-Za-z0-9_+/=-]{32,}(?![A-Za-z0-9_+/=-])"), 0)
        ]
    }()

    private static let secretNameRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9_. -]*\(secretNamePattern)[A-Za-z0-9_. -]*$", options: .caseInsensitive)

    static let minimumHighEntropyLength = 32
    static let minimumHighEntropyBitsPerCharacter = 4.0

    /// Every secret-shaped run in `text`, non-overlapping, in reading order.
    static func matches(in text: String) -> [Match] {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        var accepted: [Match] = []
        for (kind, regex, group) in patterns {
            for result in regex.matches(in: text, range: whole) {
                let candidates = kind == .highEntropy
                    ? highEntropyRanges(in: string, candidate: result.range)
                    : [(group..<result.numberOfRanges).lazy.map { result.range(at: $0) }
                        .first { $0.location != NSNotFound } ?? result.range]
                for range in candidates where range.location != NSNotFound && range.length > 0 {
                    if kind == .openAIKey, !string.substring(with: result.range(at: 1)).contains(where: \.isNumber) { continue }
                    guard !accepted.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
                    accepted.append(Match(kind: kind, range: range))
                }
            }
        }
        return accepted.sorted { $0.range.location < $1.range.location }
    }

    /// A path ("/Users/…/DerivedData/…") is judged a segment at a time — a whole
    /// path is long, mixed and high-entropy, and is not a secret.
    private static func highEntropyRanges(in string: NSString, candidate: NSRange) -> [NSRange] {
        let token = string.substring(with: candidate)
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
        "com.lastpass.LastPass", "org.keepassxc.keepassxc", "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop"
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

/// The outgoing-screenshot half: walk the frontmost app's focused window beside
/// the capture, black out password boxes and every scanner match on the image
/// before it is encoded, and WITHHOLD the image when that check could not be
/// completed in time. Fail closed: a picture nobody could check is not sent.
/// Limit (v1): other apps' windows on the same display are not text-scanned.
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
        /// Set when nothing needed walking: Clicky or a password manager in front
        /// (both are excluded from the capture itself).
        var notWalkedReason: String?
        /// The walk threw: `noFocusedWindow`, `screenIsLocked`, ...
        var failure: String?
        var stopReasons: [String] = []
        var subtreesLostToFailedReads = 0
        var focusChangedDuringWalk = false
        /// A secret was read in an element with no usable frame: it may be on
        /// screen and cannot be covered.
        var unlocatedSecrets = 0
        var redactions: [Redaction] = []
        var nodeCount = 0
        var milliseconds = 0
    }

    struct Drawn: Sendable {
        let kind: String
        /// Top-left image pixels.
        let rect: CGRect
    }

    struct Report: Sendable {
        /// `clean`, `redacted`, `notWalked` or `withheld`.
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
        if inspection.notWalkedReason != nil { return nil }
        if let failure = inspection.failure { return failure }
        if let stop = inspection.stopReasons.sorted().first { return stop }
        if inspection.subtreesLostToFailedReads > 0 { return "subtreesLost" }
        if inspection.focusChangedDuringWalk { return "focusChanged" }
        if inspection.unlocatedSecrets > 0 { return "unlocatedSecret" }
        return nil
    }

    /// What to black out among `nodes`: every on-screen box that might be a
    /// password box, and every scanner match in a name or value - at the exact
    /// glyph rect when `boundsForRange` answers (AX coordinates), else the
    /// element's frame. A match with neither is counted as unlocated.
    static func redactions(
        in nodes: [AccessibilityElementNode], primaryDisplayHeight: CGFloat,
        boundsForRange: (AXUIElement, NSRange) -> CGRect? = axBounds(of:range:)
    ) -> (redactions: [Redaction], unlocated: Int) {
        var found: [Redaction] = []
        var unlocated = 0
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
                for match in SecretScanner.matches(in: text.raw) {
                    if isValue, let element = node.accessibilityElement, let bounds = boundsForRange(element, match.range) {
                        let rect = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                            bounds, primaryDisplayHeightInPoints: primaryDisplayHeight)
                        if rect.width > 0, rect.height > 0 {
                            found.append(Redaction(kind: match.kind.rawValue, appKitRect: rect, source: "range"))
                            continue
                        }
                    }
                    if onScreen {
                        found.append(Redaction(kind: match.kind.rawValue, appKitRect: frame, source: "frame"))
                    } else {
                        unlocated += 1
                    }
                }
            }
        }
        return (found, unlocated)
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

    /// Blocking cross-process walk of the frontmost app's focused window. Call
    /// off main: `inspectWithinDeadline` gives it a thread of its own.
    static func inspectFrontmostWindow(timeLimitSeconds: Double) -> Inspection {
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
        // Bounded before the first cross-process read (`focusedWindowTarget`).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        inspection.app = AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier
        if HarnessServer.isHarnessItself(bundleIdentifier: inspection.app) {
            inspection.notWalkedReason = "ownApp"
            return finished()
        }
        if CredentialGuard.isPasswordManager(inspection.app) {
            inspection.notWalkedReason = "passwordManager"
            return finished()
        }
        do {
            let target = try AccessibilityTreeWalker.focusedWindowTarget()
            inspection.app = target.application.bundleIdentifier
            let remaining = max(0.05, timeLimitSeconds - Date().timeIntervalSince(startedAt))
            let snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow(target, timeLimitInSeconds: remaining)
            inspection.stopReasons = snapshot.walkStopReasons.map { String(describing: $0) }
            inspection.subtreesLostToFailedReads = snapshot.subtreesLostToFailedReads
            inspection.focusChangedDuringWalk = snapshot.focusChangedDuringWalk
            inspection.nodeCount = snapshot.nodeCount
            let found = redactions(in: snapshot.rootNode?.flattenedDescendants() ?? [],
                                   primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
            inspection.redactions = found.redactions
            inspection.unlocatedSecrets = found.unlocated
        } catch {
            inspection.failure = (error as? AccessibilitySnapshotError).map { String(describing: $0) } ?? "walkFailed"
        }
        return finished()
    }

    /// The walk on its own thread, or nil once `walkDeadlineSeconds` pass.
    static func inspectWithinDeadline() async -> Inspection? {
        await RealtimeVoiceSession.value(within: walkDeadlineSeconds) {
            inspectFrontmostWindow(timeLimitSeconds: walkDeadlineSeconds)
        }
    }

    /// `image` of `displayFrame` made safe to send, or `Withheld`. Logs one
    /// counts-only line either way.
    static func guarded(_ image: CGImage, displayFrame: CGRect, inspection: Inspection?,
                        excludedWindowCount: Int) throws -> (image: CGImage, report: Report) {
        var report = Report(outcome: "clean", inspection: inspection, excludedWindowCount: excludedWindowCount)
        if let reason = withholdReason(inspection) {
            report.outcome = "withheld"
            report.reason = reason
            log(report)
            throw Withheld(report: report)
        }
        if let notWalked = inspection?.notWalkedReason {
            report.outcome = "notWalked"
            report.reason = notWalked
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
