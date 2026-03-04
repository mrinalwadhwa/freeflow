import Foundation

/// Tracks the recording lifecycle from idle through injection.
public enum RecordingState: Sendable, Equatable {
    case idle
    case recording
    case processing
    case injecting
    case injectionFailed
}
