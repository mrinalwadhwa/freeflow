import Foundation

#if canImport(AppKit)
    import AppKit
#endif

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Inject text into the active application using app-aware strategies.
///
/// Three injection strategies are supported, tried in order of preference:
/// 1. **Accessibility API** — set kAXValueAttribute directly on the focused element
/// 2. **Pasteboard + Cmd+V** — copy to clipboard and simulate paste (preserves original clipboard)
/// 3. **Keystroke simulation** — simulate individual key events via CGEvent
///
/// The strategy is selected per-app based on bundle ID. If the preferred strategy
/// fails, the injector falls back to the next one before throwing.
public final class AppTextInjector: TextInjecting, @unchecked Sendable {

    /// Error types for text injection failures.
    public enum InjectionError: Error, Sendable, CustomStringConvertible {
        case noFocusedElement
        case allStrategiesFailed(bundleID: String)
        case accessibilityNotGranted

        public var description: String {
            switch self {
            case .noFocusedElement:
                return "No focused UI element found for text injection"
            case .allStrategiesFailed(let bundleID):
                return "All injection strategies failed for app: \(bundleID)"
            case .accessibilityNotGranted:
                return "Accessibility permission is not granted"
            }
        }
    }

    /// Map bundle IDs to their preferred injection strategy order.
    ///
    /// Apps not in this map use the default order: accessibility → pasteboard → keystroke.
    private static let strategyMap: [String: [InjectionStrategy]] = [
        // Native macOS apps — accessibility works well
        "com.apple.TextEdit": [.accessibility, .pasteboard],
        "com.apple.Notes": [.accessibility, .pasteboard],
        "com.apple.mail": [.accessibility, .pasteboard],
        "com.apple.dt.Xcode": [.accessibility, .pasteboard],

        // Terminal — pasteboard is most reliable
        "com.apple.Terminal": [.pasteboard, .keystroke],
        "com.googlecode.iterm2": [.pasteboard, .keystroke],

        // Electron apps — pasteboard is most reliable
        "com.tinyspeck.slackmacgap": [.pasteboard, .accessibility],
        "com.microsoft.VSCode": [.pasteboard, .keystroke],
        "com.hnc.Discord": [.pasteboard, .keystroke],
        "notion.id": [.pasteboard, .accessibility],
        "md.obsidian": [.pasteboard, .accessibility],

        // Browsers — pasteboard for web content fields
        "com.apple.Safari": [.pasteboard, .accessibility],
        "com.google.Chrome": [.pasteboard, .accessibility],
        "com.microsoft.edgemac": [.pasteboard, .accessibility],
        "com.brave.Browser": [.pasteboard, .accessibility],
        "company.thebrowser.Browser": [.pasteboard, .accessibility],  // Arc
        "org.mozilla.firefox": [.pasteboard, .keystroke],

        // Messages — pasteboard
        "com.apple.MobileSMS": [.pasteboard, .accessibility],
    ]

    /// Default strategy order when an app is not in the strategy map.
    private static let defaultStrategies: [InjectionStrategy] = [
        .accessibility, .pasteboard, .keystroke,
    ]

    public init() {}

    // MARK: - TextInjecting

