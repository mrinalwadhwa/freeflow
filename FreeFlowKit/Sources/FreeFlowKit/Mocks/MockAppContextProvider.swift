import Foundation

/// A mock implementation of `AppContextProviding` that returns a configurable stub context.
///
/// Used in tests to exercise the pipeline without real accessibility API calls
/// and to verify context-dependent behavior.
public final class MockAppContextProvider: AppContextProviding, @unchecked Sendable {

    /// The context that will be returned by `readContext()`.
    /// Change this between calls to simulate different app states.
    public var stubbedContext: AppContext

    /// Number of times `readContext()` has been called.
    public private(set) var readContextCallCount: Int = 0

    public init(context: AppContext = .stub) {
        self.stubbedContext = context
    }

    public func readContext() async -> AppContext {
        readContextCallCount += 1
        return stubbedContext
    }
}

extension AppContext {

    /// A stub context representing a generic text editor for use in tests and mocks.
    public static let stub = AppContext(
        bundleID: "com.apple.TextEdit",
        appName: "TextEdit",
        windowTitle: "Untitled",
        browserURL: nil,
        focusedFieldContent: "Some existing text in the field.",
        selectedText: nil,
        cursorPosition: 31
    )
}
