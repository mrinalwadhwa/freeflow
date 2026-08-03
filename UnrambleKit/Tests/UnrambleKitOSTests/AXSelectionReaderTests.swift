import Foundation
import Testing

@testable import UnrambleKit

@Suite("AX selection reader")
struct AXSelectionReaderTests {

    @Test("Reading degrades gracefully without a focused selection")
    func readDegradesGracefully() async {
        // On a headless runner there is no focused element; with a desktop
        // session the focused element may or may not have a selection.
        // Either way the read must return promptly without crashing.
        let reader = AXSelectionReader(timeout: 0.1)
        _ = await reader.readSelectedText()
    }
}
