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
    /// type field. Built-in and USB mics are far-field (laptop at
    /// arm's length, desk mic at 1-2 ft). Bluetooth devices are
    /// near-field (close-talking headset).
    ///
    /// USB desk mics (e.g. Blue Yeti) at typical desk distance produce
    /// speech peaks of only 0.002 RMS — similar to the built-in mic
    /// and too quiet for reliable transcription without software gain.
    /// Classifying USB as far-field enables 10-16x gain and server-side
    /// far-field noise reduction, matching the built-in mic behavior.
    public var micProximity: MicProximity {
        switch transportType {
        case .builtIn, .usb:
            return .farField
        case .bluetooth, .other:
            return .nearField
        }
    }
}

/// Microphone proximity relative to the speaker's mouth.
///
/// Sent to the server so it can configure the OpenAI Realtime API's
/// `input_audio_noise_reduction` appropriately.
public enum MicProximity: String, Sendable, Equatable {
    /// Close-talking microphone (headphones, Bluetooth headset).
    case nearField = "near_field"
    /// Far-field microphone (built-in laptop mic, USB desk mic, conference room mic).
    case farField = "far_field"
}
