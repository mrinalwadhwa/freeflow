import Foundation
import Testing

@testable import UnrambleKit

@Suite("VoiceProcessedInputTransport")
struct VoiceProcessedInputTransportTests {

    @Test("Builds against the current capture device")
    func buildsAgainstCurrentDevice() async throws {
        let provider = CoreAudioDeviceProvider()
        let devices = await provider.availableDevices()

        // Headless machines and VMs may have no input devices.
        guard let current = await provider.currentDevice(),
            !devices.isEmpty
        else { return }

        Log.debug(
            "[VoiceProcessedCapture] test device "
                + "id=\(current.id) name=\(current.name)")
        let transport = try VoiceProcessedInputTransport(deviceID: current.id)
        #expect(transport.deviceID == current.id)
        #expect(transport.format.sampleRate > 0)
        #expect(transport.format.channelCount >= 1)
    }

    @Test("An invalid device fails to build")
    func invalidDeviceThrows() {
        #expect(throws: (any Error).self) {
            _ = try VoiceProcessedInputTransport(deviceID: 999_999)
        }
    }

    @Test("Stop before start is safe")
    func stopBeforeStart() async throws {
        let provider = CoreAudioDeviceProvider()
        guard let current = await provider.currentDevice() else { return }

        let transport = try VoiceProcessedInputTransport(deviceID: current.id)
        transport.stop()
        transport.stop()
    }
}
