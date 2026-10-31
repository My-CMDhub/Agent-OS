//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    /// What the credential guard did to this image (`ScreenSecretGuard`).
    var secretGuard: ScreenSecretGuard.Report? = nil
}

@MainActor
enum CompanionScreenCaptureUtility {

    private static let appBundleIdentifier = Bundle.main.bundleIdentifier

    /// Captures the display that contains the focused window first when possible.
    /// Falls back to all visible displays when focus cannot be resolved safely.
    ///
    /// Every caller gets the credential guard: throws `ScreenSecretGuard.Withheld`
    /// while secure input is on or when the app in front could not be checked
    /// for secrets in time; otherwise password-manager windows are left out,
    /// secrets in that app's windows are blacked out before encoding, and a
    /// display holding none of its windows is not sent.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        try ScreenSecretGuard.refuseWhileSecureInput(SecureInputState.current())
        let isRefused = try policyRefuses()
        // Started first, so the walk runs beside the capture, not in front of it.
        // Detached: AX is cross-process IPC and never runs on main.
        let inspection = Task.detached { await ScreenSecretGuard.inspectWithinDeadline(isRefused: isRefused) }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Our own overlays and panels, every password manager and every app the harness
        // policy refuses are never in the picture — left out by APPLICATION.
        let leftOutApplications = excludedApplications(in: content, isRefused: isRefused)
        let leftOut = windowsLeftOut(owners: content.windows.map { $0.owningApplication?.bundleIdentifier },
                                     ownBundleIdentifier: appBundleIdentifier)
        let secretGuard = SecretGuardInput(inspection: inspection, excludedWindowCount: leftOut.passwordManagers.count)
        // A display the guard did not check is skipped; if every one is, this says why.
        var displayWithheld: ScreenSecretGuard.Withheld?

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        if let focusedDisplayIndex = focusedDisplayIndex(in: content),
           let focusedDisplay = content.displays[safe: focusedDisplayIndex] {
            print("🎯 Capture mode: focused display first (\(focusedDisplay.displayID))")
            do {
                if let capture = try await captureDisplay(
                    focusedDisplay,
                    displayIndex: focusedDisplayIndex,
                    totalDisplayCount: content.displays.count,
                    displayLookup: nsScreenByDisplayID,
                    excludingApplications: leftOutApplications,
                    secretGuard: secretGuard,
                    mouseLocation: mouseLocation,
                    labelMode: .focused
                ) {
                    return [capture]
                }
            } catch let withheld as ScreenSecretGuard.Withheld where withheld.report.reason == ScreenSecretGuard.displayNotScanned {
                displayWithheld = withheld
            }

            print("🎯 Capture mode: focused display capture failed, falling back")
        }

        print("🎯 Capture mode: fallback all displays")

