import Foundation

#if canImport(AppKit)
    import AppKit
    import CoreGraphics
#endif

/// Copies a custom editor's selection, reads its plain text, and restores the
/// user's pasteboard. The operation runs on the main actor because AppKit's
/// pasteboard and the run loop are main-thread services.
public struct PasteboardCopySelectionReader: CopySelectionReading {

    /// A generous ceiling prevents an accidental whole-document copy from
    /// retaining an unbounded string while still allowing book-length prose.
    private static let maximumUTF8ByteCount = 8 * 1_024 * 1_024
    private static let copyTimeout: TimeInterval = 1.0

    public init() {}

    public func copySelectedText() async -> String? {
        #if canImport(AppKit)
            return await MainActor.run { Self.copyOnMainActor() }
        #else
            return nil
        #endif
    }

    #if canImport(AppKit)
        private struct SavedItem {
            let types: [NSPasteboard.PasteboardType]
            let dataByType: [NSPasteboard.PasteboardType: Data]
        }

        @MainActor
        private static func copyOnMainActor() -> String? {
            let pasteboard = NSPasteboard.general
            let originalChangeCount = pasteboard.changeCount
            let savedItems = saveContents(of: pasteboard)

            guard postCopyCommand() else { return nil }

            let deadline = Date().addingTimeInterval(copyTimeout)
            while pasteboard.changeCount == originalChangeCount,
                Date() < deadline
            {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.005))
            }

            guard pasteboard.changeCount != originalChangeCount else {
                return nil
            }
            let copiedChangeCount = pasteboard.changeCount
            let copied = pasteboard.string(forType: .string)

            // Do not overwrite a clipboard change made by the user, a
            // clipboard manager, or another process while the copy completed.
            if pasteboard.changeCount == copiedChangeCount {
                restore(savedItems, to: pasteboard)
            }

            guard let copied,
                !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                copied.utf8.count <= maximumUTF8ByteCount
            else { return nil }
            return copied
        }

        @MainActor
        private static func postCopyCommand() -> Bool {
            guard let source = CGEventSource(stateID: .hidSystemState),
                let keyDown = CGEvent(
                    keyboardEventSource: source, virtualKey: 8, keyDown: true),
                let keyUp = CGEvent(
                    keyboardEventSource: source, virtualKey: 8, keyDown: false)
            else { return false }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return true
        }

        @MainActor
        private static func saveContents(
            of pasteboard: NSPasteboard
        ) -> [SavedItem] {
            guard let items = pasteboard.pasteboardItems else { return [] }
            return items.compactMap { item in
                var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        dataByType[type] = data
                    }
                }
                guard !dataByType.isEmpty else { return nil }
                return SavedItem(types: item.types, dataByType: dataByType)
            }
        }

        @MainActor
        private static func restore(
            _ savedItems: [SavedItem], to pasteboard: NSPasteboard
        ) {
            pasteboard.clearContents()
            guard !savedItems.isEmpty else { return }
            let items = savedItems.map { saved in
                let item = NSPasteboardItem()
                for type in saved.types {
                    if let data = saved.dataByType[type] {
                        item.setData(data, forType: type)
                    }
                }
                return item
            }
            pasteboard.writeObjects(items)
        }
    #endif
}
