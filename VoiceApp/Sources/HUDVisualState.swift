import Foundation

/// Visual states for the HUD overlay.
///
/// Derived from `RecordingState` (pipeline) combined with UI-local signals:
/// hover, activation mode (held vs hands-free), slow-processing timer, and
/// injection failure. The HUD controller owns this derivation; VoiceKit
/// knows nothing about these states.
enum HUDVisualState: Equatable {

    /// Tiny capsule outline. The app is alive and idle. Accepts hover and click.
    case minimized

    /// Expanded pill with hotkey hint. Shown when hovering the minimized capsule.
    case ready

    /// Push-to-talk listening. Waveform dots, no buttons. Keyboard owns this state.
    case listeningHeld

    /// Hands-free listening. Waveform dots with ✕ (cancel) and ■ (stop) buttons.
    case listeningHandsFree

    /// STT in flight, fast path. Animated indicator, no cancel affordance.
    case processing

    /// STT in flight, slow path (threshold exceeded). Shows reassurance message
    /// and ✕ cancel affordance.
    case processingSlow

    /// Injection failed — no focused text field. Shows paste-shortcut hint and ✕ dismiss.
    case noTarget

    /// Whether the HUD should accept mouse events in this state.
    ///
    /// States that rely on the keyboard as the control surface disable mouse
    /// events so clicks pass through to the app underneath.
    var acceptsMouseEvents: Bool {
        switch self {
        case .minimized, .ready, .listeningHandsFree, .processingSlow, .noTarget:
            return true
        case .listeningHeld, .processing:
            return false
        }
    }

    /// Whether the pill should show at its expanded width.
    ///
    /// Minimized uses a compact capsule; all other states expand the pill
    /// to show content (hint text, waveform, buttons, or messages).
    var isExpanded: Bool {
        self != .minimized
    }

    /// Whether waveform dots should animate in this state.
    var showsWaveform: Bool {
        switch self {
        case .listeningHeld, .listeningHandsFree:
            return true
        default:
            return false
        }
    }

    /// Whether the processing animation should be visible.
    var showsProcessingIndicator: Bool {
        switch self {
        case .processing, .processingSlow:
            return true
        default:
            return false
        }
    }

    /// Whether cancel (✕) and stop (■) buttons should be visible.
    var showsHandsFreeControls: Bool {
        self == .listeningHandsFree
    }

    /// Whether a cancel (✕) affordance should be visible.
    ///
    /// Available in hands-free listening, slow processing, and no-target states.
    var showsCancelButton: Bool {
        switch self {
        case .listeningHandsFree, .processingSlow, .noTarget:
            return true
        default:
            return false
        }
    }

    /// Whether the stop (■) button should be visible.
    var showsStopButton: Bool {
        self == .listeningHandsFree
    }
}
