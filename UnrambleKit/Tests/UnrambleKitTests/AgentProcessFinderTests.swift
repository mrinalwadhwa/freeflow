import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Agent process finder")
struct AgentProcessFinderTests {

    @Test("Finds an agent through a deep descendant chain")
    func findsAgentThroughDeepChain() {
        let table = FakeProcessTable(
            records: [
                .init(pid: 100, parentPid: 1, name: "Terminal"),
                .init(pid: 200, parentPid: 100, name: "termserver"),
                .init(pid: 300, parentPid: 200, name: "login"),
                .init(pid: 400, parentPid: 300, name: "zsh"),
                .init(pid: 500, parentPid: 400, name: "claude"),
            ],
            workingDirectories: [500: "/Users/dev/project"])
        let finder = AgentProcessFinder(processTable: table)
        let agents = finder.findAgents(under: 100, matching: ["claude"])
        #expect(agents == [
            AgentProcess(
                name: "claude",
                pid: 500,
                workingDirectory: "/Users/dev/project")
        ])
    }

    @Test("Finds several agents under one root")
    func findsSeveralAgents() {
        let table = FakeProcessTable(
            records: [
                .init(pid: 100, parentPid: 1, name: "Terminal"),
                .init(pid: 201, parentPid: 100, name: "zsh"),
                .init(pid: 202, parentPid: 100, name: "zsh"),
                .init(pid: 301, parentPid: 201, name: "claude"),
                .init(pid: 302, parentPid: 202, name: "codex"),
            ],
            workingDirectories: [301: "/one", 302: "/two"])
        let finder = AgentProcessFinder(processTable: table)
        let agents = finder.findAgents(
            under: 100, matching: ["claude", "codex"])
        #expect(agents.count == 2)
        #expect(Set(agents.map(\.workingDirectory)) == ["/one", "/two"])
    }

    @Test("Ignores agents outside the root's descendant tree")
    func ignoresAgentsOutsideTree() {
        let table = FakeProcessTable(
            records: [
                .init(pid: 100, parentPid: 1, name: "Terminal"),
                .init(pid: 999, parentPid: 1, name: "claude"),
            ],
            workingDirectories: [999: "/elsewhere"])
        let finder = AgentProcessFinder(processTable: table)
        #expect(finder.findAgents(under: 100, matching: ["claude"]).isEmpty)
    }

    @Test("Drops a match without a readable working directory")
    func dropsMatchWithoutWorkingDirectory() {
        let table = FakeProcessTable(
            records: [
                .init(pid: 100, parentPid: 1, name: "Terminal"),
                .init(pid: 200, parentPid: 100, name: "claude"),
            ],
            workingDirectories: [:])
        let finder = AgentProcessFinder(processTable: table)
        #expect(finder.findAgents(under: 100, matching: ["claude"]).isEmpty)
    }

    @Test("A cyclic parent link cannot loop the walk")
    func cyclicParentLinksTerminate() {
        let table = FakeProcessTable(
            records: [
                .init(pid: 100, parentPid: 200, name: "one"),
                .init(pid: 200, parentPid: 100, name: "two"),
                .init(pid: 300, parentPid: 200, name: "claude"),
            ],
            workingDirectories: [300: "/loop"])
        let finder = AgentProcessFinder(processTable: table)
        let agents = finder.findAgents(under: 100, matching: ["claude"])
        #expect(agents.map(\.pid) == [300])
    }
}
