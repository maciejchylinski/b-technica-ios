import Foundation
import UIKit

/// Builds a simple shareable PDF issue report from local project data.
/// Uses only native `UIGraphicsPDFRenderer` — no third-party libraries.
enum IssueReportGenerator {
    struct Input {
        var projectName: String
        var generatedDate: Date
        var issues: [IssueBlock]
        /// Short description of applied filters, e.g. "All issues" or "Status: Open".
        var filterSummary: String
    }

    struct IssueBlock {
        var number: Int
        var title: String
        var details: String
        var status: String
        var drawingName: String
        var drawingRevision: String?
        var drawingLocation: String?
        var contractor: String?
        var discipline: String?
        var pageNumber: Int
        var drawingPageCount: Int
        /// Loaded images only; missing files should already be filtered out.
        var photos: [UIImage]
    }

    enum ReportError: LocalizedError {
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .writeFailed: return "Could not write the report PDF."
            }
        }
    }

    /// Creates a temporary PDF under `tmp/IssueReports/` and returns its URL.
    static func writePDF(from input: Input) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueReports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: input.generatedDate)
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "BTechnica-Issues-\(stamp).pdf"
        let url = directory.appendingPathComponent(fileName)

        let data = try renderPDF(from: input)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ReportError.writeFailed
        }
        return url
    }

    // MARK: - Rendering

    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
    private static let margin: CGFloat = 40
    private static let contentWidth: CGFloat = pageRect.width - margin * 2

    private static func renderPDF(from input: Input) throws -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            var y = beginPage(context: context, input: input, continuing: false)

            if input.issues.isEmpty {
                y = drawText(
                    "No issues in this project yet.",
                    font: .systemFont(ofSize: 12),
                    color: .secondaryLabel,
                    at: y,
                    context: context,
                    input: input
                )
                return
            }

            for (index, issue) in input.issues.enumerated() {
                let needed = estimatedHeight(for: issue)
                if y + needed > pageRect.height - margin {
                    y = beginPage(context: context, input: input, continuing: true)
                }

                y = drawIssue(issue, at: y, context: context, input: input)

                if index < input.issues.count - 1 {
                    y += 10
                    drawSeparator(at: y)
                    y += 16
                }
            }
        }
    }

    @discardableResult
    private static func beginPage(context: UIGraphicsPDFRendererContext,
                                  input: Input,
                                  continuing: Bool) -> CGFloat {
        context.beginPage()
        var y = margin

        let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
        y = drawText("B Technica", font: titleFont, color: .label, at: y, maxLines: 1)
        y += 4
        y = drawText("Issue report",
                     font: .systemFont(ofSize: 14, weight: .semibold),
                     color: .secondaryLabel,
                     at: y,
                     maxLines: 1)
        y += 12

        let dateText = input.generatedDate.formatted(date: .abbreviated, time: .shortened)
        y = drawLabeled("Project", value: input.projectName, at: y)
        y = drawLabeled("Generated", value: dateText, at: y)
        y = drawLabeled("Issues", value: "\(input.issues.count)", at: y)
        y = drawLabeled("Filters", value: input.filterSummary, at: y)
        if continuing {
            y = drawText("Continued…",
                         font: .italicSystemFont(ofSize: 11),
                         color: .secondaryLabel,
                         at: y,
                         maxLines: 1)
        }

        y += 8
        drawSeparator(at: y)
        y += 16
        return y
    }

    private static func drawIssue(_ issue: IssueBlock,
                                  at startY: CGFloat,
                                  context: UIGraphicsPDFRendererContext,
                                  input: Input) -> CGFloat {
        var y = startY

        y = drawText("#\(issue.number)  \(issue.title)",
                     font: .systemFont(ofSize: 14, weight: .bold),
                     color: .label,
                     at: y)

        y = drawLabeled("Status", value: issue.status, at: y)
        y = drawLabeled("Drawing", value: issue.drawingName, at: y)
        if let revision = issue.drawingRevision, !revision.isEmpty {
            y = drawLabeled("Revision", value: revision, at: y)
        }
        if let location = issue.drawingLocation, !location.isEmpty {
            y = drawLabeled("Location", value: location, at: y)
        }
        if let discipline = issue.discipline, !discipline.isEmpty {
            y = drawLabeled("Discipline", value: discipline, at: y)
        }
        if let contractor = issue.contractor, !contractor.isEmpty {
            y = drawLabeled("Contractor", value: contractor, at: y)
        }
        if issue.drawingPageCount > 1 {
            y = drawLabeled("Page", value: "\(issue.pageNumber)", at: y)
        }

        let details = issue.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if details.isEmpty {
            y = drawLabeled("Details", value: "No description", at: y)
        } else {
            y = drawText("Details",
                         font: .systemFont(ofSize: 11, weight: .semibold),
                         color: .secondaryLabel,
                         at: y,
                         maxLines: 1)
            y = drawText(details,
                         font: .systemFont(ofSize: 11),
                         color: .label,
                         at: y)
        }

        if issue.photos.isEmpty {
            y = drawText("Photos: none",
                         font: .systemFont(ofSize: 11),
                         color: .secondaryLabel,
                         at: y,
                         maxLines: 1)
        } else {
            y = drawText("Photos (\(issue.photos.count))",
                         font: .systemFont(ofSize: 11, weight: .semibold),
                         color: .secondaryLabel,
                         at: y,
                         maxLines: 1)
            y = drawPhotos(issue.photos, at: y, context: context, input: input)
        }

        return y
    }

    private static func drawPhotos(_ photos: [UIImage],
                                   at startY: CGFloat,
                                   context: UIGraphicsPDFRendererContext,
                                   input: Input) -> CGFloat {
        let columns: CGFloat = 2
        let spacing: CGFloat = 10
        let thumbWidth = (contentWidth - spacing) / columns
        let thumbHeight = thumbWidth * 0.75
        var y = startY
        var column: CGFloat = 0
        var rowTop = y

        for photo in photos {
            if rowTop + thumbHeight > pageRect.height - margin {
                y = beginPage(context: context, input: input, continuing: true)
                rowTop = y
                column = 0
            }

            let x = margin + column * (thumbWidth + spacing)
            let rect = CGRect(x: x, y: rowTop, width: thumbWidth, height: thumbHeight)
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()

            let fitted = aspectFitRect(for: photo.size, in: rect.insetBy(dx: 2, dy: 2))
            photo.draw(in: fitted)

            column += 1
            if column >= columns {
                column = 0
                rowTop += thumbHeight + spacing
            }
        }

        if column == 0 {
            return rowTop
        }
        return rowTop + thumbHeight + spacing
    }

    // MARK: - Text helpers

    private static func drawLabeled(_ label: String, value: String, at y: CGFloat) -> CGFloat {
        let labelFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let valueFont = UIFont.systemFont(ofSize: 11)
        let labelWidth: CGFloat = 70
        let labelRect = CGRect(x: margin, y: y, width: labelWidth, height: 16)
        let valueRect = CGRect(x: margin + labelWidth,
                               y: y,
                               width: contentWidth - labelWidth,
                               height: 60)

        NSAttributedString(string: label,
                           attributes: [.font: labelFont, .foregroundColor: UIColor.secondaryLabel])
            .draw(in: labelRect)

        let valueAttr = NSAttributedString(string: value,
                                           attributes: [.font: valueFont, .foregroundColor: UIColor.label])
        let valueBounds = valueAttr.boundingRect(with: CGSize(width: valueRect.width, height: 200),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                 context: nil)
        valueAttr.draw(in: CGRect(x: valueRect.minX,
                                  y: y,
                                  width: valueRect.width,
                                  height: ceil(valueBounds.height)))
        return y + max(16, ceil(valueBounds.height)) + 4
    }

    @discardableResult
    private static func drawText(_ text: String,
                                 font: UIFont,
                                 color: UIColor,
                                 at y: CGFloat,
                                 maxLines: Int? = nil,
                                 context: UIGraphicsPDFRendererContext? = nil,
                                 input: Input? = nil) -> CGFloat {
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        let maxHeight = pageRect.height - margin - y
        var bounds = attr.boundingRect(with: CGSize(width: contentWidth, height: maxHeight),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                       context: nil)
        if let maxLines {
            let lineHeight = font.lineHeight
            bounds.size.height = min(bounds.height, lineHeight * CGFloat(maxLines))
        }

        // If text won't fit and we have a context, start a new page.
        if let context, let input, y + bounds.height > pageRect.height - margin {
            let newY = beginPage(context: context, input: input, continuing: true)
            return drawText(text, font: font, color: color, at: newY, maxLines: maxLines)
        }

        attr.draw(in: CGRect(x: margin, y: y, width: contentWidth, height: ceil(bounds.height)))
        return y + ceil(bounds.height) + 6
    }

    private static func drawSeparator(at y: CGFloat) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: margin + contentWidth, y: y))
        UIColor.separator.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func estimatedHeight(for issue: IssueBlock) -> CGFloat {
        var height: CGFloat = 90
        if let revision = issue.drawingRevision, !revision.isEmpty {
            height += 20
        }
        if let location = issue.drawingLocation, !location.isEmpty {
            height += 20
        }
        if let discipline = issue.discipline, !discipline.isEmpty {
            height += 20
        }
        if let contractor = issue.contractor, !contractor.isEmpty {
            height += 20
        }
        if issue.drawingPageCount > 1 {
            height += 20
        }
        let details = issue.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty {
            height += min(80, CGFloat(details.count / 40) * 14)
        }
        if !issue.photos.isEmpty {
            let rows = ceil(CGFloat(issue.photos.count) / 2)
            let thumbHeight = ((contentWidth - 10) / 2) * 0.75
            height += 20 + rows * (thumbHeight + 10)
        }
        return height
    }

    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }
}
