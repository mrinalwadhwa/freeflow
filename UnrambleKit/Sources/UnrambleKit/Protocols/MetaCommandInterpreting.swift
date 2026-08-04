import Foundation

/// Decide whether a call turn's utterance is a meta-command.
public protocol MetaCommandInterpreting: Sendable {

    /// Return the command the utterance expresses, or nil when the
    /// utterance is content to send. The whole utterance must be the
    /// command; a command phrase inside a longer sentence is content.
    func interpret(_ utterance: String) async -> CallMetaCommand?
}
