import Foundation
import Testing

@testable import UnrambleKit

@Suite("Libproc process table")
struct LibprocProcessTableTests {

    @Test("The snapshot contains the current process with its parent")
    func snapshotContainsCurrentProcess() {
        let table = LibprocProcessTable()
        let snapshot = table.snapshot()
        let current = snapshot.first {
            $0.pid == ProcessInfo.processInfo.processIdentifier
        }
        #expect(current != nil)
        #expect(current?.parentPid == getppid())
        #expect(current?.name.isEmpty == false)
    }

    @Test("The snapshot links the current process's full ancestry to launchd")
    func snapshotLinksAncestryToLaunchd() {
        // The ancestry from any process to pid 1 crosses processes owned
        // by root (launchd; under a terminal also the setuid login
        // wrapper). Every link must be present, or the agent finder's
        // descendant walk from a terminal would sever mid-chain.
        let table = LibprocProcessTable()
        let snapshot = table.snapshot()
        var recordsByPid: [Int32: ProcessTableRecord] = [:]
        for record in snapshot {
            recordsByPid[record.pid] = record
        }

        var pid = ProcessInfo.processInfo.processIdentifier
        var hops = 0
        while pid != 1 {
            let record = recordsByPid[pid]
            #expect(record != nil, "missing snapshot record for pid \(pid)")
            guard let record else { return }
            pid = record.parentPid
            hops += 1
            #expect(hops < 64)
            guard hops < 64 else { return }
        }
        #expect(recordsByPid[1]?.name.isEmpty == false)
    }

    @Test("The current process's working directory is readable")
    func currentWorkingDirectoryIsReadable() {
        let table = LibprocProcessTable()
        let workingDirectory = table.currentWorkingDirectory(
            of: ProcessInfo.processInfo.processIdentifier)
        #expect(workingDirectory != nil)
        if let workingDirectory {
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(
                atPath: workingDirectory, isDirectory: &isDirectory)
            #expect(exists)
            #expect(isDirectory.boolValue)
        }
    }

    @Test("An unknown pid yields no working directory")
    func unknownPidYieldsNil() {
        let table = LibprocProcessTable()
        #expect(table.currentWorkingDirectory(of: -1) == nil)
    }
}
