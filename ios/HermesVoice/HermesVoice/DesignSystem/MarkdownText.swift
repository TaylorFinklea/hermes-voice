import SwiftUI

/// Lightweight markdown renderer for assistant replies — no third-party deps.
///
/// Splits the text into block elements (headings, paragraphs, bullet/numbered
/// lists, fenced code, blockquotes) and styles each; inline spans
/// (bold/italic/`code`/links) render via `AttributedString`. SwiftUI's plain
/// `Text(String)` shows literal `##`, `*`, and code fences, which is what the
/// transcript used to look like. The SPOKEN copy is de-markdowned separately
/// (LocalSpeaker.makeSpeakable / backend make_speakable), so the screen can show
/// the rich version while the ear hears clean prose.
struct MarkdownText: View {
    let markdown: String
    var bodyFont: Font = HVFont.heroReply
    var color: Color = HVColor.cream

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                block.view(bodyFont: bodyFont, color: color)
            }
        }
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(marker: String, text: String)
    case quote(String)
    case code(String)

    @ViewBuilder
    func view(bodyFont: Font, color: Color) -> some View {
        switch self {
        case let .heading(level, text):
            Self.inline(text)
                .font(level <= 2 ? .system(size: 17, weight: .bold)
                                 : .system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        case let .paragraph(text):
            Self.inline(text)
                .font(bodyFont)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        case let .bullet(text):
            HStack(alignment: .top, spacing: 7) {
                Text("•").font(bodyFont).foregroundStyle(HVColor.bronze)
                Self.inline(text).font(bodyFont).foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .numbered(marker, text):
            HStack(alignment: .top, spacing: 7) {
                Text(marker).font(bodyFont).foregroundStyle(HVColor.bronze).monospacedDigit()
                Self.inline(text).font(bodyFont).foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(HVColor.bronze.opacity(0.6))
                    .frame(width: 2)
                Self.inline(text).font(bodyFont).foregroundStyle(HVColor.creamDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(HVColor.cream)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(HVColor.creamSurface))
        }
    }

    /// Inline markdown (bold/italic/`code`/links) via `AttributedString`; falls
    /// back to plain text. `inlineOnlyPreservingWhitespace` keeps the text as one
    /// run (no block reflow) and renders emphasis/code/links.
    private static func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var paragraph: [String] = []
        var i = 0
        let n = lines.count

        func flush() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while i < n {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceMarker(trimmed) {          // fenced code block
                flush()
                var code: [String] = []
                i += 1
                while i < n {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flush(); i += 1; continue }

            if let h = headingMatch(trimmed) {
                flush(); blocks.append(.heading(level: h.0, text: h.1)); i += 1; continue
            }
            if isHorizontalRule(trimmed) {                 // before bullet: "***" etc.
                flush(); i += 1; continue
            }
            if let b = bulletMatch(line) {
                flush(); blocks.append(.bullet(b)); i += 1; continue
            }
            if let num = numberedMatch(line) {
                flush(); blocks.append(.numbered(marker: num.0, text: num.1)); i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    private static func fenceMarker(_ t: String) -> String? {
        if t.hasPrefix("```") { return "```" }
        if t.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func headingMatch(_ t: String) -> (Int, String)? {
        var level = 0
        var idx = t.startIndex
        while idx < t.endIndex, t[idx] == "#", level < 7 {
            level += 1
            idx = t.index(after: idx)
        }
        guard level >= 1, level <= 6, idx < t.endIndex, t[idx] == " " else { return nil }
        return (level, String(t[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private static func isHorizontalRule(_ t: String) -> Bool {
        guard let first = t.first, first == "-" || first == "*" || first == "_" else { return false }
        let stripped = t.filter { !$0.isWhitespace }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    private static func bulletMatch(_ line: String) -> String? {
        let t = line.drop { $0 == " " || $0 == "\t" }
        guard let first = t.first, first == "-" || first == "*" || first == "+" else { return nil }
        let after = t.dropFirst()
        guard after.first == " " else { return nil }
        return String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func numberedMatch(_ line: String) -> (String, String)? {
        let t = line.drop { $0 == " " || $0 == "\t" }
        var digits = ""
        var idx = t.startIndex
        while idx < t.endIndex, t[idx].isNumber {
            digits.append(t[idx])
            idx = t.index(after: idx)
        }
        guard !digits.isEmpty, idx < t.endIndex, t[idx] == "." || t[idx] == ")" else { return nil }
        let sep = t[idx]
        let after = t.index(after: idx)
        guard after < t.endIndex, t[after] == " " else { return nil }
        return ("\(digits)\(sep)", String(t[after...]).trimmingCharacters(in: .whitespaces))
    }
}
