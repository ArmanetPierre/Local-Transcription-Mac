import AppKit
import Foundation

/// Exporte le compte rendu de reunion en Markdown (.md) ou en PDF
final class MeetingReportExporter: NSObject {

    // MARK: - Markdown Export

    static func exportMarkdown(report: String, title: String) -> String {
        let date = formattedDate()
        return """
        # Compte Rendu — \(title)

        > Genere le \(date)

        ---

        \(report)
        """
    }

    // MARK: - PDF Export (NSAttributedString + Core Graphics — pas de WKWebView)

    /// Genere un PDF A4 multi-pages a partir du compte rendu Markdown
    @MainActor
    static func generatePDF(markdown: String, title: String) throws -> Data {
        let html = buildHTML(markdown: markdown, title: title)

        guard let htmlData = html.data(using: .utf8) else {
            throw PDFError.conversionFailed("Impossible d'encoder le HTML en UTF-8")
        }

        // HTML → NSAttributedString (synchrone, pas de WKWebView)
        guard let attributedString = NSAttributedString(
            html: htmlData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ) else {
            throw PDFError.conversionFailed("Impossible de convertir le HTML en NSAttributedString")
        }

        // Dimensions A4 en points (72 dpi)
        let pageWidth: CGFloat = 595.28
        let pageHeight: CGFloat = 841.89
        let margin: CGFloat = 50
        let contentWidth = pageWidth - 2 * margin
        let contentHeight = pageHeight - 2 * margin

        // TextKit : calculer le layout complet
        let textStorage = NSTextStorage(attributedString: attributedString)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let totalTextHeight = layoutManager.usedRect(for: textContainer).height

        // Creer le PDF multi-pages via Core Graphics
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let pdfConsumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: pdfConsumer, mediaBox: &mediaBox, nil) else {
            throw PDFError.contextCreationFailed
        }

        var yOffset: CGFloat = 0

        while yOffset < totalTextHeight {
            context.beginPage(mediaBox: &mediaBox)
            context.saveGState()

            // Retourner le systeme de coordonnees du CGContext :
            // Par defaut PDF = origine bas-gauche, Y vers le haut
            // On veut : origine haut-gauche, Y vers le bas (flipped)
            context.translateBy(x: 0, y: pageHeight)
            context.scaleBy(x: 1, y: -1)

            let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext

            // Clip pour ne dessiner que la zone de contenu de cette page
            let clipRect = NSRect(x: margin, y: margin, width: contentWidth, height: contentHeight)
            NSBezierPath.clip(NSRect(x: margin, y: margin, width: contentWidth, height: contentHeight))

            // Origin : decaler le texte vers le haut pour afficher la bonne page
            let origin = NSPoint(x: margin, y: margin - yOffset)

            // Calculer quels glyphes sont visibles sur cette page
            let visibleRect = NSRect(
                x: 0,
                y: yOffset,
                width: contentWidth,
                height: contentHeight
            )
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: visibleRect,
                in: textContainer
            )