    public func inject(text: String, into context: AppContext) async throws {
        let strategies = AppTextInjector.strategies(for: context.bundleID)
        var lastError: Error?

        for strategy in strategies {
            do {
                switch strategy {
                case .accessibility:
                    try injectViaAccessibility(text: text, into: context)
                    return
                case .pasteboard:
                    try injectViaPasteboard(text: text)
                    return
                case .keystroke:
                    try injectViaKeystrokes(text: text)
                    return
                }
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? InjectionError.allStrategiesFailed(bundleID: context.bundleID)
    }

    // MARK: - Strategy Selection

    /// Return the ordered list of strategies to try for the given bundle ID.
    public static func strategies(for bundleID: String) -> [InjectionStrategy] {
        return strategyMap[bundleID] ?? defaultStrategies
    }

    // MARK: - Strategy 1: Accessibility API

    /// Inject text by setting the accessibility value on the focused element.
    ///
    /// For text fields that support kAXValueAttribute writes, this inserts text
    /// at the cursor position (or replaces the selection) by reading the current
    /// value, splicing in the new text, and writing back the full value.
    private func injectViaAccessibility(text: String, into context: AppContext) throws {
        guard let focused = AXElementHelper.focusedElement() else {
            throw InjectionError.noFocusedElement
        }

        guard AXElementHelper.isTextInput(focused) else {
            throw InjectionError.noFocusedElement
        }

        let textToInject = addLeadingSpaceIfNeeded(
            text: text,
            fieldContent: context.focusedFieldContent,
            cursorPosition: context.cursorPosition
        )

        // Read current value and cursor position to splice text in
        let currentValue = AXElementHelper.textContent(of: focused) ?? ""
        let cursorPos = AXElementHelper.cursorPosition(of: focused)
        let selectedRange = AXElementHelper.rangeValue(
            of: kAXSelectedTextRangeAttribute, from: focused)

        let newValue: String
        let newCursorPos: Int

        if let range = selectedRange, range.length > 0 {
            // Replace selected text
            let start = currentValue.index(
                currentValue.startIndex,
                offsetBy: min(range.location, currentValue.count))
            let end = currentValue.index(
                start,
                offsetBy: min(range.length, currentValue.count - range.location))
            var mutable = currentValue
            mutable.replaceSubrange(start..<end, with: textToInject)
            newValue = mutable
            newCursorPos = range.location + textToInject.count
        } else if let pos = cursorPos {
            // Insert at cursor position
            let index = currentValue.index(
                currentValue.startIndex,
                offsetBy: min(pos, currentValue.count))
            var mutable = currentValue
            mutable.insert(contentsOf: textToInject, at: index)
            newValue = mutable
            newCursorPos = pos + textToInject.count
        } else {
            // Append to end
            newValue = currentValue + textToInject
            newCursorPos = newValue.count
        }

        guard AXElementHelper.setValue(newValue, on: focused) else {
            throw InjectionError.allStrategiesFailed(bundleID: "accessibility-set-failed")
        }

        // Move cursor to end of injected text
        let cursorRange = CFRange(location: newCursorPos, length: 0)
        AXElementHelper.setSelectedTextRange(cursorRange, on: focused)
    }

    // MARK: - Strategy 2: Pasteboard + Cmd+V

    /// Inject text by copying it to the pasteboard and simulating Cmd+V.
    ///
    /// The previous clipboard content is saved and restored after pasting.
    /// A short delay is introduced between clipboard write and paste to give
    /// the system time to process.
    private func injectViaPasteboard(text: String) throws {
        #if canImport(AppKit)
            let pasteboard = NSPasteboard.general

            // Save current clipboard content
            let savedItems = savePasteboardContents(pasteboard)

            // Write the text to inject
            pasteboard.clearContents()

            let textToInject = addLeadingSpaceIfNeededFromFocused(text: text)
            pasteboard.setString(textToInject, forType: .string)

            // Small delay for pasteboard to settle
            Thread.sleep(forTimeInterval: 0.01)

            // Simulate Cmd+V
            simulatePaste()

            // Wait for the paste to complete before restoring
            Thread.sleep(forTimeInterval: 0.05)

            // Restore previous clipboard content
            restorePasteboardContents(pasteboard, items: savedItems)
        #else
            throw InjectionError.allStrategiesFailed(bundleID: "pasteboard-unavailable")
        #endif
    }

    // MARK: - Strategy 3: Keystroke Simulation

    /// Inject text by simulating individual keystrokes via CGEvent.
    ///
    /// This is the slowest strategy but works for apps that do not respond to
    /// accessibility value writes or paste commands. Each character is sent as
    /// a key-down/key-up pair using CGEvent with Unicode input.
    private func injectViaKeystrokes(text: String) throws {
        let textToInject = addLeadingSpaceIfNeededFromFocused(text: text)

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectionError.allStrategiesFailed(bundleID: "cgevent-source-failed")
        }

        for character in textToInject.utf16 {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            else {
                continue
            }
            guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                continue
            }

            var char = character
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            // Small delay between keystrokes to avoid overwhelming the target app
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    // MARK: - Paste Simulation

    /// Simulate Cmd+V (paste) using CGEvent.
    private func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        // Virtual key code for 'V' is 9
        let vKeyCode: CGKeyCode = 9

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        else { return }
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard Preservation

    #if canImport(AppKit)
        /// Saved pasteboard item with its type and data.
        private struct SavedPasteboardItem {
            let types: [NSPasteboard.PasteboardType]
            let dataByType: [NSPasteboard.PasteboardType: Data]
        }

        /// Save all items from the pasteboard for later restoration.
        private func savePasteboardContents(_ pasteboard: NSPasteboard) -> [SavedPasteboardItem] {
            guard let items = pasteboard.pasteboardItems else { return [] }

            return items.compactMap { item in
                let types = item.types
                var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in types {
                    if let data = item.data(forType: type) {
                        dataByType[type] = data
                    }
                }
                guard !dataByType.isEmpty else { return nil }
                return SavedPasteboardItem(types: types, dataByType: dataByType)
            }
        }

        /// Restore previously saved items to the pasteboard.
        private func restorePasteboardContents(
            _ pasteboard: NSPasteboard, items: [SavedPasteboardItem]
        ) {
            guard !items.isEmpty else { return }

            pasteboard.clearContents()

            for saved in items {
                let item = NSPasteboardItem()
                for type in saved.types {
                    if let data = saved.dataByType[type] {
                        item.setData(data, forType: type)
                    }
                }
                pasteboard.writeObjects([item])
            }
        }
    #endif

    // MARK: - Smart Leading Space

    /// Add a leading space before the injected text if the character before the
    /// cursor is not whitespace or punctuation that typically precedes a word.
    ///
    /// - Parameters:
    ///   - text: The text to inject.
    ///   - fieldContent: The current content of the focused field.
    ///   - cursorPosition: The current cursor position in the field.
    /// - Returns: The text, potentially with a leading space prepended.
    func addLeadingSpaceIfNeeded(
        text: String,
        fieldContent: String?,
        cursorPosition: Int?
    ) -> String {
        guard let content = fieldContent, let pos = cursorPosition else {
            return text
        }

        // If cursor is at the start, no space needed
        guard pos > 0 else { return text }

        // If the content is shorter than expected, bail
        guard pos <= content.count else { return text }

        let index = content.index(content.startIndex, offsetBy: pos - 1)
        let charBefore = content[index]

        // If the text already starts with a space or newline, don't add another
        if text.hasPrefix(" ") || text.hasPrefix("\n") { return text }

        // If the text starts with punctuation, don't add a space before it
        if let first = text.first, first.isPunctuation { return text }

        // Characters that don't need a space after them
        let noSpaceAfter: Set<Character> = [
            " ", "\t", "\n", "\r",  // whitespace
            "(", "[", "{", "<",  // opening brackets
            "\"", "'", "`",  // opening quotes
            "/", "\\",  // path separators
        ]

        if noSpaceAfter.contains(charBefore) {
            return text
        }

        return " " + text
    }

    /// Add a leading space by reading the currently focused element's state.
    ///
    /// Used by pasteboard and keystroke strategies that don't receive a fresh
    /// AppContext. Reads the focused element directly via AXUIElement.
    private func addLeadingSpaceIfNeededFromFocused(text: String) -> String {
        guard let focused = AXElementHelper.focusedElement() else {
            return text
        }
        guard AXElementHelper.isTextInput(focused) else {
            return text
        }

        let content = AXElementHelper.textContent(of: focused)
        let cursorPos = AXElementHelper.cursorPosition(of: focused)

        return addLeadingSpaceIfNeeded(
            text: text,
            fieldContent: content,
            cursorPosition: cursorPos
        )
    }
}
