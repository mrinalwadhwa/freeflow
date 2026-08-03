import Foundation

/// A coding-agent process found beneath an application process.
public struct AgentProcess: Sendable, Equatable {
    public let name: String
    public let pid: Int32
    public let workingDirectory: String

    /// The device number of the agent's controlling terminal, when it has
    /// one. Correlates the agent with a specific terminal pane.
    public let ttyDevice: Int32?

    public init(
        name: String,
        pid: Int32,
        workingDirectory: String,
        ttyDevice: Int32? = nil
    ) {
        self.name = name
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.ttyDevice = ttyDevice
    }
}

/// Finds coding-agent processes in the descendant tree of an application.
///
/// Walks the process table from the application's pid through arbitrary
/// depth, so agents behind shells, login wrappers, terminal server
/// daemons, and IDE integrated terminals are all reachable.
public struct AgentProcessFinder: Sendable {

    private let processTable: any ProcessTableProviding

    public init(processTable: any ProcessTableProviding) {
        self.processTable = processTable
    }

    /// Return every process named in `names` that descends from `rootPid`,
    /// with its working directory. Matches without a readable working
    /// directory are dropped.
    public func findAgents(
        under rootPid: Int32,
        matching names: Set<String>
    ) -> [AgentProcess] {
        let records = processTable.snapshot()
        var childrenByParent: [Int32: [ProcessTableRecord]] = [:]
        for record in records {
            childrenByParent[record.parentPid, default: []].append(record)
        }

        var agents: [AgentProcess] = []
        var queue: [Int32] = [rootPid]
        var visited: Set<Int32> = [rootPid]
        while let pid = queue.popLast() {
            for child in childrenByParent[pid] ?? [] {
                guard visited.insert(child.pid).inserted else { continue }
                queue.append(child.pid)
                guard names.contains(child.name) else { continue }
                guard
                    let workingDirectory =
                        processTable.currentWorkingDirectory(of: child.pid)
                else { continue }
                agents.append(
                    AgentProcess(
                        name: child.name,
                        pid: child.pid,
                        workingDirectory: workingDirectory,
                        ttyDevice: child.ttyDevice))
            }
        }
        return agents
    }
}
