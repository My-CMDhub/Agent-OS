//
//  AgentComputer.swift
//  leanring-buddy
//
//  The agent loop's computer actions (owner's ruling 2026-10-31, universal screen
//  hands): Anthropic's `computer_toolset_20260801`, whose members Claude calls with
//  pixel coordinates in the whole-display screenshot each step brings (`look` tier
//  `screen`, 1 px per point unless downscaled). Nothing here acts. Each acting member
//  becomes a voice tool call (`RealtimeToolCall`) that runs the SAME guarded path a
//  voice turn's call takes (`RealtimeVoiceConnection.runToolCall`: heard check, unnamed
//  app card, read-only / tab / draft guards, kernel, tickets), aimed by the harness's
//  `pointer` and `key` — never around them:
//    left_click / double_click / right_click -> press_element, pointer click kinds
//    left_click_drag -> drag_item; mouse_move -> point_at, pointer move
//    scroll -> scroll (a coordinate: the pointer's wheel there; none: the window's main area)
//    key -> press_keys (X11 key names translated); type -> type_text into the focused field
//  screenshot, zoom, cursor_position and wait are the loop's own (`Local`).
//  Disabled (`disabledMembers`): middle_click and triple_click (the pointer has neither),
//  left_mouse_down / left_mouse_up and hold_key (a button or key held across calls would
//  act outside any one judged gesture).
//

import CoreGraphics
import Foundation

