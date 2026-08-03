import Foundation

#if canImport(AVFoundation) && canImport(CoreAudio)
    import AVFoundation
    import CoreAudio

    /// Captures one concrete Core Audio input without following changes to the
    /// system-default device. The timestamp router and dictation sink remain the
    /// same as the AVAudioEngine provider; only the physical transport differs.
    public final class AUHALAudioCaptureProvider: AudioProviding,
        @unchecked Sendable
    {
        typealias TransportFactory = @Sendable (AudioObjectID) throws ->
            any AUHALInputTransporting

        private struct PhysicalCapture {
            let id: UUID
            let deviceID: AudioObjectID
            let transport: any AUHALInputTransporting
            let router: TimestampedAudioFrameRouter
        }

        private struct DictationCapture {
            let owner: AudioCaptureOwner
            let sink: DictationAudioSink
            let sinkToken: DictationAudioSinkPublication.Token
            let route: TimestampedAudioFrameRouter.Route
            let playsSoundFeedback: Bool
        }

        private struct PreviewCapture {
            let owner: AudioCaptureOwner
            let stream: AsyncStream<Float>
            let continuation: AsyncStream<Float>.Continuation
        }

        private struct StopEntry {
            let id: UUID
            let task: Task<AudioBuffer, any Error>
        }

        private struct StopFinalization: Sendable {
            let completion: DictationAudioSink.Completion
            let metrics: AudioCaptureMetrics
        }

        private let lock = NSLock()
        private let transitions = AsyncSerialOperationQueue()
        private let demands = AudioCaptureDemandLedger()
        private let makeTransport: TransportFactory
        private let sinkPublication = DictationAudioSinkPublication()
        private let pcmStreamSnapshot = AudioCapturePCMStreamSnapshot()

        private weak var audioDeviceProvider:
            (any AudioInputDeviceSnapshotProviding)?
        private var soundFeedbackProvider: SoundFeedbackProvider?
        private var physical: PhysicalCapture?
        private var dictation: DictationCapture?
        private var preview: PreviewCapture?
        private var legacyOwner: AudioCaptureOwner?
        private var retainedMetrics: AudioCaptureMetrics?
        private var metricsOwner: AudioCaptureOwner?
        private var stopEntries: [AudioCaptureOwner: StopEntry] = [:]
        private var isShutdown = false

        public init() {
            makeTransport = { try AUHALDirectInputTransport(deviceID: $0) }
        }

        init(makeTransport: @escaping TransportFactory) {
            self.makeTransport = makeTransport
        }

        deinit {
            let transport = lock.withLock { physical?.transport }
            transport?.stop()
        }

        public func setAudioDeviceProvider(
            _ provider: any AudioInputDeviceSnapshotProviding
        ) {
            lock.withLock { audioDeviceProvider = provider }
        }

        public func setSoundFeedbackProvider(
            _ provider: SoundFeedbackProvider?
        ) {
            lock.withLock { soundFeedbackProvider = provider }
        }

        public var isRecording: Bool {
            lock.withLock { physical != nil }
        }

        public func isRecording(owner: AudioCaptureOwner) -> Bool {
            lock.withLock {
                dictation?.owner == owner || preview?.owner == owner
            }
        }

        public var pcmAudioStream: AsyncStream<Data>? {
            pcmStreamSnapshot.current
        }

        public func pcmAudioStream(
            owner: AudioCaptureOwner
        ) -> AsyncStream<Data>? {
            lock.withLock {
                guard dictation?.owner == owner else { return nil }
                return dictation?.sink.pcmStream
            }
        }

        public var audioLevelStream: AsyncStream<Float>? {
            lock.withLock {
                if let legacyOwner, dictation?.owner == legacyOwner {
                    return dictation?.sink.levelStream
                }
                return preview?.stream
            }
        }

        public func audioLevelStream(
            owner: AudioCaptureOwner
        ) -> AsyncStream<Float>? {
            lock.withLock {
                if preview?.owner == owner { return preview?.stream }
                guard dictation?.owner == owner else { return nil }
                return dictation?.sink.levelStream
            }
        }

        public func metrics(
            owner: AudioCaptureOwner
        ) -> AudioCaptureMetrics? {
            lock.withLock {
                guard metricsOwner == owner else { return nil }
                return dictation?.owner == owner
                    ? dictation?.sink.metrics
                    : retainedMetrics
            }
        }

        public var peakRMS: Float { currentMetrics?.peakRMS ?? 0 }
        public var ambientRMS: Float { currentMetrics?.ambientRMS ?? 0 }
        public var micProximity: MicProximity {
            currentMetrics?.micProximity ?? currentDeviceMetadata.proximity
        }
        public var gainFactor: Float { currentMetrics?.gainFactor ?? 1 }
        public var deviceName: String {
            currentMetrics?.deviceName ?? currentDeviceMetadata.name
        }

        private var currentMetrics: AudioCaptureMetrics? {
            lock.withLock { dictation?.sink.metrics ?? retainedMetrics }
        }

        private var currentDeviceMetadata: (
            proximity: MicProximity,
            name: String
        ) {
            lock.withLock {
                let id = physical?.deviceID
                return (
                    audioDeviceProvider?.micProximityForDevice(id) ?? .nearField,
                    audioDeviceProvider?.deviceNameForDevice(id)
                        ?? "System Default")
            }
        }

        public func startRecording() async throws {
            try await startRecording(onCaptureReady: {})
        }

        public func startRecording(
            onCaptureReady: @escaping @Sendable () -> Void
        ) async throws {
            let owner = AudioCaptureOwner.preview()
            lock.withLock { legacyOwner = owner }
            do {
                try await startRecording(
                    owner: owner,
                    configuration: .dictation,
                    releaseBoundary: nil,
                    onCaptureReady: onCaptureReady)
            } catch {
                lock.withLock {
                    if legacyOwner == owner { legacyOwner = nil }
                }
                throw error
            }
        }

        public func startRecording(
            releaseBoundary: AudioCaptureReleaseBoundary,
            onCaptureReady: @escaping @Sendable () -> Void
        ) async throws {
            let owner = AudioCaptureOwner.preview()
            lock.withLock { legacyOwner = owner }
            do {
                try await startRecording(
                    owner: owner,
                    configuration: .dictation,
                    releaseBoundary: releaseBoundary,
                    onCaptureReady: onCaptureReady)
            } catch {
                lock.withLock {
                    if legacyOwner == owner { legacyOwner = nil }
                }
                throw error
            }
        }

        public func startRecording(
            owner: AudioCaptureOwner,
            configuration: AudioCaptureConfiguration,
            releaseBoundary: AudioCaptureReleaseBoundary?,
            onCaptureReady: @escaping @Sendable () -> Void
        ) async throws {
            let provider = lock.withLock { audioDeviceProvider }
            try await provider?.waitUntilInputDeviceSettled()
            try Task.checkCancellation()
            guard demands.insert(owner) else {
                throw AudioCaptureError.alreadyRecording
            }
            do {
                try await transitions.run { [self] in
                    try Task.checkCancellation()
                    guard demands.contains(owner) else {
                        throw CancellationError()
                    }
                    try startSerialized(
                        owner: owner,
                        configuration: configuration,
                        releaseBoundary: releaseBoundary,
                        onCaptureReady: onCaptureReady)
                }
            } catch {
                _ = demands.remove(owner)
                throw error
            }
        }

        private func startSerialized(
            owner: AudioCaptureOwner,
            configuration: AudioCaptureConfiguration,
            releaseBoundary: AudioCaptureReleaseBoundary?,
            onCaptureReady: @escaping @Sendable () -> Void
        ) throws {
            if lock.withLock({ physical != nil }) {
                try attach(
                    owner: owner,
                    configuration: configuration,
                    releaseBoundary: releaseBoundary,
                    onCaptureReady: onCaptureReady)
                return
            }

            let provider = lock.withLock { audioDeviceProvider }
            guard let deviceID = provider?.captureDeviceID else {
                throw AudioCaptureError.noInputDevice
            }
            let transport = try makeTransport(deviceID)
            let metadata = (
                provider?.micProximityForDevice(deviceID) ?? .nearField,
                provider?.deviceNameForDevice(deviceID) ?? "System Default")
            let router = TimestampedAudioFrameRouter(
                makeDictationSink: { [sinkPublication] in
                    try sinkPublication.makeRouterSink()
                })

            var newDictation: DictationCapture?
            var newPreview: PreviewCapture?
            if configuration.retainsPCM {
                let sink = try DictationAudioSink(
                    inputFormat: transport.format,
                    micProximity: metadata.0,
                    deviceName: metadata.1)
                let sinkToken = sinkPublication.publish(sink)
                do {
                    router.markContinuousCaptureStarted(
                        atHostTime: AudioCaptureReleaseFence.currentHostTime())
                    let route = try router.promote(
                        releaseBoundary: releaseBoundary
                            ?? AudioCaptureReleaseBoundary())
                    newDictation = DictationCapture(
                        owner: owner,
                        sink: sink,
                        sinkToken: sinkToken,
                        route: route,
                        playsSoundFeedback: shouldPlaySoundFeedback(
                            requested: configuration.playsSoundFeedback))
                } catch {
                    _ = sinkPublication.clear(sinkToken)
                    sink.discard()
                    throw promotionError(error)
                }
            } else {
                let pair = AsyncStream<Float>.makeStream(
                    bufferingPolicy: .bufferingNewest(1))
                newPreview = PreviewCapture(
                    owner: owner,
                    stream: pair.stream,
                    continuation: pair.continuation)
            }

            do {
                try transport.start { [weak self, router] buffer, timestamp in
                    self?.process(
                        buffer,
                        timestamp: timestamp,
                        router: router)
                }
            } catch {
                newPreview?.continuation.finish()
                if let newDictation {
                    _ = sinkPublication.clear(newDictation.sinkToken)
                    newDictation.sink.discard()
                }
                throw AudioCaptureError.engineStartFailed(String(describing: error))
            }
            router.markContinuousCaptureStarted(
                atHostTime: AudioCaptureReleaseFence.currentHostTime())

            let published = lock.withLock { () -> Bool in
                guard !isShutdown, physical == nil, demands.contains(owner) else {
                    return false
                }
                physical = PhysicalCapture(
                    id: UUID(),
                    deviceID: deviceID,
                    transport: transport,
                    router: router)
                dictation = newDictation
                preview = newPreview
                if let newDictation {
                    retainedMetrics = nil
                    metricsOwner = owner
                    pcmStreamSnapshot.publish(newDictation.sink.pcmStream)
                }
                onCaptureReady()
                return true
            }
            guard published else {
                transport.stop()
                router.reset()
                newPreview?.continuation.finish()
                if let newDictation {
                    _ = sinkPublication.clear(newDictation.sinkToken)
                    newDictation.sink.discard()
                }
                throw CancellationError()
            }
            if newDictation?.playsSoundFeedback == true {
                lock.withLock { soundFeedbackProvider }?.playStartSound()
            }
            Log.debug(
                "[AUHALCapture] Started device=\(deviceID) "
                    + "sampleRate=\(transport.format.sampleRate) "
                    + "channels=\(transport.format.channelCount)")
        }

        private func attach(
            owner: AudioCaptureOwner,
            configuration: AudioCaptureConfiguration,
            releaseBoundary: AudioCaptureReleaseBoundary?,
            onCaptureReady: @escaping @Sendable () -> Void
        ) throws {
            let shouldPlay = shouldPlaySoundFeedback(
                requested: configuration.playsSoundFeedback)
            try lock.withLock {
                guard let physical, !isShutdown else {
                    throw AudioCaptureError.alreadyRecording
                }
                if configuration.retainsPCM {
                    guard dictation == nil else {
                        throw AudioCaptureError.alreadyRecording
                    }
                    let metadata = (
                        audioDeviceProvider?.micProximityForDevice(
                            physical.deviceID) ?? .nearField,
                        audioDeviceProvider?.deviceNameForDevice(
                            physical.deviceID) ?? "System Default")
                    let sink = try DictationAudioSink(
                        inputFormat: physical.transport.format,
                        micProximity: metadata.0,
                        deviceName: metadata.1)
                    let sinkToken = sinkPublication.publish(sink)
                    do {
                        let route = try physical.router.promote(
                            releaseBoundary: releaseBoundary
                                ?? AudioCaptureReleaseBoundary())
                        dictation = DictationCapture(
                            owner: owner,
                            sink: sink,
                            sinkToken: sinkToken,
                            route: route,
                            playsSoundFeedback: shouldPlay)
                        retainedMetrics = nil
                        metricsOwner = owner
                        pcmStreamSnapshot.publish(sink.pcmStream)
                    } catch {
                        _ = sinkPublication.clear(sinkToken)
                        sink.discard()
                        throw promotionError(error)
                    }
                } else {
                    guard preview == nil else {
                        throw AudioCaptureError.alreadyRecording
                    }
                    let pair = AsyncStream<Float>.makeStream(
                        bufferingPolicy: .bufferingNewest(1))
                    preview = PreviewCapture(
                        owner: owner,
                        stream: pair.stream,
                        continuation: pair.continuation)
                }
                onCaptureReady()
            }
            if shouldPlay {
                lock.withLock { soundFeedbackProvider }?.playStartSound()
            }
        }

        private func process(
            _ buffer: AVAudioPCMBuffer,
            timestamp: AVAudioTime,
            router: TimestampedAudioFrameRouter
        ) {
            let previewContinuation = lock.withLock { preview?.continuation }
            if let previewContinuation,
                let rms = Self.rms(buffer)
            {
                previewContinuation.yield(min(sqrtf(rms * 25), 1))
            }
            _ = router.ingest(buffer, timestamp: timestamp)
        }

        private static func rms(_ buffer: AVAudioPCMBuffer) -> Float? {
            guard let channels = buffer.floatChannelData else { return nil }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return nil }
            var sum: Float = 0
            if buffer.format.isInterleaved {
                for index in 0..<(frameCount * channelCount) {
                    let value = channels[0][index]
                    sum += value * value
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        let value = channels[channel][frame]
                        sum += value * value
                    }
                }
            }
            return sqrtf(sum / Float(frameCount * channelCount))
        }

        public func closeRecordingBoundary() {
            guard let owner = lock.withLock({ legacyOwner }) else { return }
            _ = closeRecordingBoundary(owner: owner)
        }

        public func closeRecordingBoundary(
            atHostTime releaseHostTime: UInt64
        ) {
            guard let owner = lock.withLock({ legacyOwner }) else { return }
            _ = closeRecordingBoundary(
                owner: owner,
                atHostTime: releaseHostTime)
        }

        @discardableResult
        public func closeRecordingBoundary(
            owner: AudioCaptureOwner
        ) -> Bool {
            closeRecordingBoundary(
                owner: owner,
                atHostTime: AudioCaptureReleaseFence.currentHostTime())
        }

        @discardableResult
        public func closeRecordingBoundary(
            owner: AudioCaptureOwner,
            atHostTime releaseHostTime: UInt64
        ) -> Bool {
            guard let route = lock.withLock({
                dictation?.owner == owner ? dictation?.route : nil
            }) else { return false }
            return route.publishRelease(at: releaseHostTime)
        }

        public func stopRecording() async throws -> AudioBuffer {
            guard let owner = lock.withLock({ legacyOwner }) else { return .empty }
            let result = try await stopRecording(owner: owner)
            lock.withLock {
                if legacyOwner == owner { legacyOwner = nil }
            }
            return result
        }

        public func stopRecording(
            owner: AudioCaptureOwner
        ) async throws -> AudioBuffer {
            let entry: StopEntry = try lock.withLock {
                if let entry = stopEntries[owner] { return entry }
                guard dictation?.owner == owner || preview?.owner == owner else {
                    throw AudioCaptureError.ownerMismatch
                }
                let id = UUID()
                let task = Task<AudioBuffer, any Error> { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.transitions.run {
                        try await self.stopSerialized(owner: owner)
                    }
                }
                let entry = StopEntry(id: id, task: task)
                stopEntries[owner] = entry
                return entry
            }
            defer {
                lock.withLock {
                    if stopEntries[owner]?.id == entry.id {
                        stopEntries[owner] = nil
                    }
                }
            }
            return try await entry.task.value
        }

        private func stopSerialized(
            owner: AudioCaptureOwner
        ) async throws -> AudioBuffer {
            guard let termination = demands.beginTermination(owner) else {
                throw AudioCaptureError.ownerMismatch
            }
            defer { demands.finishTermination(termination) }

            if lock.withLock({ dictation?.owner == owner }) {
                return try await stopDictation(owner: owner)
            }
            return try stopPreview(owner: owner)
        }

        private func stopDictation(
            owner: AudioCaptureOwner
        ) async throws -> AudioBuffer {
            guard let claim = lock.withLock({ () -> (
                capture: DictationCapture,
                physical: PhysicalCapture,
                sound: SoundFeedbackProvider?
            )? in
                guard let dictation, dictation.owner == owner, let physical else {
                    return nil
                }
                return (
                    dictation,
                    physical,
                    dictation.playsSoundFeedback ? soundFeedbackProvider : nil)
            }) else { throw AudioCaptureError.ownerMismatch }

            _ = claim.capture.route.publishRelease(
                at: AudioCaptureReleaseFence.currentHostTime())
            let router = claim.physical.router
            let route = claim.capture.route
            let sink = claim.capture.sink
            let drain = AudioCaptureStopDrain<StopFinalization>(
                observeRelease: {
                    guard await router.waitUntilReleaseObserved(for: route) else {
                        return false
                    }
                    return router.finish(route)
                },
                finalize: {
                    StopFinalization(
                        completion: sink.finishWithIntegrity(),
                        metrics: sink.metrics)
                })
            let timeout = min(
                max(3 * 512 / claim.physical.transport.format.sampleRate, 0.25),
                2)

            switch await drain.outcome(timeout: timeout) {
            case .completed(.finalized(let finalization)):
                let transportToStop = lock.withLock {
                    guard dictation?.owner == owner,
                        dictation?.route == route,
                        physical?.id == claim.physical.id
                    else { return nil as (any AUHALInputTransporting)? }
                    dictation = nil
                    retainedMetrics = finalization.metrics
                    metricsOwner = owner
                    pcmStreamSnapshot.clear()
                    _ = sinkPublication.clear(claim.capture.sinkToken)
                    if preview == nil {
                        physical = nil
                        return claim.physical.transport
                    }
                    return nil
                }
                transportToStop?.stop()
                if transportToStop != nil { router.reset() }
                claim.sound?.playStopSound()
                if let failure = finalization.completion.integrityFailure {
                    throw AudioCaptureError.incompleteCapture(
                        finalization.completion.buffer,
                        failure)
                }
                return finalization.completion.buffer

            case .completed(.releaseRejected), .deadline, .cancelled:
                let failure = sink.integrityPublication.failure
                    ?? drain.timeoutFailure
                let recovery = sink.recoveryBuffer()
                claim.physical.transport.stop()
                _ = router.finish(route)
                _ = await drain.task.value
                failCapture(
                    owner: owner,
                    claim: claim,
                    sink: sink)
                throw AudioCaptureError.incompleteCapture(recovery, failure)
            }
        }

        private func failCapture(
            owner: AudioCaptureOwner,
            claim: (
                capture: DictationCapture,
                physical: PhysicalCapture,
                sound: SoundFeedbackProvider?
            ),
            sink: DictationAudioSink
        ) {
            let previewOwner = lock.withLock { () -> AudioCaptureOwner? in
                guard physical?.id == claim.physical.id else { return nil }
                let previewOwner = preview?.owner
                preview?.continuation.finish()
                preview = nil
                dictation = nil
                physical = nil
                metricsOwner = nil
                retainedMetrics = nil
                pcmStreamSnapshot.clear()
                _ = sinkPublication.clear(claim.capture.sinkToken)
                if legacyOwner == owner { legacyOwner = nil }
                if let previewOwner, legacyOwner == previewOwner {
                    legacyOwner = nil
                }
                return previewOwner
            }
            if let previewOwner { _ = demands.remove(previewOwner) }
            claim.physical.router.reset()
            sink.discard()
        }

        private func stopPreview(
            owner: AudioCaptureOwner
        ) throws -> AudioBuffer {
            let claim = try lock.withLock { () -> (
                physical: PhysicalCapture?,
                continuation: AsyncStream<Float>.Continuation
            ) in
                guard let preview, preview.owner == owner else {
                    throw AudioCaptureError.ownerMismatch
                }
                self.preview = nil
                let physicalToStop: PhysicalCapture?
                if dictation == nil {
                    physicalToStop = physical
                    physical = nil
                } else {
                    physicalToStop = nil
                }
                return (physicalToStop, preview.continuation)
            }
            claim.continuation.finish()
            claim.physical?.transport.stop()
            claim.physical?.router.reset()
            return .empty
        }

        public func canRecoverCaptureReleasedBeforeReadiness(
            owner: AudioCaptureOwner,
            pressHostTime: UInt64
        ) -> Bool {
            lock.withLock {
                guard preview?.owner == owner, let physical else { return false }
                return physical.router.canPromoteFromContinuousCapture(
                    at: pressHostTime)
            }
        }

        @discardableResult
        public func forceReset(owner: AudioCaptureOwner) -> Bool {
            guard demands.remove(owner) else { return false }
            let cleanup = lock.withLock { () -> (
                transport: (any AUHALInputTransporting)?,
                router: TimestampedAudioFrameRouter?,
                sink: DictationAudioSink?,
                previewContinuation: AsyncStream<Float>.Continuation?
            ) in
                if dictation?.owner == owner {
                    let result = (
                        physical?.transport,
                        physical?.router,
                        dictation?.sink,
                        preview?.continuation)
                    if let previewOwner = preview?.owner {
                        _ = demands.remove(previewOwner)
                    }
                    physical = nil
                    dictation = nil
                    preview = nil
                    sinkPublication.reset()
                    pcmStreamSnapshot.clear()
                    metricsOwner = nil
                    retainedMetrics = nil
                    if legacyOwner == owner { legacyOwner = nil }
                    return result
                }
                guard preview?.owner == owner else {
                    return (nil, nil, nil, nil)
                }
                let continuation = preview?.continuation
                preview = nil
                if dictation == nil {
                    let result: (
                        (any AUHALInputTransporting)?,
                        TimestampedAudioFrameRouter?,
                        DictationAudioSink?,
                        AsyncStream<Float>.Continuation?
                    ) = (
                        physical?.transport,
                        physical?.router,
                        nil,
                        continuation
                    )
                    physical = nil
                    return result
                }
                return (nil, nil, nil, continuation)
            }
            cleanup.transport?.stop()
            cleanup.router?.reset()
            cleanup.sink?.discard()
            cleanup.previewContinuation?.finish()
            return true
        }

        public func forceReset() {
            guard let owner = lock.withLock({
                legacyOwner ?? dictation?.owner ?? preview?.owner
            }) else { return }
            _ = forceReset(owner: owner)
        }

        public func shutdown() {
            let owners = demands.sealForShutdown().activeOwners
            let cleanup = lock.withLock { () -> (
                transport: (any AUHALInputTransporting)?,
                router: TimestampedAudioFrameRouter?,
                sink: DictationAudioSink?,
                previewContinuation: AsyncStream<Float>.Continuation?
            ) in
                guard !isShutdown else { return (nil, nil, nil, nil) }
                isShutdown = true
                let result = (
                    physical?.transport,
                    physical?.router,
                    dictation?.sink,
                    preview?.continuation)
                physical = nil
                dictation = nil
                preview = nil
                sinkPublication.reset()
                pcmStreamSnapshot.clear()
                stopEntries.removeAll(keepingCapacity: false)
                return result
            }
            _ = owners
            cleanup.transport?.stop()
            cleanup.router?.reset()
            cleanup.sink?.discard()
            cleanup.previewContinuation?.finish()
        }

        public func markNeedsRebuild() {
            // AUHAL is pinned to one AudioObjectID. Unrelated default-device
            // changes do not invalidate it; an explicit selection transaction
            // drains this provider before starting a different device.
        }

        private func shouldPlaySoundFeedback(requested: Bool) -> Bool {
            guard requested else { return false }
            return lock.withLock {
                audioDeviceProvider?.isSoundFeedbackSafe ?? true
            }
        }

        private func promotionError(_ error: any Error) -> AudioCaptureError {
            guard
                let error = error as? TimestampedAudioFrameRouter.PromotionError
            else { return .formatError }
            switch error {
            case .dictationAlreadyActive:
                return .alreadyRecording
            case .preRollCoverageUnavailable:
                return .captureIntegrity(
                    AudioCaptureIntegrityFailure(
                        stage: .timestampCoverage,
                        affectedFrameCount: nil))
            case .sinkCreationFailed:
                return .formatError
            }
        }
    }
#endif
