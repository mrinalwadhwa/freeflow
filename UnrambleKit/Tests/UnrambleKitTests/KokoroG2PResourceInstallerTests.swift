import Foundation
import Testing

@testable import UnrambleKit

@Suite("Kokoro G2P resource installer")
struct KokoroG2PResourceInstallerTests {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-g2p-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Installs resources and a config stub into the cache layout")
    func installsResourcesAndStub() throws {
        let source = try makeTempDirectory()
        let cache = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cache)
        }
        try Data("gold".utf8).write(
            to: source.appendingPathComponent("us_gold.json"))
        try Data("weights".utf8).write(
            to: source.appendingPathComponent("us_bart.safetensors"))

        try KokoroG2PResourceInstaller.install(
            from: source, intoHubCacheDirectory: cache)

        let target = cache.appendingPathComponent(
            KokoroG2PResourceInstaller.cacheSubpath)
        #expect(
            try Data(
                contentsOf: target.appendingPathComponent("us_gold.json"))
                == Data("gold".utf8))
        #expect(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("us_bart.safetensors")
                    .path))
        let stub = try Data(
            contentsOf: target.appendingPathComponent("config.json"))
        #expect(
            try JSONSerialization.jsonObject(with: stub) is [String: Any])
    }

    @Test("Reinstalling leaves existing files and the stub in place")
    func reinstallIsIdempotent() throws {
        let source = try makeTempDirectory()
        let cache = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cache)
        }
        try Data("gold".utf8).write(
            to: source.appendingPathComponent("us_gold.json"))

        try KokoroG2PResourceInstaller.install(
            from: source, intoHubCacheDirectory: cache)
        let target = cache.appendingPathComponent(
            KokoroG2PResourceInstaller.cacheSubpath)
        try Data("edited".utf8).write(
            to: target.appendingPathComponent("config.json"))

        try KokoroG2PResourceInstaller.install(
            from: source, intoHubCacheDirectory: cache)

        #expect(
            try Data(
                contentsOf: target.appendingPathComponent("config.json"))
                == Data("edited".utf8))
    }

    @Test("A changed source file replaces the cached copy")
    func changedSourceReplacesCopy() throws {
        let source = try makeTempDirectory()
        let cache = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cache)
        }
        let goldSource = source.appendingPathComponent("us_gold.json")
        try Data("v1".utf8).write(to: goldSource)
        try KokoroG2PResourceInstaller.install(
            from: source, intoHubCacheDirectory: cache)

        try Data("v2-longer".utf8).write(to: goldSource)
        try KokoroG2PResourceInstaller.install(
            from: source, intoHubCacheDirectory: cache)

        let target = cache.appendingPathComponent(
            KokoroG2PResourceInstaller.cacheSubpath)
        #expect(
            try Data(
                contentsOf: target.appendingPathComponent("us_gold.json"))
                == Data("v2-longer".utf8))
    }
}
