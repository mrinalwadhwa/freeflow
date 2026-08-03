import Foundation

/// Turns readable content into the text a synthesizer speaks.
///
/// A deliberately small placeholder for the speech-shaping stage: it
/// speaks attribution and title first, reads prose, headings, list items,
/// and quotes as they are, and announces code blocks by size instead of
/// reading them. Fuller shaping (URL and identifier normalization, link
/// list elision) replaces this type without touching acquisition.
public struct SpeechScriptBuilder: Sendable {

    public init() {}

    public func script(for content: ReadableContent) -> String {
        var lines: [String] = []
        if let attribution = content.attribution, !attribution.isEmpty {
            lines.append("\(attribution).")
        }
        if let title = content.title, !title.isEmpty {
            lines.append("\(title).")
        }
        for segment in content.segments {
            switch segment.kind {
            case .prose, .listItem, .quote, .metadata:
                lines.append(segment.text)
            case .heading:
                lines.append("\(segment.text).")
            case .code:
                // A one-line block is usually a command; the full formal
                // announcement grates when several appear in a row.
                let lineCount = segment.text
                    .components(separatedBy: "\n").count
                if lineCount == 1 {
                    lines.append("Command skipped.")
                } else {
                    lines.append("Code block, \(lineCount) lines, skipped.")
                }
            }
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
