import Foundation

/// A physical or virtual audio input device available on the system.
public struct AudioDevice: Sendable, Equatable, Identifiable {

    /// How the device is connected to the system.
    public enum TransportType: Sendable, Equatable {
        /// Built-in microphone (e.g. MacBook Pro Microphone).
        case builtIn
        /// Bluetooth device (e.g. AirPods, headset).
        case bluetooth
        /// USB device (e.g. Yeti, Scarlett).
        case usb
        /// Virtual or aggregate device, or transport could not be determined.
        case other
    }

    /// Core Audio device ID.
    public let id: UInt32

    /// Human-readable device name (e.g. "MacBook Pro Microphone").
    public let name: String

    /// Whether this is the system default input device.
    public let isDefault: Bool

    /// How the device is physically connected.
    public let transportType: TransportType

    public init(
        id: UInt32,
        name: String,
        isDefault: Bool = false,
        transportType: TransportType = .other
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.transportType = transportType
    }

    /// Mic proximity hint for the server-side noise reduction config.
    ///
    /// Maps to the OpenAI Realtime API `input_audio_noise_reduction`
    /// type field. Built-in mics are far-field (laptop at arm's
    /// length); everything else is assumed near-field (close-talking
    /// headset, desk mic, etc.).
    public var micProximity: MicProximity {
        switch transportType {
        case .builtIn:
            return .farField
        case .bluetooth, .usb, .other:
            return .nearField
        }
    }
}

/// Microphone proximity relative to the speaker's mouth.
///
/// Sent to the server so it can configure the OpenAI Realtime API's
/// `input_audio_noise_reduction` appropriately.
public enum MicProximity: String, Sendable, Equatable {
    /// Close-talking microphone (headphones, USB desk mic).
    case nearField = "near_field"
    /// Far-field microphone (built-in laptop mic, conference room mic).
    case farField = "far_field"
}
