import Foundation
import Testing

@testable import UnrambleKit

@Suite("AX web content reader")
struct AXWebContentReaderTests {

    @Test("Reading a nonexistent process returns nil promptly")
    func nonexistentProcessReturnsNil() async {
        let reader = AXWebContentReader(timeout: 0.5)
        let content = await reader.readMainContent(processIdentifier: -1)
        #expect(content == nil)
    }

    @Test("Reading a process without a web area returns nil")
    func processWithoutWebAreaReturnsNil() async {
        // The test runner itself has no browser window; with no desktop
        // session there is no focused window at all. Either way the read
        // must return nil promptly without crashing.
        let reader = AXWebContentReader(timeout: 0.5)
        let content = await reader.readMainContent(
            processIdentifier: ProcessInfo.processInfo.processIdentifier)
        #expect(content == nil)
    }
}
