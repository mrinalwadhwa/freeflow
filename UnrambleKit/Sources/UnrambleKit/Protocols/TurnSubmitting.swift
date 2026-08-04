import Foundation

/// Submit an injected turn to a coding-agent session.
///
/// Injection types the text; submission presses Return so the agent
/// starts working on it. Only coding-agent targets are submitted — a
/// turn sent to any other application stays plain dictation.
public protocol TurnSubmitting: Sendable {

    /// Press Return in the frontmost application.
    func submitTurn() async
}
