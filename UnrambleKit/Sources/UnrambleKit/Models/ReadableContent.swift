import Foundation

/// Content one source acquired for one read session.
///
/// Segments carry just enough structure for speech shaping to elide code
/// blocks, skip link lists, and announce headings. They carry no positions,
/// styling, or source handles, so speech shaping cannot reach back into the
/// app the content came from.
public struct ReadableContent: Sendable, Equatable {

    /// One run of same-kind text within the content.
    public struct Segment: Sendable, Equatable {

        public enum Kind: Sendable, Equatable {
            case prose
            case heading
            case code
            case quote
            case listItem
            case metadata
        }

        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Spoken before the content when the source needs to identify itself,
    /// e.g. "Claude Code in unramble" when several agents are reachable.
    public let attribution: String?

    /// Window title, message subject, or session title when the source has one.
    public let title: String?

    public let segments: [Segment]

    public init(
        attribution: String? = nil,
        title: String? = nil,
        segments: [Segment]
    ) {
        self.attribution = attribution
        self.title = title
        self.segments = segments
    }

    /// Whether the content has nothing speakable.
    public var isEmpty: Bool {
        segments.allSatisfy {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
