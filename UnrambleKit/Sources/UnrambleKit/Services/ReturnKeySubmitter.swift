import CoreGraphics
import Foundation

/// Press Return in the frontmost application.
///
/// Posts through the HID event tap, the same route keystroke
/// injection uses, so the submit lands wherever the injected turn
/// just landed.
public struct ReturnKeySubmitter: TurnSubmitting {

    /// Virtual key code for Return (kVK_Return).
    private static let returnKeyCode: CGKeyCode = 36

    public init() {}

    public func submitTurn() async {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.returnKeyCode,
                keyDown: true),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.returnKeyCode,
                keyDown: false)
        else { return }
        // Clear inherited modifier state: a flag left over from paste
        // injection or the user's hands would turn the submit into a
        // chord — iTerm toggles fullscreen on Command-Return.
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
