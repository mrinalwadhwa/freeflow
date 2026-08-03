import Foundation
import Testing

@testable import UnrambleKit

@Suite("Transcript file helpers")
struct TranscriptFilesTests {

    @Test("Path lineage matches in both directions")
    func lineageMatchesBothDirections() {
        #expect(TranscriptFiles.pathsShareLineage("/a/b", "/a/b"))
        #expect(TranscriptFiles.pathsShareLineage("/a/b/c", "/a/b"))
        #expect(TranscriptFiles.pathsShareLineage("/a/b", "/a/b/c"))
    }

    @Test("A sibling path sharing a name prefix does not match")
    func siblingPrefixDoesNotMatch() {
        #expect(
            !TranscriptFiles.pathsShareLineage(
                "/Users/dev/pro", "/Users/dev/project"))
        #expect(
            !TranscriptFiles.pathsShareLineage(
                "/Users/dev/project", "/Users/dev/pro"))
    }

    @Test("Tail reading a large file drops the partial first line")
    func tailReadDropsPartialFirstLine() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("unramble-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = (0..<100).map { "line-\($0)-" + String(repeating: "x", count: 100) }
        try lines.joined(separator: "\n").write(
            to: file, atomically: true, encoding: .utf8)

        let tail = TranscriptFiles.tailLines(of: file, maximumBytes: 500)

        #expect(!tail.isEmpty)
        #expect(tail.last == lines.last)
        #expect(tail.allSatisfy { $0.hasPrefix("line-") })
    }

    @Test("Tail reading a small file returns every line")
    func tailReadReturnsWholeSmallFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("unramble-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try "one\ntwo\nthree".write(to: file, atomically: true, encoding: .utf8)

        #expect(
            TranscriptFiles.tailLines(of: file, maximumBytes: 1_000)
                == ["one", "two", "three"])
    }
}
