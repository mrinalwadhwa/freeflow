import Foundation

/// Orchestrates the full dictation pipeline: hotkey → record + read context →
/// stop recording → process audio → inject text.
///
/// Implementations wire together an `AudioProviding`, `AppContextProviding`,
/// and `TextInjecting` to drive the end-to-end flow. The recording state
/// machine lives behind this protocol.
public protocol PipelineProviding: Sendable {

    /// Called when the hotkey is pressed. Starts audio recording and
    /// begins reading app context in parallel.
    func activate() async

    /// Called when the hotkey is released. Stops recording, sends audio
    /// and context through the processing pipeline, and injects the
    /// resulting text into the active app.
    func complete() async

    /// Cancels an in-progress pipeline run and resets to idle.
    func cancel() async

    /// The current recording state. Observe this to drive UI updates
    /// (menu bar icon, HUD overlay).
    var state: RecordingState { get async }
}
