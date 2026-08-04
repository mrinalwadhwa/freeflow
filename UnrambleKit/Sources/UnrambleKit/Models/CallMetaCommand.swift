import Foundation

/// A spoken command a conversation call executes itself instead of
/// sending to the focused application.
public enum CallMetaCommand: Equatable, Sendable {

    /// End the call, identically to Escape.
    case hangUp
}
