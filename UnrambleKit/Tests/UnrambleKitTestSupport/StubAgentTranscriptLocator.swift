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

    public func latestResponse(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptResponse? {
        try lock.withLock {
            _requestedWorkingDirectories.append(processWorkingDirectory)
            if _throwsError { throw StubError() }
            return _stubbedResponse
        }
    }
}
