//
//  ScreenOCR.swift
//  leanring-buddy
//
//  Apple's Vision OCR as a witness that is not the model: which words are
//  drawn at a point, read locally from our own guarded capture. The vision
//  click (`HarnessServer.visionClickResponse`) clicks only where these words
//  are the model's label — a guard must never compare the model's text with
//  itself, and the screenshot the model read is the model's evidence, not ours.
//
//  Coordinates: Vision's normalised boxes have a BOTTOM-LEFT origin, like
//  AppKit, so a box maps onto the captured region (AppKit) with no flip —
//  unlike AX and CGEvent, which are top-left (WindowPositionManager.swift:235).
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One word Vision read, in AppKit points.
nonisolated struct OCRWord: Equatable, Sendable {
    let text: String
    let frame: CGRect
}

/// One line Vision read, in AppKit points, with each word's own box.
nonisolated struct OCRLine: Equatable, Sendable {
    let text: String
    let frame: CGRect
    var words: [OCRWord] = []
}

nonisolated enum ScreenOCR {
    /// How far outside a word's glyphs a point still counts as on it: a button's
    /// padding. Wider would let the word beside the point answer for it.
    static let wordReachPoints: CGFloat = 8

    /// What the words at a point say about the model's label.
    enum Witness: Equatable {
        /// The label's words, in order, hold the point. `text` is the WHOLE line
        /// they sit in — what the kernel judges ("Pay now" for a label "now").
        case matched(text: String, frame: CGRect)
        /// Words are drawn there and they are not the label.
        case mismatch(textAtPoint: String)
        /// No words were read at the point.
        case noText
    }

    /// One folded token of a line and the box of the word it came from.
    private static func tokens(of line: OCRLine) -> [(token: String, frame: CGRect)] {
        let words = line.words.isEmpty ? [OCRWord(text: line.text, frame: line.frame)] : line.words
        return words.flatMap { word in RealtimeVoiceVerbs.foldedTokens(word.text).map { ($0, word.frame) } }
    }

    private static func reaches(_ frame: CGRect, _ point: CGPoint) -> Bool {
        frame.insetBy(dx: -wordReachPoints, dy: -wordReachPoints).contains(point)
    }

    /// The label (case, accents and punctuation folded) must be a run of words of
    /// one line whose boxes hold the point. Exact tokens: OCR that misreads one
    /// letter is a mismatch, and a mismatch clicks nothing.
    static func witness(lines: [OCRLine], point: CGPoint, label: String) -> Witness {
        let wanted = RealtimeVoiceVerbs.foldedTokens(label)
        let atPoint = lines.filter { line in tokens(of: line).contains { reaches($0.frame, point) } }
        guard !atPoint.isEmpty else { return .noText }
        guard !wanted.isEmpty else { return .mismatch(textAtPoint: atPoint.map(\.text).joined(separator: "\n")) }
        for line in atPoint {
            let read = tokens(of: line)
            guard read.count >= wanted.count else { continue }
            for start in 0...(read.count - wanted.count) where read[start..<(start + wanted.count)].map(\.token) == wanted {
                let frame = read[start..<(start + wanted.count)].map(\.frame).reduce(read[start].frame) { $0.union($1) }
                if reaches(frame, point) { return .matched(text: line.text, frame: frame) }
            }
        }
        return .mismatch(textAtPoint: atPoint.map(\.text).joined(separator: "\n"))
    }

    /// The word whose own box (within `wordReachPoints`) holds the point — the
    /// smallest if two do. Never the nearest word elsewhere.
    static func wordBox(at point: CGPoint, in lines: [OCRLine]) -> OCRWord? {
        lines.flatMap { $0.words.isEmpty ? [OCRWord(text: $0.text, frame: $0.frame)] : $0.words }
            .filter { reaches($0.frame, point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The line a word was read in.
    static func line(holding word: OCRWord, in lines: [OCRLine]) -> OCRLine? {
        lines.first { $0.words.contains(word) || ($0.words.isEmpty && $0.frame == word.frame) }
    }

    // MARK: Did the region change? (pure)

    /// A pixel this far apart (0-255 grey) moved; less is JPEG noise.
    static let pixelDeltaThreshold = 24
    /// This share of pixels must move: a caret blink is a few, a relabelled button hundreds.
    static let changedShare = 0.005

    /// Two grey thumbnails of one region, same size: did enough of it change?
    /// A failed or mismatched decode is never "changed".
    static func changed(before: [UInt8], after: [UInt8]) -> Bool {
        guard !before.isEmpty, before.count == after.count else { return false }
        let moved = zip(before, after).filter { abs(Int($0) - Int($1)) > pixelDeltaThreshold }.count
        return moved >= max(3, Int(Double(before.count) * changedShare))
    }

    // MARK: Impure: Vision and ImageIO

    /// The lines Vision reads in `jpeg`, which shows `region` (AppKit points).
    /// Accurate, no language correction: these are labels, not prose.
    static func recognize(jpeg: Data, region: CGRect) -> [OCRLine] {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return recognize(image: image, region: region)
    }

    static func recognize(image: CGImage, region: CGRect) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        func points(_ box: CGRect) -> CGRect {
            CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
                   width: box.width * region.width, height: box.height * region.height)
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            var words: [OCRWord] = []
            var index = text.startIndex
            for piece in text.split(whereSeparator: \.isWhitespace) {
                guard let range = text.range(of: piece, range: index..<text.endIndex) else { continue }
                index = range.upperBound
                if let box = try? candidate.boundingBox(for: range)?.boundingBox {
                    words.append(OCRWord(text: String(piece), frame: points(box)))
                }
            }
            return OCRLine(text: text, frame: points(observation.boundingBox), words: words)
        }
    }

    /// The image as `width`-wide 8-bit grey, for `changed`; [] when it does not decode.
    static func greyThumbnail(jpeg: Data, width: Int = 96) -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0 else { return [] }
        let height = max(1, Int((Double(image.height) / Double(image.width) * Double(width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : []
    }
}
