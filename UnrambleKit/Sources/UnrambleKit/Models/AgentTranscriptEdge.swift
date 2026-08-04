import Foundation

/// The live edge of a coding-agent session transcript.
///
/// The response watch reads it under quiescence: a still transcript
/// whose newest record is assistant text is a completed turn.
public struct AgentTranscriptEdge: Sendable {

    /// Whether the transcript's newest record is an assistant message
    /// with text — the shape of a completed turn.
    public let endsWithAssistantText: Bool

    /// The latest assistant response in the transcript, when one
    /// exists.
    public let latestResponse: AgentTranscriptResponse?

    public init(
        endsWithAssistantText: Bool,
        latestResponse: AgentTranscriptResponse?
    ) {
        self.endsWithAssistantText = endsWithAssistantText
        self.latestResponse = latestResponse
    }
}