        // Sort displays so the cursor screen is always first on fallback.
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            do {
                if let capture = try await captureDisplay(
                    display,
                    displayIndex: displayIndex,
                    totalDisplayCount: sortedDisplays.count,
                    displayLookup: nsScreenByDisplayID,
                    excludingApplications: leftOutApplications,
                    secretGuard: secretGuard,
                    mouseLocation: mouseLocation,
                    labelMode: .fallback
                ) {
                    capturedScreens.append(capture)
                }
            } catch let withheld as ScreenSecretGuard.Withheld where withheld.report.reason == ScreenSecretGuard.displayNotScanned {
                displayWithheld = withheld
            }
        }

        guard !capturedScreens.isEmpty else {
            if let displayWithheld { throw displayWithheld }
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Indices of the applications every whole-display capture leaves out (owner's ruling
    /// 2026-10-31): Clicky (by process and by bundle), every password manager, and every app
    /// the harness policy refuses. By APPLICATION, never by window: a window such an app opens
    /// after this list was read is still not in the picture, where a window list would miss it.
    /// The list comes from `SCShareableContent` with OFF-screen windows too (security review
    /// 2026-10-31): on-screen only, an excluded app with nothing on screen yet was not listed, so
    /// a window it opened before the shutter was photographed. ponytail: an app with no window at
    /// all is still not listed; ScreenCaptureKit offers no other handle to exclude it by.
    nonisolated static func applicationsLeftOut(_ applications: [(bundleIdentifier: String?, processID: pid_t)], ownPID: pid_t,
                                                ownBundleIdentifier: String?, isRefused: (String?) -> Bool) -> [Int] {
        applications.indices.filter { index in
            let bundle = applications[index].bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            return applications[index].processID == ownPID || (ownBundleIdentifier != nil && bundle == ownBundleIdentifier)
                || CredentialGuard.isPasswordManager(bundle) || isRefused(bundle)
        }
    }

    nonisolated static func excludedApplications(in content: SCShareableContent, isRefused: (String?) -> Bool) -> [SCRunningApplication] {
        applicationsLeftOut(content.applications.map { ($0.bundleIdentifier, $0.processID) }, ownPID: getpid(),
                            ownBundleIdentifier: Bundle.main.bundleIdentifier, isRefused: isRefused)
            .map { content.applications[$0] }
    }

    /// The harness policy's `refuse` as a capture exclusion. A policy file that does not
    /// parse fails closed, as every harness verb does: nothing is photographed.
    nonisolated static func policyRefuses() throws -> @Sendable (String?) -> Bool {
        switch HarnessAppPolicy.load(from: HarnessServer.policyURL) {
        case .missing: return { _ in false }
        case .loaded(let policy, _): return { HarnessAppPolicy.verdict(for: $0, in: policy).0 == .refuse }
        case .unreadable:
            let report = ScreenSecretGuard.Report(outcome: "withheld", reason: "policyUnreadable")
            ScreenSecretGuard.log(report)
            throw ScreenSecretGuard.Withheld(report: report)
        }
    }

    // MARK: The harness's whole display (`look` tier `screen`, `pointer`)

    /// One display as the harness captured it. `image` is the GUARDED picture (the front
    /// app's secrets blacked out) when `withheld` is false. When the guard withheld it,
    /// `image` is the raw capture and must never leave this process: `pointer` still
    /// reads the words at its point from it to JUDGE them locally, and reports none.
    struct HarnessShot: @unchecked Sendable {
        let image: CGImage
        /// AppKit, the whole display.
        let displayFrame: CGRect
        let report: ScreenSecretGuard.Report
        let withheld: Bool
        let excludedBundleIdentifiers: [String]
        let milliseconds: Int
    }

    /// The voice screenshot's path for ONE display the caller chose: the same exclusions
    /// (`applicationsLeftOut`, by application), the same front-app inspection and
    /// `ScreenSecretGuard.guarded`, at `pixelsPerPoint` (1 for `look`: a 1440x900 display is a
    /// 1440x900 image, so an image pixel IS a point). Throws `Withheld` while secure input is on.
    nonisolated static func captureHarnessDisplay(_ display: EscalationLadder.DisplayInfo, pixelsPerPoint: CGFloat,
                                                  isRefused: @escaping @Sendable (String?) -> Bool) async throws -> HarnessShot {
        let startedAt = Date()
        try ScreenSecretGuard.refuseWhileSecureInput(SecureInputState.current())
        let inspection = Task.detached { await ScreenSecretGuard.inspectWithinDeadline(isRefused: isRefused) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw NSError(domain: "CompanionScreenCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "that display is not available for capture"])
        }
        let excluded = excludedApplications(in: content, isRefused: isRefused)
        let leftOut = windowsLeftOut(owners: content.windows.map { $0.owningApplication?.bundleIdentifier },
                                     ownBundleIdentifier: Bundle.main.bundleIdentifier)
        let image = try await captureImage(of: scDisplay, excluding: excluded, displayFrame: display.appKitFrame,
                                           pixelsPerPoint: pixelsPerPoint)
        let checked = await inspection.value
        let shot = { (image: CGImage, report: ScreenSecretGuard.Report, withheld: Bool) in
            HarnessShot(image: image, displayFrame: display.appKitFrame, report: report, withheld: withheld,
                        excludedBundleIdentifiers: excluded.map(\.bundleIdentifier).filter { !$0.isEmpty }.sorted(),
                        milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000))
        }
        do {
            let (safe, report) = try ScreenSecretGuard.guarded(image, displayFrame: display.appKitFrame, inspection: checked,
                                                               excludedWindowCount: leftOut.passwordManagers.count)
            return shot(safe, report, false)
        } catch let withheld as ScreenSecretGuard.Withheld {
            return shot(image, withheld.report, true)
        }
    }

    /// Which display `look` tier `screen` photographs: the one holding most of the focused
    /// window, else the main display.
    nonisolated static func harnessDisplayIndex(focusedWindowFrame: CGRect?, displays: [CGRect], mainIndex: Int?) -> Int? {
        focusedWindowFrame.flatMap { bestDisplayIndex(for: $0, among: displays) } ?? mainIndex ?? (displays.isEmpty ? nil : 0)
    }

    /// A small crop of a display, for `pointer`'s before/after pixel comparison ONLY: it
    /// never leaves the process (a 96-pixel grey thumbnail is all that is kept), so it is not
    /// guarded — but it leaves out the same applications, and the cursor, so neither our
    /// overlay nor the pointer we just moved counts as a change.
    nonisolated static func greyCrop(_ region: CGRect, of display: EscalationLadder.DisplayInfo,
                                     isRefused: @escaping @Sendable (String?) -> Bool) async throws -> [UInt8] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else { return [] }
        let image = try await captureImage(of: scDisplay, excluding: excludedApplications(in: content, isRefused: isRefused),
                                           displayFrame: display.appKitFrame, pixelsPerPoint: 1, crop: region, showsCursor: false)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return [] }
        return ScreenOCR.greyThumbnail(jpeg: jpeg)
    }

    /// The one capture call every whole-display path shares. `crop` is AppKit global, inside the display.
    nonisolated private static func captureImage(of display: SCDisplay, excluding applications: [SCRunningApplication],
                                                 displayFrame: CGRect, pixelsPerPoint: CGFloat?, crop: CGRect? = nil,
                                                 showsCursor: Bool = true) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = showsCursor
        let region = crop ?? displayFrame
        if let crop { configuration.sourceRect = EscalationLadder.sourceRect(forAppKitRect: crop, onDisplayWithAppKitFrame: displayFrame) }
        if let pixelsPerPoint {
            let size = EscalationLadder.pixelSize(forRegion: region, backingScaleFactor: pixelsPerPoint)
            configuration.width = size.width
            configuration.height = size.height
        } else {
            // The voice screenshot's size: 1920 on the long edge.
            let maxDimension = 1920
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Indices of the windows left out of every capture: ours, and password managers'.
    nonisolated static func windowsLeftOut(owners: [String?], ownBundleIdentifier: String?)
        -> (own: [Int], passwordManagers: [Int]) {
        let own = owners.indices.filter { ownBundleIdentifier != nil && owners[$0] == ownBundleIdentifier }
        let passwordManagers = owners.indices.filter { !own.contains($0) && CredentialGuard.isPasswordManager(owners[$0]) }
        return (own, passwordManagers)
    }

    /// The only way a captured image becomes model-bound bytes: guarded
    /// (blacked out, or `Withheld` thrown), then encoded. nil when encoding fails.
    nonisolated static func modelReadyJPEG(
        _ captured: CGImage, displayFrame: CGRect, inspection: ScreenSecretGuard.Inspection?, excludedWindowCount: Int
    ) throws -> (jpeg: Data, report: ScreenSecretGuard.Report)? {
        let (image, report) = try ScreenSecretGuard.guarded(
            captured, displayFrame: displayFrame, inspection: inspection, excludedWindowCount: excludedWindowCount)
        guard let jpeg = NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return nil }
        return (jpeg, report)
    }

    nonisolated static func bestDisplayIndex(for windowFrame: CGRect, among displayFrames: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestIntersectionArea: CGFloat = 0

        for (index, displayFrame) in displayFrames.enumerated() {
            let intersection = displayFrame.intersection(windowFrame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                continue
            }

            let area = intersection.width * intersection.height
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestIndex = index
            }
        }

        return bestIndex
    }

    private enum CaptureLabelMode {
        case focused
        case fallback
    }

    private struct SecretGuardInput {
        let inspection: Task<ScreenSecretGuard.Inspection?, Never>
        /// Password-manager windows left out of the filter.
        let excludedWindowCount: Int
    }

    private static func captureDisplay(
        _ display: SCDisplay,
        displayIndex: Int,
        totalDisplayCount: Int,
        displayLookup: [CGDirectDisplayID: NSScreen],
        excludingApplications: [SCRunningApplication],
        secretGuard: SecretGuardInput,
        mouseLocation: CGPoint,
        labelMode: CaptureLabelMode
    ) async throws -> CompanionScreenCapture? {
        let displayFrame = displayLookup[display.displayID]?.frame
            ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                      width: CGFloat(display.width), height: CGFloat(display.height))
        let isCursorScreen = displayFrame.contains(mouseLocation)

        let capturedImage = try await captureImage(of: display, excluding: excludingApplications,
                                                   displayFrame: displayFrame, pixelsPerPoint: nil)
        // Before encoding: blacked out, or withheld (throws) — never sent unchecked.
        guard let (jpegData, secretGuardReport) = try modelReadyJPEG(
            capturedImage, displayFrame: displayFrame, inspection: await secretGuard.inspection.value,
            excludedWindowCount: secretGuard.excludedWindowCount
        ) else {
            return nil
        }

        let screenLabel: String
        switch labelMode {
        case .focused:
            screenLabel = "focused screen (active window)"
        case .fallback:
            if totalDisplayCount == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(totalDisplayCount) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(totalDisplayCount) — secondary screen"
            }
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: screenLabel,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: capturedImage.width,
            screenshotHeightInPixels: capturedImage.height,
            secretGuard: secretGuardReport
        )
    }

    private static func focusedDisplayIndex(in content: SCShareableContent) -> Int? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let frontmostBundleIdentifier = frontmostApplication.bundleIdentifier,
              frontmostBundleIdentifier != appBundleIdentifier,
              let focusedWindowFrame = focusedWindowFrame(for: frontmostApplication.processIdentifier) else {
            return nil
        }

        let displayFrames = content.displays.map(\.frame)
        let focusedDisplayIndex = bestDisplayIndex(for: focusedWindowFrame, among: displayFrames)

        if let focusedDisplayIndex {
            print("🎯 Focused window frame: \(focusedWindowFrame.debugDescription)")
            print("🎯 Frontmost app: \(frontmostBundleIdentifier)")
            print("🎯 Focused display index: \(focusedDisplayIndex)")
        }

        return focusedDisplayIndex
    }

    private static func focusedWindowFrame(for processID: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(processID)

        var focusedWindowValue: AnyObject?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedWindowResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = focusedWindowValue as! AXUIElement

        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        let windowFrame = CGRect(origin: position, size: size)
        guard !windowFrame.isNull, windowFrame.width > 0, windowFrame.height > 0 else {
            return nil
        }

        return windowFrame
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
