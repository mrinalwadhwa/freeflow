import Foundation
import UnrambleKit

/// Stub transcript locator that returns a fixed response or error.
public final class StubAgentTranscriptLocator: AgentTranscriptLocating,
    @unchecked Sendable
{

    public struct StubError: Error {
        public init() {}
    }

    public let agentName: String
    public let processNames: Set<String>

    private let lock = NSLock()
    private var _stubbedResponse: AgentTranscriptResponse?
    private var _throwsError = false
    private var _requestedWorkingDirectories: [String] = []

    public init(
        agentName: String,
        processNames: Set<String>,
        stubbedResponse: AgentTranscriptResponse? = nil
    ) {
        self.agentName = agentName
        self.processNames = processNames
        _stubbedResponse = stubbedResponse
    }

    public var stubbedResponse: AgentTranscriptResponse? {
        get { lock.withLock { _stubbedResponse } }
        set { lock.withLock { _stubbedResponse = newValue } }
    }

    public var throwsError: Bool {
        get { lock.withLock { _throwsError } }
        set { lock.withLock { _throwsError = newValue } }
    }

    public var requestedWorkingDirectories: [String] {
        lock.withLock { _requestedWorkingDirectories }
    }

    /// The session file `sessionFile(forProcessWorkingDirectory:)`
    /// returns.
    public var stubbedSessionFile: URL? {
        get { lock.withLock { _stubbedSessionFile } }
        set { lock.withLock { _stubbedSessionFile = newValue } }
    }
    private var _stubbedSessionFile: URL?

    /// The edge `transcriptEdge(of:forProcessWorkingDirectory:)`
    /// returns; nil answers with an empty edge.
    public var stubbedEdge: AgentTranscriptEdge? {
        get { lock.withLock { _stubbedEdge } }
        set { lock.withLock { _stubbedEdge = newValue } }
    }
    private var _stubbedEdge: AgentTranscriptEdge?

    public func latestResponse(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptResponse? {
        try lock.withLock {
            _requestedWorkingDirectories.append(processWorkingDirectory)
            if _throwsError { throw StubError() }
            return _stubbedResponse
        }
    }

    public func sessionFile(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> URL? {
        try lock.withLock {
            if _throwsError { throw StubError() }
            return _stubbedSessionFile
        }
    }

    public func transcriptEdge(
        of file: URL,
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptEdge {
        try lock.withLock {
            if _throwsError { throw StubError() }
            return _stubbedEdge
                ?? AgentTranscriptEdge(
                    endsWithAssistantText: false,
                    latestResponse: nil)
        }
    }
}
