import Foundation
import AVFoundation
import AudioToolbox
import ComposeApp

/// Native iOS audio player using AudioQueue
/// Replaces MPVController for better iOS integration
class NativeAudioController: NSObject, PlatformAudioPlayer {

    // MARK: - AudioQueue
    private var audioQueue: AudioQueueRef?
    private var audioFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()

    // MARK: - Audio Buffer
    private var pcmBuffer: [Data] = []
    private let bufferLock = NSLock()
    private let kNumberOfBuffers = 5 // More buffers for smoother playback
    private let kBufferSize: UInt32 = 65536 // 64KB per buffer for less stuttering


    // MARK: - Decoder
    private var decoder: NativeAudioDecoder?
    private let decoderLock = NSLock()
    private var listener: MediaPlayerListener?

    // MARK: - Stream Configuration
    private var currentCodec: String = "flac"
    private var currentSampleRate: Int32 = 48000
    private var currentChannels: Int32 = 2
    private var currentBitDepth: Int32 = 16
    private var codecHeader: Data?

    // MARK: - State
    private var isPlaying = false
    /// True while local playback owns or is claiming the shared audio session.
    var isRenderingAudio: Bool { streamStarted || isPlaying }
    private var streamStarted = false
    // Play-intent gate (mirrors Android's shouldPlayAudio). While false — paused or
    // interrupted — incoming audio is dropped instead of (re)starting the queue, so
    // a packet still in the consumer pipeline can't undo an optimistic pause.
    private var shouldPlay = true
    // True only while we hold a server pause issued in response to an audio-session
    // interruption (phone call, Siri). On .ended we auto-resume the server only if
    // this is set — so we never spontaneously start playback that the user didn't
    // have running before the interruption.
    private var pausedByInterruption = false

    // MARK: - Overlay Announcements
    // Native overlay path used by the custom Home Assistant bridge. The main
    // Sendspin AudioQueue keeps rendering while AVAudioPlayer speaks over it.
    // Ducking is applied only to our main queue, so CarPlay never sees a stop/
    // restart and the interrupted song continues underneath the announcement.
    private var announcementPlayer: AVAudioPlayer?
    private var announcementDownloadTask: URLSessionDataTask?
    private var mainVolume: Float = 1.0
    private var mainMuted = false
    private var announcementDuckFactor: Float = 1.0
    private var announcementGeneration: UInt64 = 0

    // MARK: - Logging
    // Routes through Kermit (NativeLog) so these reach the shareable in-memory buffer
    // and os.Logger
    private static let logTag = "NativeAudioController"
    private func logInfo(_ message: String) { NativeLog.shared.info(tag: Self.logTag, message: message) }
    private func logError(_ message: String) { NativeLog.shared.error(tag: Self.logTag, message: message) }
    private func logDebug(_ message: String) { NativeLog.shared.debug(tag: Self.logTag, message: message) }

