import Foundation

/// Watch a coding-agent session's transcript for the response to a
/// sent turn.
///
/// The watch stats the session file cheaply on every poll and parses
/// its edge only when the file has been still for the quiescence
/// window. A still transcript whose newest record is assistant text
/// fresher than the watch delivers the response; stillness past the
/// extended window with no such text is a tool-only outcome, which
/// also covers dead or unreadable transcripts and turns that landed
/// elsewhere. Every observed change without a resolution emits a
/// throttled still-working notice, so a long tool-heavy turn keeps
/// the call visibly alive without ever narrating. Freshness is judged
/// by record timestamps against the arm time — the sent turn's own
/// transcript record resets stillness the moment it lands, so the
/// previous response is never re-spoken.
public actor TranscriptResponseWatcher: ResponseWatching {

    private struct FileFingerprint: Equatable {
        let size: UInt64
        let modified: Date
    }

    private let locators: [any AgentTranscriptLocating]
    private let quiescenceWindow: TimeInterval
    private let extendedWindow: TimeInterval
    private let pollInterval: TimeInterval
    private let interimParseInterval: TimeInterval
    private let activityNoticeInterval: TimeInterval
    private let narratesInterimMessages: @Sendable () -> Bool

    private var watchTask: Task<Void, Never>?

    /// The extended window bounds only a completely still transcript.
    /// An agent composing a long reply writes nothing for stretches of
    /// a minute or more, and the call's microphone stays open through
    /// the whole wait, so patience here costs nothing — while an
    /// early tool-only resolution silently killed the narration of
    /// every slow response.
    public init(
        locators: [any AgentTranscriptLocating] = [
            ClaudeCodeTranscriptLocator(),
            CodexTranscriptLocator(),
        ],
        quiescenceWindow: TimeInterval = 1.5,
        extendedWindow: TimeInterval = 600,
        pollInterval: TimeInterval = 0.25,
        interimParseInterval: TimeInterval = 1.0,
        activityNoticeInterval: TimeInterval = 5.0,
        narratesInterimMessages: @escaping @Sendable () -> Bool = { true }
    ) {
        self.locators = locators
        self.quiescenceWindow = quiescenceWindow
        self.extendedWindow = extendedWindow
        self.pollInterval = pollInterval
        self.interimParseInterval = interimParseInterval
        self.activityNoticeInterval = activityNoticeInterval
        self.narratesInterimMessages = narratesInterimMessages
    }

    public func arm(
        session: ResolvedAgentSession,
        anchor: String
    ) async -> AsyncStream<ResponseWatchEvent> {
        watchTask?.cancel()
        let (stream, continuation) =
            AsyncStream<ResponseWatchEvent>.makeStream()

        guard let locator = locator(for: session) else {
            // No locator understands this agent, so completion can
            // never be observed; resolve as tool-only rather than
            // leaving the call waiting forever.
            continuation.yield(.toolOnly)
            continuation.finish()
            return stream
        }

        let quiescenceWindow = quiescenceWindow
        let extendedWindow = extendedWindow
        let pollInterval = pollInterval
        let interimParseInterval = interimParseInterval
        let activityNoticeInterval = activityNoticeInterval
        let narrationEnabled = narratesInterimMessages()
        watchTask = Task {
            defer { continuation.finish() }
            await Self.runWatch(
                session: session,
                locator: locator,
                quiescenceWindow: quiescenceWindow,
                extendedWindow: extendedWindow,
                pollInterval: pollInterval,
                interimParseInterval: interimParseInterval,
                activityNoticeInterval: activityNoticeInterval,
                narrationEnabled: narrationEnabled,
                continuation: continuation)
        }
        return stream
    }

    public func cancelWatch() async {
        watchTask?.cancel()
        watchTask = nil
    }

    private func locator(
        for session: ResolvedAgentSession
    ) -> (any AgentTranscriptLocating)? {
        locators.first {
            $0.agentName == session.agentName
                || $0.processNames.contains(session.agentName)
        }
    }

    private static func runWatch(
        session: ResolvedAgentSession,
        locator: any AgentTranscriptLocating,
        quiescenceWindow: TimeInterval,
        extendedWindow: TimeInterval,
        pollInterval: TimeInterval,
        interimParseInterval: TimeInterval,
        activityNoticeInterval: TimeInterval,
        narrationEnabled: Bool,
        continuation: AsyncStream<ResponseWatchEvent>.Continuation
    ) async {
        let armDate = Date()
        var sessionFile: URL?
        var lastFingerprint: FileFingerprint?
        var parsedFingerprint: FileFingerprint?
        var interimParsedFingerprint: FileFingerprint?
        var lastInterimParse = Date.distantPast
        var lastActivityNotice = Date.distantPast
        var narrated: Set<String> = []
        var stillSince = Date()

        while !Task.isCancelled {
            if sessionFile == nil {
                sessionFile =
                    (try? locator.sessionFile(
                        forProcessWorkingDirectory: session.workingDirectory))
                    ?? nil
            }
            let fingerprint = sessionFile.flatMap(Self.fingerprint(of:))
            if fingerprint != lastFingerprint {
                // Discovering the file is not activity; only a change
                // to an already-observed transcript is the agent
                // visibly at work. The throttled notice holds the
                // call's idle window open without narrating anything.
                if lastFingerprint != nil,
                    Date().timeIntervalSince(lastActivityNotice)
                        >= activityNoticeInterval
                {
                    lastActivityNotice = Date()
                    continuation.yield(.stillWorking)
                }
                lastFingerprint = fingerprint
                stillSince = Date()
            }

            // Narrate fresh mostly-prose messages as they arrive,
            // throttled so a fast-changing transcript is not re-parsed
            // on every poll. Only the latest message is visible per
            // parse; one that lives shorter than the parse interval
            // between two others can be missed.
            if narrationEnabled,
                let sessionFile,
                let fingerprint,
                fingerprint != interimParsedFingerprint,
                Date().timeIntervalSince(lastInterimParse)
                    >= interimParseInterval
            {
                interimParsedFingerprint = fingerprint
                lastInterimParse = Date()
                if let edge = try? locator.transcriptEdge(
                    of: sessionFile,
                    forProcessWorkingDirectory: session.workingDirectory),
                    let response = edge.latestResponse,
                    response.timestamp > armDate,
                    !narrated.contains(response.markdown),
                    Self.isMostlyProse(response.markdown)
                {
                    narrated.insert(response.markdown)
                    continuation.yield(
                        .interimMessage(markdown: response.markdown))
                }
            }

            let still = Date().timeIntervalSince(stillSince)
            if still >= quiescenceWindow,
                let stillFile = sessionFile,
                let fingerprint,
                fingerprint != parsedFingerprint
            {
                // Parse at most once per fingerprint: a still file
                // cannot change its edge, and any change resets
                // stillness anyway.
                parsedFingerprint = fingerprint
                if let edge = try? locator.transcriptEdge(
                    of: stillFile,
                    forProcessWorkingDirectory: session.workingDirectory),
                    edge.endsWithAssistantText,
                    let response = edge.latestResponse,
                    response.timestamp > armDate
                {
                    if narrated.contains(response.markdown) {
                        continuation.yield(
                            .completed(markdown: response.markdown))
                    } else {
                        continuation.yield(
                            .response(markdown: response.markdown))
                    }
                    return
                }
                // Nothing fresh at this edge: drop the cached file so
                // the next poll re-resolves. A newer session file —
                // created after the watch armed — then takes over
                // instead of the watch pinning to a stale transcript.
                sessionFile = nil
            }
            if still >= extendedWindow {
                continuation.yield(.toolOnly)
                return
            }

            try? await Task.sleep(
                nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Whether a message is mostly prose: code makes up less than the
    /// maximum fraction of its text. Code-heavy interim messages are
    /// skipped; a code-heavy final response still speaks through the
    /// script builder, which compresses code blocks.
    static func isMostlyProse(
        _ markdown: String,
        maximumCodeFraction: Double = 0.4
    ) -> Bool {
        let segments = MarkdownSegmenter.segments(from: markdown)
        let codeLength = segments.filter { $0.kind == .code }
            .reduce(0) { $0 + $1.text.count }
        let totalLength = segments.reduce(0) { $0 + $1.text.count }
        guard totalLength > 0 else { return false }
        return Double(codeLength) / Double(totalLength) < maximumCodeFraction
    }

    private static func fingerprint(of file: URL) -> FileFingerprint? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: file.path)
        else { return nil }
        return FileFingerprint(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast)
    }
}
