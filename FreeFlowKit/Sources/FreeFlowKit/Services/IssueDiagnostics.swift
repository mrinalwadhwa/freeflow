import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Collects system information, recent log history, and mic diagnostics
/// into a pre-filled GitHub issue URL for one-click error reporting.
///
/// Used by the "Report an Issue..." menu item and the "Report this issue"
/// link on error screens. Follows the same pattern as "Contribute Mic Data"
/// but captures general diagnostics instead of mic-specific data.
public enum IssueDiagnostics {

    /// The GitHub repo where issues are filed.
    private static let repoURL = "https://github.com/build-trust/freeflow/issues/new"

    /// Build a GitHub issue URL pre-filled with diagnostics.
    ///
    /// - Parameters:
    ///   - title: A short summary for the issue title. Defaults to empty
    ///     so the user fills it in.
    ///   - errorMessage: An optional error message to highlight at the top
    ///     of the issue body (e.g. from a "Something went wrong" screen).
    ///   - micDiagnostics: Formatted mic diagnostic string from
    ///     `MicDiagnosticStore.formattedDiagnostics()`. Pass nil to omit.
    /// - Returns: A URL that opens the GitHub new-issue page with the body
    ///   pre-filled, or nil if URL construction fails.
    public static func issueURL(
        title: String = "",
        errorMessage: String? = nil,
        micDiagnostics: String? = nil
    ) -> URL? {
        // Build the full diagnostics and copy to clipboard.
        let fullDiagnostics = buildFullDiagnostics(
            errorMessage: errorMessage,
            micDiagnostics: micDiagnostics
        )
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fullDiagnostics, forType: .string)
        #endif

        // The URL body is kept short: system info + paste prompt.
        let body = buildURLBody(errorMessage: errorMessage)

        var components = URLComponents(string: repoURL)!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "bug"),
        ]
        return components.url
    }

    // MARK: - Body

    /// Build a short body for the URL (stays under GitHub's URL length limit).
    private static func buildURLBody(errorMessage: String?) -> String {
        var sections: [String] = []

        // Error message (if reporting from an error screen).
        if let errorMessage, !errorMessage.isEmpty {
            sections.append(
                """
                **Error:**
                > \(errorMessage)
                """)
        }

        // What happened (user fills in).
        sections.append(
            """
            **What happened:**
            <!-- Describe what you were doing and what went wrong. -->

            """)

        // System info (compact, always fits).
        sections.append(
            """
            **System info:**
            ```
            \(systemInfo())
            ```
            """)

        // Prompt to paste full diagnostics from clipboard.
        sections.append(
            """
            **Diagnostics:**
            <!-- Full diagnostics have been copied to your clipboard. Paste (⌘V) below this line. -->

            """)

        return sections.joined(separator: "\n\n")
    }

    /// Build the full diagnostics string for the clipboard.
    private static func buildFullDiagnostics(
        errorMessage: String?,
        micDiagnostics: String?
    ) -> String {
        var sections: [String] = []

        sections.append("**System info:**")
        sections.append("```\n\(systemInfo())\n```")

        // Recent log history.
        let history = Log.formattedHistory()
        if history != "No log entries recorded." {
            sections.append(
                """
                <details>
                <summary>Recent log (\(Log.entryCount) entries)</summary>

                ```
                \(history)
                ```
                </details>
                """)
        }

        // Mic diagnostics (if available).
        if let micDiagnostics, micDiagnostics != "No dictation sessions recorded yet." {
            sections.append(
                """
                <details>
                <summary>Mic diagnostics</summary>

                ```
                \(micDiagnostics)
                ```
                </details>
                """)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - System Info

    /// Collect system information as a compact multi-line string.
    public static func systemInfo() -> String {
        let appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        let buildNumber =
            Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "unknown"
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let model = macModelIdentifier()
        let memory = ProcessInfo.processInfo.physicalMemory
        let memoryGB = String(format: "%.0f", Double(memory) / 1_073_741_824)
        let uptime = formatUptime(ProcessInfo.processInfo.systemUptime)

        return [
            "FreeFlow: \(appVersion) (\(buildNumber))",
            "macOS: \(macOS)",
            "Mac: \(model)",
            "Memory: \(memoryGB) GB",
            "Uptime: \(uptime)",
        ].joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private static func macModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