    override init() {
        super.init()
        logDebug("Initialized")

        // Handle audio session interruptions (phone calls, Siri, alarms)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        // Handle route changes (headphones unplugged, Bluetooth disconnects)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // System auto-pauses AudioQueue. Tell the server to pause too so playback
            // resumes from the same position afterwards instead of skipping ahead while
            // the call held the audio session.
            logInfo("Audio session interrupted")
            if isPlaying {
                pausedByInterruption = true
                logInfo("Pausing server playback due to interruption")
                remoteCommandHandler?.onCommand(command: "pause", source: "interruption")
            }
        case .ended:
            guard pausedByInterruption else { break }
            pausedByInterruption = false
            // We deliberately do not use .shouldResume here as it is not guaranteed
            // to be set even in cases it should be. As per Apple, it's a hint not
            // a contract. Instead we track for ourselves if we were interrupted,
            // and once control is handed back, if another app is now using the
            // audio device exclusively.
            if !AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint {
                logInfo("Resuming server playback after interruption")
                remoteCommandHandler?.onCommand(command: "play", source: "interruption")
            } else {
                logInfo("Another app holds audio — staying paused")
            }
        @unknown default:
            break
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            logInfo("Audio output device disconnected")
            let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription
            handleOldDeviceUnavailable(previousRoute: previousRoute)
        }
    }

    /// Pause when the active output route disappears (Bluetooth disconnect,
    /// headphones unplug, AirPods power-off, CarPlay disconnect) — never let
    /// playback silently fall back to the phone speaker. Shutting `shouldPlay`
    /// drops in-flight packets so the next one can't rebuild the queue on the
    /// new route; the server pause stops the stream at the source. Unlike an
    /// interruption, iOS sends no matching `.ended`, so this is a deliberate
    /// pause the user resumes by hand, on whatever route is then active.
    /// (AirPods already send their own `pause` remote command on removal; the
    /// `streamStarted` guard makes this a no-op once that has shut the gate.)
    private func handleOldDeviceUnavailable(previousRoute: AVAudioSessionRouteDescription?) {
        guard streamStarted else { return }
        let prev = previousRoute?.outputs.first?.portType.rawValue ?? "unknown"
        logInfo("\(prev) disappeared — pausing playback")
        shouldPlay = false
        streamStarted = false
        stopAudioQueue()
        bufferLock.lock()
        pcmBuffer.removeAll()
        bufferLock.unlock()
        remoteCommandHandler?.onCommand(command: "pause", source: "route_loss")
    }

    // MARK: - PlatformAudioPlayer Protocol

    func prepareStream(codec: String, sampleRate: Int32, channels: Int32, bitDepth: Int32, codecHeader: String?, listener: MediaPlayerListener) {
        logInfo("prepareStream - codec=\(codec), rate=\(sampleRate), ch=\(channels), bit=\(bitDepth)")

        self.listener = listener
        self.currentCodec = codec.lowercased()
        self.currentSampleRate = sampleRate
        self.currentChannels = channels
        self.currentBitDepth = bitDepth
        self.streamStarted = false
        self.shouldPlay = true

        // Decode codec header if present
        if let headerBase64 = codecHeader, let headerData = Data(base64Encoded: headerBase64) {
            self.codecHeader = headerData
            logDebug("Decoded codec header: \(headerData.count) bytes")
        } else {
            self.codecHeader = nil
        }

        // Stop any existing playback
        stopAudioQueue()

        // Clear buffers
        bufferLock.lock()
        pcmBuffer.removeAll()
        bufferLock.unlock()

        // Create decoder for codec
        do {
            let newDecoder = try AudioDecoderFactory.create(
                codec: currentCodec,
                sampleRate: Int(sampleRate),
                channels: Int(channels),
                bitDepth: Int(bitDepth),
                codecHeader: self.codecHeader
            )
            decoderLock.lock()
            decoder = newDecoder
            decoderLock.unlock()
            logInfo("Created decoder for \(codec)")
        } catch {
            logError("Failed to create decoder: \(error)")
            listener.onError(error: KotlinThrowable(message: error.localizedDescription))
            return
        }

        listener.onReady()
    }

    /// Called from Kotlin via efficient NSData bulk-copy path (avoids per-byte Swift interop).
    func writeRawPcmNSData(data: Data) {
        processAudioData(data)
    }

    /// Legacy path: still satisfies the PlatformAudioPlayer protocol but is no longer
    /// called from Kotlin (Kotlin always uses writeRawPcmNSData now).
    func writeRawPcm(data: KotlinByteArray) {
        let size = Int(data.size)
        var swiftData = Data(count: size)
        for i in 0..<size {
            swiftData[i] = UInt8(bitPattern: data.get(index: Int32(i)))
        }
        processAudioData(swiftData)
    }

    private func processAudioData(_ swiftData: Data) {
        // Suspended (paused / interrupted): drop in-flight audio rather than
        // restart the queue, so a packet still in the consumer pipeline can't
        // undo the pause before the server stops streaming.
        guard shouldPlay else { return }

        // Start audio queue on first data
        if !streamStarted {
            streamStarted = true
            logDebug("First data received (\(swiftData.count) bytes)")
            NowPlayingCoordinator.shared.activatePlayback()
            startAudioQueue()
        }

        decoderLock.lock()
        defer { decoderLock.unlock() }

        guard let decoder = decoder else {
            logDebug("No decoder available — dropping packet")
            return
        }

        do {
            let pcmData = try decoder.decode(swiftData)
            bufferLock.lock()
            pcmBuffer.append(pcmData)
            bufferLock.unlock()
        } catch {
            logDebug("Decode error: \(error)")
        }
    }

    func stopRawPcmStream() {
        logInfo("Stopping stream")
        shouldPlay = false
        streamStarted = false
        stopAudioQueue()

        bufferLock.lock()
        pcmBuffer.removeAll()
        bufferLock.unlock()
    }

    /// Tear down rather than `AudioQueuePause`: a paused queue replays its stale
    /// primed buffers on resume, then underruns. `shouldPlay = false` drops any
    /// in-flight audio so the consumer can't immediately rebuild the queue;
    /// resume then rebuilds clean on the next packet, like a cold start.
    func pauseSink() {
        logInfo("pauseSink")
        shouldPlay = false
        streamStarted = false
        tearDownQueue()
    }

    /// Reactivating the session reclaims audio from another app that grabbed it.
    /// `shouldPlay = true` re-opens the write gate; the queue rebuilds on the next
    /// audio packet, or is started here if one still exists (gapless restart).
    func resumeSink() {
        logInfo("resumeSink")
        shouldPlay = true
        NowPlayingCoordinator.shared.activatePlayback()
        isPlaying = true
        if let queue = audioQueue {
            AudioQueueStart(queue, nil)
        }
    }

    /// Drop buffered PCM (track transition / playback-delay re-phase).
    func flush() {
        bufferLock.lock()
        pcmBuffer.removeAll()
        bufferLock.unlock()
    }

    func setVolume(volume: Int32) {
        mainVolume = (Float(volume) / 100.0).clamped(to: 0.0...1.0)
        applyMainQueueVolume()
    }

    func setMuted(muted: Bool) {
        mainMuted = muted
        applyMainQueueVolume()
    }

    private func applyMainQueueVolume() {
        guard let queue = audioQueue else { return }
        let effective: Float = mainMuted ? 0.0 : mainVolume * announcementDuckFactor
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, effective)
    }

    /// Play an HTTP(S) audio clip over the current Sendspin stream without
    /// stopping or pausing it. The main stream is attenuated locally for the
    /// duration of the clip, then restored to the latest server-controlled
    /// volume. Safe to call while no music is playing as well.
    func playOverlayAnnouncement(
        urlString: String,
        duckingLevel: Double = 0.22,
        announcementVolume: Double = 1.0
    ) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            logError("Overlay announcement rejected invalid URL")
            return
        }

        announcementGeneration &+= 1
        let generation = announcementGeneration

        announcementDownloadTask?.cancel()
        announcementDownloadTask = nil
        announcementPlayer?.stop()
        announcementPlayer = nil
        announcementDuckFactor = 1.0
        applyMainQueueVolume()

        logInfo("Overlay announcement download started")
        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        announcementDownloadTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard generation == self.announcementGeneration else { return }

            if let error {
                self.logError("Overlay announcement download failed: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.logError("Overlay announcement HTTP \(http.statusCode)")
                return
            }
            guard let data, !data.isEmpty else {
                self.logError("Overlay announcement returned no audio data")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.announcementGeneration else { return }
                do {
                    NowPlayingCoordinator.shared.activatePlayback()

                    let player = try AVAudioPlayer(data: data)
                    player.delegate = self
                    player.volume = Float(announcementVolume).clamped(to: 0.0...1.0)
                    player.prepareToPlay()

                    self.announcementDuckFactor =
                        Float(duckingLevel).clamped(to: 0.0...1.0)
                    self.applyMainQueueVolume()
                    self.announcementPlayer = player

                    guard player.play() else {
                        self.logError("Overlay announcement AVAudioPlayer refused play()")
                        self.finishOverlayAnnouncement()
                        return
                    }
                    self.logInfo("Overlay announcement started; main stream remains active")
                } catch {
                    self.logError("Overlay announcement decode failed: \(error.localizedDescription)")
                    self.finishOverlayAnnouncement()
                }
            }
        }
        announcementDownloadTask?.resume()
    }

    func stopOverlayAnnouncement() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.announcementGeneration &+= 1
            self.announcementDownloadTask?.cancel()
            self.announcementDownloadTask = nil
            self.announcementPlayer?.stop()
            self.finishOverlayAnnouncement()
        }
    }

    private func finishOverlayAnnouncement() {
        announcementPlayer = nil
        announcementDownloadTask = nil
        announcementDuckFactor = 1.0
        applyMainQueueVolume()
        logInfo("Overlay announcement finished; main stream volume restored")
    }

    func dispose() {
        stopOverlayAnnouncement()
        // The Now Playing surface is cleared by the track channel going null
        // (pipeline teardown removes the current item); no direct clear here.
        stopAudioQueue()
        decoderLock.lock()
        decoder = nil
        decoderLock.unlock()
    }

    // MARK: - AudioQueue Management

    private func startAudioQueue() {
        // Configure audio format (always output PCM)
        audioFormat.mSampleRate = Float64(currentSampleRate)
        audioFormat.mFormatID = kAudioFormatLinearPCM
        audioFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        audioFormat.mFramesPerPacket = 1
        audioFormat.mChannelsPerFrame = UInt32(currentChannels)

        // FLAC decoder always outputs Int32 (scaled to full range).
        // PCM 24-bit is unpacked to Int32 by PCMPassthroughDecoder.
        // All other cases use the negotiated bit depth directly.
        let effectiveBitDepth: Int32
        if currentCodec == "flac" || currentBitDepth == 24 {
            effectiveBitDepth = 32
        } else {
            effectiveBitDepth = currentBitDepth
        }
        let bytesPerSample = effectiveBitDepth / 8

        audioFormat.mBitsPerChannel = UInt32(effectiveBitDepth)
        audioFormat.mBytesPerFrame = UInt32(currentChannels) * UInt32(bytesPerSample)
        audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame

        logDebug("Audio format - \(currentSampleRate)Hz, \(currentChannels)ch, \(effectiveBitDepth)bit")

        // Create AudioQueue
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        var queue: AudioQueueRef?
        let status = AudioQueueNewOutput(
            &audioFormat,
            audioQueueCallback,
            selfPointer,
            nil,
            nil,
            0,
            &queue
        )

        guard status == noErr, let queue = queue else {
            logError("Failed to create AudioQueue: \(status)")
            return
        }

        audioQueue = queue
        applyMainQueueVolume()

        // Allocate and prime buffers
        for _ in 0..<kNumberOfBuffers {
            var buffer: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, kBufferSize, &buffer)

            if allocStatus == noErr, let buffer = buffer {
                fillBuffer(queue: queue, buffer: buffer)
            }
        }

        // Start playback
        let startStatus = AudioQueueStart(queue, nil)
        if startStatus == noErr {
            isPlaying = true
            logInfo("AudioQueue started")
        } else {
            logError("Failed to start AudioQueue: \(startStatus)")
        }
    }

    private func stopAudioQueue() {
        tearDownQueue()
        pausedByInterruption = false // Stream stopped — no auto-resume on .ended.
    }

    /// `AudioQueueStop(_, true)` discards enqueued hardware buffers, so a rebuilt
    /// queue never replays stale audio. Leaves `pausedByInterruption` untouched —
    /// a pause issued during `.began` must still auto-resume on `.ended`.
    private func tearDownQueue() {
        guard let queue = audioQueue else { return }

        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)

        audioQueue = nil
        isPlaying = false
        logInfo("AudioQueue stopped")
    }

    fileprivate func fillBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        // Get next PCM data from buffer
        bufferLock.lock()
        let pcmData = pcmBuffer.isEmpty ? nil : pcmBuffer.removeFirst()
        bufferLock.unlock()

        if let data = pcmData {
            // Copy PCM data to buffer
            let copySize = min(data.count, Int(buffer.pointee.mAudioDataBytesCapacity))
            _ = data.withUnsafeBytes { srcBytes in
                memcpy(buffer.pointee.mAudioData, srcBytes.baseAddress, copySize)
            }
            buffer.pointee.mAudioDataByteSize = UInt32(copySize)
        } else {
            // No data - output silence
            memset(buffer.pointee.mAudioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
            buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        }

        // Re-enqueue buffer
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    // MARK: - Now Playing (Control Center / Lock Screen)

    private var remoteCommandHandler: RemoteCommandHandler?

    func setLongFormSeekIntervals(backSeconds: Int64, forwardSeconds: Int64) {
        NowPlayingCoordinator.shared.setLongFormSeekIntervals(
            backSeconds: backSeconds,
            forwardSeconds: forwardSeconds
        )
    }

    func setRemoteCommandHandler(handler: RemoteCommandHandler?) {
        self.remoteCommandHandler = handler

        NowPlayingCoordinator.shared.setCommandHandler { [weak self] command in
            self?.logInfo("Remote command: \(command)")
            self?.remoteCommandHandler?.onCommand(command: command, source: "remote")
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension NativeAudioController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === announcementPlayer else { return }
        finishOverlayAnnouncement()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === announcementPlayer else { return }
        if let error {
            logError("Overlay announcement playback error: \(error.localizedDescription)")
        }
        finishOverlayAnnouncement()
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

// MARK: - AudioQueue Callback

private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData = userData else { return }

    let controller = Unmanaged<NativeAudioController>.fromOpaque(userData).takeUnretainedValue()
    controller.fillBuffer(queue: queue, buffer: buffer)
}