            // Dessiner les glyphes
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)

            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPage()

            yOffset += contentHeight
        }

        context.closePDF()

        return pdfData as Data
    }

    // MARK: - HTML Generation

    static func buildHTML(markdown: String, title: String) -> String {
        let date = formattedDate()
        let bodyHTML = markdownToHTML(markdown)

        return """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', Helvetica, Arial, sans-serif;
                font-size: 11pt;
                line-height: 1.65;
                color: #2d2d2d;
            }
            .cover {
                text-align: center;
                padding: 30px 0 20px 0;
                border-bottom: 3px solid #7c3aed;
                margin-bottom: 24px;
            }
            .cover h1 {
                font-size: 22pt;
                color: #1a1a1a;
                margin: 0 0 6px 0;
                font-weight: 700;
            }
            .cover .meta {
                font-size: 9pt;
                color: #9ca3af;
                margin-top: 4px;
            }
            h1 { font-size: 16pt; color: #4c1d95; margin-top: 22px; margin-bottom: 6px; }
            h2 { font-size: 13pt; color: #6d28d9; margin-top: 18px; margin-bottom: 5px; }
            h3 { font-size: 11pt; color: #7c3aed; margin-top: 12px; margin-bottom: 4px; }
            p { margin: 5px 0; }
            ul, ol { padding-left: 24px; margin: 5px 0; }
            li { margin-bottom: 3px; }
            strong { color: #1a1a1a; }
            em { color: #4b5563; }
            hr { border: none; border-top: 1px solid #d1d5db; margin: 16px 0; }
            .footer {
                margin-top: 36px;
                padding-top: 10px;
                border-top: 1px solid #e5e7eb;
                text-align: center;
                font-size: 8pt;
                color: #d1d5db;
            }
        </style>
        </head>
        <body>
            <div class="cover">
                <h1>Compte Rendu</h1>
                <div class="meta">\(Self.escapeHTML(title)) &mdash; \(date)</div>
            </div>
            \(bodyHTML)
            <div class="footer">
                Document genere automatiquement par Voxa
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Markdown → HTML

    static func markdownToHTML(_ markdown: String) -> String {
        var html = ""
        let lines = markdown.components(separatedBy: "\n")
        var inList = false
        var listType = "" // "ul" ou "ol"
        var paragraphLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                html += "<p>\(processInline(joined))</p>\n"
            }
            paragraphLines = []
        }

        func closeList() {
            if inList {
                html += "</\(listType)>\n"
                inList = false
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Ligne vide
            if trimmed.isEmpty {
                closeList()
                flushParagraph()
                continue
            }

            // Titres
            if trimmed.hasPrefix("#### ") {
                closeList(); flushParagraph()
                html += "<h4>\(processInline(String(trimmed.dropFirst(5))))</h4>\n"
                continue
            }
            if trimmed.hasPrefix("### ") {
                closeList(); flushParagraph()
                html += "<h3>\(processInline(String(trimmed.dropFirst(4))))</h3>\n"
                continue
            }
            if trimmed.hasPrefix("## ") {
                closeList(); flushParagraph()
                html += "<h2>\(processInline(String(trimmed.dropFirst(3))))</h2>\n"
                continue
            }
            if trimmed.hasPrefix("# ") {
                closeList(); flushParagraph()
                html += "<h1>\(processInline(String(trimmed.dropFirst(2))))</h1>\n"
                continue
            }

            // Liste non ordonnee
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                if !inList || listType != "ul" {
                    closeList()
                    html += "<ul>\n"
                    inList = true
                    listType = "ul"
                }
                html += "<li>\(processInline(String(trimmed.dropFirst(2))))</li>\n"
                continue
            }

            // Liste ordonnee
            if let (_, content) = parseOrderedItem(trimmed) {
                flushParagraph()
                if !inList || listType != "ol" {
                    closeList()
                    html += "<ol>\n"
                    inList = true
                    listType = "ol"
                }
                html += "<li>\(processInline(content))</li>\n"
                continue
            }

            // Separateur
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                closeList(); flushParagraph()
                html += "<hr>\n"
                continue
            }

            // Texte normal
            paragraphLines.append(trimmed)
        }

        closeList()
        flushParagraph()

        return html
    }

    // MARK: - Inline processing

    private static func processInline(_ text: String) -> String {
        var result = escapeHTML(text)

        // Bold: **text**
        result = result.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )

        // Italic: *text*
        result = result.replacingOccurrences(
            of: #"\*(.+?)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )

        // Inline code: `text`
        result = result.replacingOccurrences(
            of: #"`(.+?)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )

        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func parseOrderedItem(_ line: String) -> (Int, String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dotIndex]
        guard let number = Int(prefix), number > 0, number < 100 else { return nil }
        let afterDot = line[line.index(after: dotIndex)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        let content = afterDot.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (number, content)
    }

    // MARK: - Helpers

    private static func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.string(from: Date())
    }

    // MARK: - Errors

    enum PDFError: LocalizedError {
        case conversionFailed(String)
        case contextCreationFailed

        var errorDescription: String? {
            switch self {
            case .conversionFailed(let msg): "Erreur de conversion: \(msg)"
            case .contextCreationFailed: "Impossible de creer le contexte PDF"
            }
        }
    }
}
