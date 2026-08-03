import Foundation

/// Asks the frontmost terminal which session has keyboard focus.
///
/// iTerm2 and Terminal expose the focused session's tty over Apple
/// Events, down to the focused split pane, so a read session can target
/// exactly the pane that would receive typed text. The first use asks
/// the user for automation consent; while that dialog is open (or when
/// consent is denied) the read times out and the caller falls back to
/// other signals.
///
/// The blocking Apple Event send runs as a detached operation so the
/// deadline returns promptly; an abandoned send resolves harmlessly
/// whenever the dialog is answered.
public struct AppleEventTerminalFocusReader: TerminalFocusReading {

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 1.2) {
        self.timeout = timeout
    }

    public func focusedSessionTTY(bundleID: String) async -> Int32? {
        guard let script = Self.script(for: bundleID) else { return nil }
        let operation = DetachedOperation { () -> String? in
            Self.run(script: script)
        }
        let outcome = await operation.outcome(timeout: timeout)
        guard case let .completed(ttyPath) = outcome else {
            operation.task.cancel()
            return nil
        }
        guard let ttyPath else { return nil }
        return Self.deviceNumber(forTTYPath: ttyPath)
    }

    /// The per-terminal script that answers with the focused session's
    /// tty path. Terminals without a known script are not asked.
    static func script(for bundleID: String) -> String? {
        switch bundleID {
        case "com.googlecode.iterm2":
            return #"tell application "iTerm2" to tty of current session of current window"#
        case "com.apple.Terminal":
            return #"tell application "Terminal" to tty of selected tab of front window"#
        default:
            return nil
        }
    }

    /// Resolve a tty path such as "/dev/ttys003" to its device number,
    /// the same value the process table reports as the controlling tty.
    static func deviceNumber(forTTYPath path: String) -> Int32? {
        guard path.hasPrefix("/dev/") else { return nil }
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Int32(status.st_rdev)
    }

    private static func run(script source: String) -> String? {
        #if canImport(AppKit)
            guard let script = NSAppleScript(source: source) else { return nil }
            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            guard error == nil else { return nil }
            let value = descriptor.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { return nil }
            return value
        #else
            return nil
        #endif
    }
}
