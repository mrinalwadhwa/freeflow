import Foundation

/// A physical or virtual audio input device available on the system.
public struct AudioDevice: Sendable, Equatable, Identifiable {

    /// Core Audio device ID.
    public let id: UInt32

    /// Human-readable device name (e.g. "MacBook Pro Microphone").
    public let name: String

    /// Whether this is the system default input device.
    public let isDefault: Bool

    public init(id: UInt32, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}
