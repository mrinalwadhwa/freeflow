import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Reads the focused element's selected text through the Accessibility API.
///
/// Applies to any element role, unlike the dictation snapshot's
/// text-input-gated read, so selections in web pages and document viewers
/// are also readable. Reads are passive: nothing about the element's
/// focus, selection, or scroll position changes.
public struct AXSelectionReader: SelectionReading {

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 0.25) {
        self.timeout = timeout
    }

    public func readSelectedText() async -> String? {
        #if canImport(ApplicationServices)
            let result = await withTimeout(seconds: timeout) {
                guard let focused = AXElementHelper.focusedElement() else {
                    return nil as String?
                }
                return AXElementHelper.selectedText(of: focused)
            }
            return result ?? nil
        #else
            return nil
        #endif
    }
}
