import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Bring the pinned agent's exact pane forward before a turn is
/// delivered.
///
/// Activating the terminal application is not enough: the injection
/// lands in whichever tab is frontmost, which may not host the pinned
/// session. iTerm2 and Terminal expose every session's tty over Apple
/// Events, so the focuser walks windows, tabs, and sessions to select
/// the one whose tty matches the pinned session, then activates the
/// application. Terminals without a known script fall back to plain
/// application activation.
public struct AppleEventTerminalFocuser: AgentFocusing {

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 1.2) {
        self.timeout = timeout
    }

    public func focusSession(
        bundleID: String,
        processIdentifier: Int32?,
        ttyDevice: Int32?
    ) async {
        if let ttyDevice,
            let ttyPath = Self.ttyPath(forDevice: ttyDevice),
            let script = Self.selectionScript(
                for: bundleID, ttyPath: ttyPath)
        {
            let operation = DetachedOperation { () -> Bool in
                Self.run(script: script)
            }
            let outcome = await operation.outcome(timeout: timeout)
            if case .completed(true) = outcome {
                await Self.awaitFocus(
                    on: bundleID,
                    processIdentifier: processIdentifier,
                    ttyPath: ttyPath,
                    timeout: timeout)
                return
            }
            operation.task.cancel()
        }
        await Self.activateApplication(processIdentifier)
    }

    /// Wait until the pinned session truly owns the keyboard: the
    /// terminal must be the frontmost application — activation is
    /// asynchronous, and the terminal reports its internal selection
    /// correctly while another app still holds key focus — and its
    /// selected session must be the pinned tty.
    private static func awaitFocus(
        on bundleID: String,
        processIdentifier: Int32?,
        ttyPath: String,
        timeout: TimeInterval
    ) async {
        guard
            let verifyScript = AppleEventTerminalFocusReader.script(
                for: bundleID)
        else {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return
        }
        var applicationActive = false
        var sessionSelected = false
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            applicationActive = await Self.isFrontmost(
                processIdentifier: processIdentifier)
            if applicationActive {
                let operation = DetachedOperation { () -> String? in
                    Self.runForString(script: verifyScript)
                }
                let outcome = await operation.outcome(timeout: timeout)
                if case let .completed(focused) = outcome {
                    sessionSelected = focused == ttyPath
                } else {
                    operation.task.cancel()
                }
                if sessionSelected {
                    Log.debug("[Focus] pinned session focus verified")
                    // One extra beat for the first responder inside
                    // the session to be ready for the paste.
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        Log.debug(
            "[Focus] not verified (app active: \(applicationActive), "
                + "session selected: \(sessionSelected)); proceeding")
    }

    /// Whether the application owns key focus system-wide.
    private static func isFrontmost(
        processIdentifier: Int32?
    ) async -> Bool {
        #if canImport(AppKit)
            guard let processIdentifier else { return true }
            return await MainActor.run {
                NSWorkspace.shared.frontmostApplication?
                    .processIdentifier == processIdentifier
            }
        #else
            return true
        #endif
    }

    /// The per-terminal script that selects the session owning the
    /// tty, then brings the application forward.
    static func selectionScript(
        for bundleID: String,
        ttyPath: String
    ) -> String? {
        switch bundleID {
        case "com.googlecode.iterm2":
            return """
                tell application "iTerm2"
                    activate
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(ttyPath)" then
                                    select s
                                    select t
                                    select w
                                    return "selected"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """
        case "com.apple.Terminal":
            return """
                tell application "Terminal"
                    activate
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(ttyPath)" then
                                set selected tab of w to t
                                set frontmost of w to true
                                return "selected"
                            end if
                        end repeat
                    end repeat
                end tell
                """
        default:
            return nil
        }
    }

    /// Resolve a controlling-tty device number back to its path, the
    /// inverse of the reader's stat lookup.
    static func ttyPath(forDevice device: Int32) -> String? {
        guard let name = devname(dev_t(device), mode_t(S_IFCHR)) else {
            return nil
        }
        return "/dev/" + String(cString: name)
    }

    private static func run(script source: String) -> Bool {
        runForString(script: source) == "selected"
    }

    private static func runForString(script source: String) -> String? {
        #if canImport(AppKit)
            guard let script = NSAppleScript(source: source) else {
                return nil
            }
            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            guard error == nil else { return nil }
            return descriptor.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        #else
            return nil
        #endif
    }

    private static func activateApplication(_ pid: Int32?) async {
        #if canImport(AppKit)
            guard let pid else { return }
            await MainActor.run {
                _ = NSRunningApplication(processIdentifier: pid)?.activate()
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        #endif
    }
}
