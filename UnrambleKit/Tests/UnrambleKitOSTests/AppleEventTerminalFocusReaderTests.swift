import Foundation
import Testing

@testable import UnrambleKit

@Suite("Apple Event terminal focus reader")
struct AppleEventTerminalFocusReaderTests {

    @Test("Only known terminals get a script")
    func onlyKnownTerminalsGetScript() {
        #expect(
            AppleEventTerminalFocusReader.script(
                for: "com.googlecode.iterm2") != nil)
        #expect(
            AppleEventTerminalFocusReader.script(
                for: "com.apple.Terminal") != nil)
        #expect(
            AppleEventTerminalFocusReader.script(
                for: "com.apple.Safari") == nil)
    }

    @Test("An unknown app is never asked and yields nil")
    func unknownAppYieldsNil() async {
        let reader = AppleEventTerminalFocusReader(timeout: 0.1)
        #expect(
            await reader.focusedSessionTTY(bundleID: "com.apple.Safari")
                == nil)
    }

    @Test("A tty path resolves to its device number")
    func ttyPathResolvesToDevice() {
        // /dev/console always exists, even on a headless runner.
        let device = AppleEventTerminalFocusReader.deviceNumber(
            forTTYPath: "/dev/console")
        #expect(device != nil)
    }

    @Test("Paths outside /dev resolve to nil")
    func nonDevicePathsResolveToNil() {
        #expect(
            AppleEventTerminalFocusReader.deviceNumber(forTTYPath: "/etc/hosts")
                == nil)
        #expect(
            AppleEventTerminalFocusReader.deviceNumber(
                forTTYPath: "/dev/does-not-exist") == nil)
    }
}
