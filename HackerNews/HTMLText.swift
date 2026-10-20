import SwiftUI

/// Converts the small HTML subset HN uses (p, i, b, a, pre/code) to an AttributedString.
enum HTMLText {
    static func attributed(_ html: String, size: CGFloat = 16) -> AttributedString {
        var result = AttributedString()
        var italic = false, bold = false, code = false
        var link: URL?
        var first = true

        let token = #/<(\/?)([a-zA-Z]+)([^>]*)>|([^<]+)/#
        for match in html.matches(of: token) {
            if let text = match.output.4 {
                var piece = AttributedString(decode(String(text)))
                var font: Font = code ? .system(size: size - 2, design: .monospaced) : Theme.body(size)
                if italic { font = font.italic() }
                if bold { font = font.bold() }
                piece.font = font
                if let link {
                    piece.link = link
                    piece.underlineStyle = .single
                    piece.foregroundColor = Theme.accent
                }
                result += piece
                first = false
                continue
            }
            let closing = match.output.1 == "/"
            switch (match.output.2 ?? "").lowercased() {
            case "p":
                if !closing && !first { result += AttributedString("\n\n") }
            case "i", "em": italic = !closing
            case "b", "strong": bold = !closing
            case "pre":
                if !closing && !first { result += AttributedString("\n\n") }
            case "code": code = !closing
            case "a":
                if closing {
                    link = nil
                } else if let href = match.output.3?.firstMatch(of: #/href="([^"]*)"/#)?.output.1 {
                    link = URL(string: decode(String(href)))
                }
            default: break
            }
        }
        return result
    }

    static func plain(_ html: String) -> String {
        String(attributed(html).characters)
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, char) in [("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&#x2F;", "/"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        out = out.replacing(#/&#x([0-9a-fA-F]+);/#) { m in
            UInt32(m.output.1, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(m.output.0)
        }
        out = out.replacing(#/&#([0-9]+);/#) { m in
            UInt32(m.output.1).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(m.output.0)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
