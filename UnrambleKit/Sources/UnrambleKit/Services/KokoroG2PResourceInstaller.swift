import Foundation

/// Install packed English G2P resources where the Kokoro text processor
/// resolves them, so phonemization never downloads at runtime.
///
/// The pinned mlx-audio-swift revision resolves `MisakiTextProcessor`
/// resources from `<hub cache>/mlx-audio/beshkenadze_kitten-tts-g2p/` and
/// treats the directory as complete only when it holds a non-empty
/// `.safetensors` file and a parseable `config.json`. The G2P repository
/// itself carries no `config.json` (its loaders read `us_bart_config.json`),
/// so the installer writes an empty JSON stub to satisfy the completeness
/// check. Copies come from the app's verified model pack; nothing here
/// touches the network.
enum KokoroG2PResourceInstaller {

    static let cacheSubpath = "mlx-audio/beshkenadze_kitten-tts-g2p"

    /// Copy G2P resource files from the model pack into the hub cache
    /// location. Existing files with matching sizes are left in place, so
    /// repeat launches are cheap.
    static func install(
        from sourceDirectory: URL,
        intoHubCacheDirectory hubCacheDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let target = hubCacheDirectory.appendingPathComponent(cacheSubpath)
        try fileManager.createDirectory(
            at: target, withIntermediateDirectories: true)

        let sources = try fileManager.contentsOfDirectory(
            at: sourceDirectory, includingPropertiesForKeys: [.fileSizeKey])
        for source in sources where source.hasDirectoryPath == false {
            let destination = target.appendingPathComponent(
                source.lastPathComponent)
            if fileSize(of: destination) == fileSize(of: source) {
                continue
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
        }

        let configStub = target.appendingPathComponent("config.json")
        if !fileManager.fileExists(atPath: configStub.path) {
            try Data("{}".utf8).write(to: configStub)
        }
    }

    private static func fileSize(of url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize
    }
}
