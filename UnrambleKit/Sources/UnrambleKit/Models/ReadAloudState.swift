import Foundation

/// State of the current read session, published for UI observation.
public enum ReadAloudState: Sendable, Equatable {
    case idle
    case acquiring
    case speaking

    /// The last session ended because no source yielded content. The UI
    /// shows guidance until `dismissGuidance` runs or a new session starts.
    case noContent
}
