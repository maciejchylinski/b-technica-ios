import Foundation
import PDFKit
import UIKit
import Vision

/// Per-page text extraction: PDFKit text layer first, Apple Vision OCR for pages
/// without usable selectable text (scans). Synchronous — call from a background task.
enum DocumentTextExtractor {
    /// Bump when extraction output changes so indexed documents are refreshed once.
    static let version = 1

    /// Pages with fewer selectable characters than this are treated as scanned.
    static let minimumSelectableCharacters = 24

    /// Longest side of the bitmap rendered for OCR (memory-bounded for A0 sheets).
    static let maxOCRPixelDimension: CGFloat = 3_000

    struct PageResult: Sendable {
        var pageIndex: Int
        var pageLabel: String?
        var text: String
        var method: PageExtractionMethod
        var ocrConfidence: Double?
    }

    static func extract(page: PDFPage, pageIndex: Int, allowOCR: Bool = true) -> PageResult {
        autoreleasepool { () -> PageResult in
            let selectable = normalize(page.string ?? "")
            let label = page.label
            let usableCount = selectable.filter { $0.isLetter || $0.isNumber }.count

            if usableCount >= minimumSelectableCharacters || !allowOCR {
                return PageResult(
                    pageIndex: pageIndex,
                    pageLabel: label,
                    text: selectable,
                    method: selectable.isEmpty ? .noText : .pdfText,
                    ocrConfidence: nil
                )
            }

            if let ocr = try? recognizeText(on: page), ocr.text.count > selectable.count {
                return PageResult(
                    pageIndex: pageIndex,
                    pageLabel: label,
                    text: ocr.text,
                    method: .ocr,
                    ocrConfidence: ocr.confidence
                )
            }
            return PageResult(
                pageIndex: pageIndex,
                pageLabel: label,
                text: selectable,
                method: selectable.isEmpty ? .noText : .pdfText,
                ocrConfidence: nil
            )
        }
    }

    /// OCR languages: Polish and English first, filtered to what this OS supports.
    static func ocrLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let preferred = ["pl-PL", "en-US", "de-DE"]
        guard let supported = try? request.supportedRecognitionLanguages() else { return ["en-US"] }
        let matches = preferred.filter { supported.contains($0) }
        return matches.isEmpty ? ["en-US"] : matches
    }

    static func recognizeText(on page: PDFPage) throws -> (text: String, confidence: Double) {
        guard let image = renderForOCR(page) else { return ("", 0) }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ocrLanguages(for: request)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? [])
            .sorted { lhs, rhs in
                // Vision uses a bottom-left origin: read top-to-bottom, then left-to-right.
                let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
                if abs(dy) > min(lhs.boundingBox.height, rhs.boundingBox.height) * 0.5 {
                    return dy > 0
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
        var lines: [String] = []
        var confidenceSum: Double = 0
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(candidate.string)
            confidenceSum += Double(candidate.confidence)
        }
        let confidence = lines.isEmpty ? 0 : confidenceSum / Double(lines.count)
        return (normalize(lines.joined(separator: "\n")), confidence)
    }

    private static func renderForOCR(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // ~300 dpi for A4, capped for large-format sheets.
        let longest = max(bounds.width, bounds.height)
        let scale = min(300.0 / 72.0, maxOCRPixelDimension / longest)
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .cropBox, to: cg)
        }
        return image.cgImage
    }

    /// NFKC (ligatures → letters), drop soft hyphens, collapse whitespace runs.
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var blankRun = 0
        for rawLine in folded.components(separatedBy: "\n") {
            let line = rawLine
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
                .joined(separator: " ")
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