nonisolated enum AgentComputer {
    static let toolsetType = "computer_toolset_20260801"
    static let toolsetName = "computer"
    static let disabledMembers = ["middle_click", "triple_click", "left_mouse_down", "left_mouse_up", "hold_key"]
    /// The halt text the API documents for a batch's later members once one failed.
    static let notExecutedText = "Not executed: an earlier computer action in this turn failed."
    /// A screenshot's long edge, in pixels: Anthropic's computer-use guidance is to stay at or under 1920x1080-class
    /// sizes for aim (the API's own limit is 2,576 px / 4,784 tokens, and it never downscales — an oversized image is a 400).
    static let maximumLongEdge = 1920
    /// One wait, at most: the task has 180 s, and a longer pause is a question for the owner.
    static let maximumWaitSeconds = 5.0
    /// A key's `repeat`, at most: each press is its own judged request.
    static let maximumKeyRepeat = 10
    /// Scroll-wheel clicks per page of the harness's scroll. ponytail: a fixed ratio; measure per app if one scrolls too far.
    static let wheelClicksPerPage = 5.0

    /// The toolset entry for the Messages API `tools` array.
    static var declaration: [String: Any] {
        ["type": toolsetType, "configs": Dictionary(uniqueKeysWithValues: disabledMembers.map { ($0, ["enabled": false]) })]
    }

    static func isMember(_ toolUse: [String: Any]) -> Bool { toolUse["toolset_name"] as? String == toolsetName }

    // MARK: Coordinates

    /// Image pixel (top-left origin) -> AppKit global point: (region.x + px * w / W, region.y + region.h - py * h / H).
    static func appKitPoint(pixel: CGPoint, region: CGRect, imagePixels: CGSize) -> CGPoint? {
        guard let fraction = fraction(pixel: pixel, imagePixels: imagePixels) else { return nil }
        return RealtimeScreenVerbs.screenshotPoint(x: fraction.x, y: fraction.y, display: region)
    }

    /// A pixel as fractions of the image: what a voice tool call's x and y are (`RealtimeScreenVerbs.screenshotPoint`).
    /// nil off the image.
    static func fraction(pixel: CGPoint, imagePixels: CGSize) -> CGPoint? {
        guard imagePixels.width > 0, imagePixels.height > 0, pixel.x >= 0, pixel.y >= 0,
              pixel.x <= imagePixels.width, pixel.y <= imagePixels.height else { return nil }
        return CGPoint(x: pixel.x / imagePixels.width, y: pixel.y / imagePixels.height)
    }

    /// AppKit point -> image pixel (cursor_position), nil off the screenshot's display.
    static func pixel(appKit point: CGPoint, region: CGRect, imagePixels: CGSize) -> CGPoint? {
        guard region.width > 0, region.height > 0, (region.minX...region.maxX).contains(point.x),
              (region.minY...region.maxY).contains(point.y) else { return nil }
        return CGPoint(x: ((point.x - region.minX) * imagePixels.width / region.width).rounded(),
                       y: ((region.maxY - point.y) * imagePixels.height / region.height).rounded())
    }

    /// zoom's [x0, y0, x1, y1] (pixels) -> the AppKit rectangle it covers.
    static func appKitRect(pixelRegion: [Double], region: CGRect, imagePixels: CGSize) -> CGRect? {
        guard pixelRegion.count == 4, pixelRegion[2] > pixelRegion[0], pixelRegion[3] > pixelRegion[1],
              let topLeft = appKitPoint(pixel: CGPoint(x: pixelRegion[0], y: pixelRegion[1]), region: region, imagePixels: imagePixels),
              let bottomRight = appKitPoint(pixel: CGPoint(x: pixelRegion[2], y: pixelRegion[3]), region: region, imagePixels: imagePixels)
        else { return nil }
        return CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
    }

    // MARK: Keys

    /// Anthropic's key text (X11 names, "ctrl+s", "alt+Tab", "super+c") -> the harness's (`HarnessKeys.parse`): alt is
    /// opt, super / cmd / command / meta are cmd; X11 Delete is forward delete and BackSpace is delete; Prior / Next are
    /// page up / down. nil for anything the harness cannot press.
    static func harnessKeys(_ text: String) -> String? {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty, parts.dropLast().allSatisfy({ !$0.isEmpty }) else { return nil }
        let modifiers = parts.dropLast().map { part -> String in
            switch part.lowercased() {
            case "alt", "option", "opt": return "opt"
            case "super", "cmd", "command", "meta", "win", "super_l", "super_r": return "cmd"
            case "control", "ctrl", "control_l", "control_r": return "ctrl"
            case "shift", "shift_l", "shift_r": return "shift"
            default: return part.lowercased()
            }
        }
        let keyNames = ["delete": "forwarddelete", "backspace": "delete", "back_space": "delete", "prior": "pageup", "next": "pagedown",
                        "page_up": "pageup", "page_down": "pagedown", "kp_enter": "enter", "escape": "escape", "minus": "-", "equal": "=",
                        "comma": ",", "period": ".", "slash": "/", "semicolon": ";", "apostrophe": "'", "bracketleft": "[",
                        "bracketright": "]", "backslash": "\\", "grave": "`"]
        let key = keyNames[last.lowercased()] ?? last.lowercased()
        let joined = (modifiers + [key]).joined(separator: "+")
        return HarnessKeys.parse(joined) == nil ? nil : joined
    }

    // MARK: Members

    /// What the loop does with one member call.
    enum Mapped: Equatable, Error {
        /// A voice tool call through the guarded path; `repeats` presses of a key.
        case call(RealtimeToolCall, repeats: Int)
        case screenshot
        /// The AppKit rectangle to capture close up.
        case zoom(CGRect)
        case cursorPosition
        case wait(seconds: Double)
        /// Refused before anything ran: the error code and the model's message.
        case refused(error: String, message: String)
    }

    /// One member's input, mapped against THIS step's screenshot (`region`: the display it shows, AppKit;
    /// `imagePixels`: the size the model was sent). `mouse`: the pointer now, AppKit, for a click with no coordinate.
    static func mapped(name: String, input: [String: Any], id: String, region: CGRect?, imagePixels: CGSize?,
                       mouse: CGPoint?) -> Mapped {
        func refuse(_ error: String, _ message: String) -> Mapped { .refused(error: error, message: message) }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) }
        func pair(_ key: String) -> CGPoint? {
            guard let values = (input[key] as? [Any])?.compactMap(number), values.count == 2 else { return nil }
            return CGPoint(x: values[0], y: values[1])
        }
        /// A coordinate as the call's fractions; nil coordinate -> the pointer's own place.
        func aim(_ key: String, required: Bool) -> Result<CGPoint, Mapped> {
            guard let region, let imagePixels else {
                return .failure(refuse("noScreenshot", "no screenshot was taken this step, so a coordinate names nothing; nothing was done"))
            }
            if let pixel = pair(key) {
                guard let fraction = fraction(pixel: pixel, imagePixels: imagePixels) else {
                    return .failure(refuse("coordinateOutOfRange", "[\(Int(pixel.x)), \(Int(pixel.y))] is outside the screenshot "
                        + "(\(Int(imagePixels.width)) by \(Int(imagePixels.height)) pixels); nothing was done"))
                }
                return .success(fraction)
            }
            if required || input[key] != nil { return .failure(refuse("missingCoordinate", "\(name) needs \(key) as [x, y] in the screenshot's pixels")) }
            guard let mouse, let pixel = pixel(appKit: mouse, region: region, imagePixels: imagePixels),
                  let fraction = fraction(pixel: pixel, imagePixels: imagePixels) else {
                return .failure(refuse("missingCoordinate", "the pointer is not on the screen in the screenshot; give \(key) as [x, y]"))
            }
            return .success(fraction)
        }
        func positioned(_ toolName: String, pointer: PointerAction, key: String = "coordinate",
                        required: Bool = false) -> Result<RealtimeToolCall, Mapped> {
            if let held = input["text"] as? String, !held.isEmpty {
                return .failure(refuse("modifiersUnsupported", "a \(name) while holding \(held) is not something these hands do; nothing "
                    + "was done. Use the key action for a shortcut, or a menu item"))
            }
            return aim(key, required: required).map { point in
                var call = RealtimeToolCall(callID: id, name: toolName, appName: nil, x: Double(point.x), y: Double(point.y))
                call.pointerAction = pointer.rawValue
                return call
            }
        }
        func called(_ result: Result<RealtimeToolCall, Mapped>) -> Mapped {
            switch result {
            case .success(let call): return .call(call, repeats: 1)
            case .failure(let refusal): return refusal
            }
        }
        switch name {
        case "screenshot": return .screenshot
        case "cursor_position": return .cursorPosition
        case "wait":
            return .wait(seconds: min(max(number(input["duration"]) ?? 1, 0), maximumWaitSeconds))
        case "zoom":
            guard let region, let imagePixels else { return refuse("noScreenshot", "no screenshot was taken this step to zoom into") }
            guard let corners = (input["region"] as? [Any])?.compactMap(number),
                  let rect = appKitRect(pixelRegion: corners, region: region, imagePixels: imagePixels) else {
                return refuse("invalidRegion", "zoom needs region [x0, y0, x1, y1] inside the screenshot, top-left then bottom-right")
            }
            return .zoom(rect)
        case "left_click": return called(positioned(RealtimeVoiceVerbs.pressElementName, pointer: .click))
        case "double_click": return called(positioned(RealtimeVoiceVerbs.pressElementName, pointer: .doubleClick))
        case "right_click": return called(positioned(RealtimeVoiceVerbs.pressElementName, pointer: .rightClick))
        case "mouse_move": return called(positioned(RealtimeVoiceVerbs.pointAtName, pointer: .move, required: true))
        case "left_click_drag":
            return called(positioned(RealtimeVoiceVerbs.dragItemName, pointer: .drag, key: "start_coordinate", required: true).flatMap { start in
                aim("coordinate", required: true).map { end in
                    var drag = start
                    (drag.toX, drag.toY) = (Double(end.x), Double(end.y))
                    return drag
                }
            })
        case "scroll":
            guard let direction = (input["scroll_direction"] as? String).flatMap(ScrollDirection.init(rawValue:)) else {
                return refuse("invalidDirection", "scroll needs scroll_direction: up, down, left or right")
            }
            let pages = min(max((number(input["scroll_amount"]) ?? 3) / wheelClicksPerPage, 0.2), HarnessScroll.maximumPages)
            if input["coordinate"] == nil, (input["text"] as? String)?.isEmpty != false {
                // No point: the window in front's main area, the harness's own scroll (AX-verified).
                return .call(RealtimeToolCall(callID: id, name: RealtimeVoiceVerbs.scrollName, appName: nil, direction: direction.rawValue,
                                              amount: pages), repeats: 1)
            }
            return called(positioned(RealtimeVoiceVerbs.scrollName, pointer: .scroll).map { call in
                var call = call
                (call.direction, call.amount) = (direction.rawValue, pages)
                return call
            })
        case "key":
            guard let text = input["text"] as? String, let keys = harnessKeys(text) else {
                return refuse("invalidKeys", "\(UntrustedText((input["text"] as? String) ?? "").forDisplay) is not a key these hands can press: "
                    + "modifiers (cmd, shift, alt, ctrl) joined by + to one key such as Return, Escape, Tab, Page_Down, Up, a letter or F5")
            }
            let repeats = min(max(Int(number(input["repeat"]) ?? 1), 1), maximumKeyRepeat)
            return .call(RealtimeToolCall(callID: id, name: RealtimeVoiceVerbs.pressKeysName, appName: nil, shortcut: keys), repeats: repeats)
        case "type":
            guard let text = input["text"] as? String, !text.isEmpty else { return refuse("missingText", "type needs the text to type") }
            return .call(RealtimeToolCall(callID: id, name: RealtimeVoiceVerbs.typeTextName, appName: nil, text: text), repeats: 1)
        default:
            return refuse("unsupportedAction", "\(name) is not one of these hands' actions; nothing was done")
        }
    }

    /// cursor_position's text, in the screenshot's pixels.
    static func cursorText(mouse: CGPoint?, region: CGRect?, imagePixels: CGSize?) -> String? {
        guard let mouse, let region, let imagePixels, let pixel = pixel(appKit: mouse, region: region, imagePixels: imagePixels) else { return nil }
        return "X=\(Int(pixel.x)), Y=\(Int(pixel.y))"
    }
}
