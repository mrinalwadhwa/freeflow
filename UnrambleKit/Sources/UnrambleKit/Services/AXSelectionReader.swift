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
                var element = AXElementHelper.focusedElement()
                guard element != nil else {
                    return nil as String?
                }

                // Native text controls normally expose the selection directly.
                // Custom editors may put the range on a parent accessibility
                // element, so inspect a small bounded ancestor chain as well.
                for _ in 0..<6 {
                    guard let current = element else { break }
                    if let selected = AXElementHelper.selectedText(of: current),
                        !selected.isEmpty
                    {
                        return selected
                    }
                    element = AXElementHelper.parent(of: current)
                }
                return nil
            }
            return result ?? nil
        #else
            return nil
        #endif
    }
}
