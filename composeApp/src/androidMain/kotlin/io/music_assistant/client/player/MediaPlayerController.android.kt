@file:Suppress("EXPECT_ACTUAL_CLASSIFIERS_ARE_IN_BETA_WARNING")

package io.music_assistant.client.player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import androidx.annotation.RequiresApi
import co.touchlab.kermit.Logger
import io.music_assistant.client.player.sendspin.model.AudioCodec

/**
 * MediaPlayerController - Sendspin audio player
 *
 * Handles raw PCM audio streaming for Sendspin protocol.
 * Built-in player (ExoPlayer) has been removed - Sendspin is now the only playback method.
 */
actual class MediaPlayerController actual constructor(platformContext: PlatformContext) {
    actual var onRemoteCommand: ((String) -> Unit)? = null

    private val logger = Logger.withTag("MediaPlayerController")
    private val context: Context = platformContext.applicationContext
    private val audioManager: AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    @Volatile private var audioTrack: AudioTrack? = null
    private var audioTrackCreationTime: Long = 0
    private var currentListener: MediaPlayerListener? = null

    private var audioFocusRequest: AudioFocusRequest? = null
    @Volatile private var hasAudioFocus = false
    @Volatile private var shouldPlayAudio = false
    @Volatile private var pausedByFocusLoss = false

    private var currentVolume: Int = 100
    private var isMuted: Boolean = false

    /**
     * Issue #941 proof-of-concept.
     *
     * The Sendspin stream is treated as a short-lived announcement endpoint and requests
     * AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK. Android can therefore keep another media app
     * (Spotify, YouTube Music, radio, ...) playing at a reduced volume instead of forcing
     * it to pause. Focus is explicitly abandoned when the Sendspin stream ends.
     *
     * This is intentionally hard-coded on this PoC branch. If device testing succeeds,
     * this should become an opt-in local-player setting before an upstream PR.
     */
    private val useTransientDuckingFocus = true

    private val noisyAudioReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                logger.w { "Audio becoming noisy (headphones unplugged) - stopping playback" }
                handleAudioOutputDisconnected()
            }
        }
    }
    private var isNoisyReceiverRegistered = false

    @get:RequiresApi(Build.VERSION_CODES.S)
    private val modeChangedListener by lazy {
        AudioManager.OnModeChangedListener { mode ->
            val inCall = mode == AudioManager.MODE_IN_CALL ||
                mode == AudioManager.MODE_IN_COMMUNICATION
            if (inCall && shouldPlayAudio) {
                logger.i { "Telephony mode=$mode — pausing server playback (focus backup)" }
                shouldPlayAudio = false
                pausedByFocusLoss = true
                audioTrack?.pause()
                onRemoteCommand?.invoke("pause")
            }
        }
    }
    private var isModeChangedListenerRegistered = false

    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                logger.i { "AudioFocus gained" }
                hasAudioFocus = true
                shouldPlayAudio = true

                audioTrack?.let { track ->
                    if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                        logger.i { "Resuming AudioTrack playback after focus gain" }
                        track.flush()
                        track.play()
                    }
                }
                applyVolume()

                if (pausedByFocusLoss) {
                    pausedByFocusLoss = false
                    logger.i { "Resuming server playback after focus regain" }
                    onRemoteCommand?.invoke("play")
                }
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                logger.w { "AudioFocus lost permanently (Android Auto connected, another app took focus, etc.)" }
                hasAudioFocus = false
                handleAudioOutputDisconnected()
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                logger.i { "AudioFocus lost temporarily" }
                hasAudioFocus = false
                val wasPlaying = shouldPlayAudio
                shouldPlayAudio = false
                audioTrack?.pause()
                if (wasPlaying) {
                    pausedByFocusLoss = true
                    logger.i { "Pausing server playback due to focus loss" }
                    onRemoteCommand?.invoke("pause")
                }
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                logger.i { "AudioFocus lost temporarily (can duck)" }
                audioTrack?.setVolume(0.2f)
            }
        }
    }

    private fun requestAudioFocus(): Boolean {
        val focusGain = if (useTransientDuckingFocus) {
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
        } else {
            AudioManager.AUDIOFOCUS_GAIN
        }

        logger.i {
            "Requesting audio focus mode=${if (useTransientDuckingFocus) "TRANSIENT_MAY_DUCK" else "GAIN"} " +
                "(hasAudioFocus=$hasAudioFocus)"
        }

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        // A request's focus-gain type is immutable. Build a fresh request so switching the
        // future user setting cannot accidentally reuse a request created for another mode.
        audioFocusRequest?.let {
            try {
                audioManager.abandonAudioFocusRequest(it)
            } catch (e: Exception) {
                logger.w(e) { "Failed to abandon previous audio focus request before re-request" }
            }
        }

        val request = AudioFocusRequest.Builder(focusGain)
            .setAudioAttributes(audioAttributes)
            .setOnAudioFocusChangeListener(audioFocusChangeListener)
            .build()
        audioFocusRequest = request

        val result = audioManager.requestAudioFocus(request)
        hasAudioFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        logger.i {
            "Audio focus request (${if (useTransientDuckingFocus) "TRANSIENT_MAY_DUCK" else "GAIN"}) result: " +
                if (hasAudioFocus) "GRANTED" else "DENIED"
        }
        return hasAudioFocus
    }

    private fun releaseAudioFocus() {
        val request = audioFocusRequest ?: return

        try {
            audioManager.abandonAudioFocusRequest(request)
        } catch (e: Exception) {
            logger.w(e) { "Failed to abandon audio focus request" }
        }

        hasAudioFocus = false
        audioFocusRequest = null
        logger.i { "Audio focus released" }
    }

    private fun handleAudioOutputDisconnected() {
        logger.w { "Handling audio output disconnection - stopping sendspin stream" }
        shouldPlayAudio = false

        audioTrack?.let { track ->
            try {
                if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    track.pause()
                    track.flush()
                    logger.i { "AudioTrack paused and flushed due to output disconnection" }
                }
            } catch (e: Exception) {
                logger.e(e) { "Error pausing AudioTrack on disconnection" }
            }
        }

        releaseAudioFocus()
        currentListener?.onError(
            Exception("Audio output disconnected (Android Auto, headphones, or Bluetooth)"),
        )
        logger.i { "Sent error signal to stop sendspin stream. User should press play to resume on phone speakers." }
    }

    actual fun prepareStream(
        codec: AudioCodec,
        sampleRate: Int,
        channels: Int,
        bitDepth: Int,
        codecHeader: String?,
        listener: MediaPlayerListener,
    ) {
        logger.i { "Preparing raw PCM stream: ${sampleRate}Hz, ${channels}ch, ${bitDepth}bit" }
        currentListener = listener

        if (!requestAudioFocus()) {
            logger.w { "Failed to gain audio focus, but continuing anyway" }
        }

        registerNoisyAudioReceiver()
        registerModeChangedListener()
        audioTrack?.release()

        val channelConfig = when (channels) {
            1 -> AudioFormat.CHANNEL_OUT_MONO
            2 -> AudioFormat.CHANNEL_OUT_STEREO
            else -> {
                logger.w { "Unsupported channel count: $channels, using stereo" }
                AudioFormat.CHANNEL_OUT_STEREO
            }
        }

        val encoding = when {
            bitDepth == 8 -> AudioFormat.ENCODING_PCM_8BIT
            bitDepth == 16 -> AudioFormat.ENCODING_PCM_16BIT
            bitDepth == 24 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                AudioFormat.ENCODING_PCM_24BIT_PACKED
            bitDepth == 32 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                AudioFormat.ENCODING_PCM_32BIT
            else -> {
                logger.w { "Unsupported bit depth: $bitDepth, using 16-bit" }
                AudioFormat.ENCODING_PCM_16BIT
            }
        }

        val minBufferSize = AudioTrack.getMinBufferSize(sampleRate, channelConfig, encoding)
        if (minBufferSize <= 0) {
            val errorName = when (minBufferSize) {
                AudioTrack.ERROR -> "ERROR"
                AudioTrack.ERROR_BAD_VALUE -> "ERROR_BAD_VALUE"
                else -> "UNKNOWN($minBufferSize)"
            }
            logger.e { "getMinBufferSize returned $errorName for ${sampleRate}Hz/${channels}ch/${bitDepth}bit" }
            listener.onError(
                IllegalStateException("Audio configuration not supported by device: $errorName"),
            )
            return
        }
        val bufferSize = minBufferSize * 4

        logger.i { "AudioTrack config: sampleRate=$sampleRate, channels=$channels, bitDepth=$bitDepth" }
        logger.i { "AudioTrack buffer: $bufferSize bytes (min: $minBufferSize)" }

        try {
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelConfig)
                        .setEncoding(encoding)
                        .build(),
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build()

            audioTrackCreationTime = System.currentTimeMillis()

            if (track.state != AudioTrack.STATE_INITIALIZED) {
                logger.e { "AudioTrack created but STATE_UNINITIALIZED — aborting" }
                track.release()
                audioTrack = null
                listener.onError(IllegalStateException("AudioTrack failed to initialize"))
                return
            }

            audioTrack = track
            logger.i { "AudioTrack created: STATE_INITIALIZED" }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    track.setStartThresholdInFrames(1)
                    logger.i { "AudioTrack startThreshold set to 1 frame" }
                } catch (e: Exception) {
                    logger.w(e) { "Failed to set startThresholdInFrames" }
                }
            }

            track.play()
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                logger.e { "AudioTrack.play() called but playState=${track.playState} — not playing" }
            }

            shouldPlayAudio = true
            applyVolume()
            listener.onReady()
        } catch (e: Exception) {
            logger.e(e) { "Failed to create AudioTrack" }
            listener.onError(e)
        }
    }

    actual fun writeRawPcm(data: ByteArray): Int {
        val track = audioTrack
        if (track == null) {
            logger.w { "AudioTrack not initialized" }
            return 0
        }

        if (!shouldPlayAudio) {
            logger.d { "Skipping audio write - shouldPlayAudio=false (audio focus lost or paused)" }
            return data.size
        }

        return try {
            val written = track.write(data, 0, data.size)
            if (written < 0) {
                val errorName = when (written) {
                    AudioTrack.ERROR_INVALID_OPERATION -> "ERROR_INVALID_OPERATION"
                    AudioTrack.ERROR_BAD_VALUE -> "ERROR_BAD_VALUE"
                    AudioTrack.ERROR_DEAD_OBJECT -> "ERROR_DEAD_OBJECT"
                    else -> "UNKNOWN_ERROR($written)"
                }
                logger.w { "AudioTrack write error: $errorName" }
                0
            } else {
                logger.d { "AudioTrack wrote $written/${data.size} bytes" }
                written
            }
        } catch (e: Exception) {
            logger.e(e) { "Error writing PCM data" }
            0
        }
    }

    actual fun pauseSink() {
        pausedByFocusLoss = false
        audioTrack?.pause()
    }

    actual fun resumeSink() {
        if (!shouldPlayAudio) {
            if (!requestAudioFocus()) {
                logger.w { "resumeSink: cannot re-acquire audio focus — sink stays paused" }
                return
            }
            shouldPlayAudio = true
        }
        audioTrack?.play()
    }

    actual fun flush() {
        try {
            audioTrack?.flush()
        } catch (e: IllegalStateException) {
            logger.w(e) { "AudioTrack flush failed (track released)" }
        }
    }

    actual fun resume() {
        resumeSink()
        onRemoteCommand?.invoke("play")
    }

    actual fun stopRawPcmStream() {
        logger.i { "Stopping raw PCM stream" }

        shouldPlayAudio = false
        pausedByFocusLoss = false
        currentListener = null

        audioTrack?.let { track ->
            try {
                if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    track.pause()
                }
                track.flush()
                track.stop()
                track.release()
            } catch (e: Exception) {
                logger.e(e) { "Error stopping AudioTrack" }
            }
        }

        audioTrack = null

        if (useTransientDuckingFocus) {
            logger.i { "PoC transient stream ended — releasing audio focus so external media can unduck" }
            releaseAudioFocus()
        }
    }

    actual fun setVolume(volume: Int) {
        currentVolume = volume.coerceIn(0, 100)
        logger.i { "Setting volume to $currentVolume" }
        applyVolume()
    }

    actual fun setMuted(muted: Boolean) {
        isMuted = muted
        logger.i { "Setting muted to $muted (audioTrack=${if (audioTrack != null) "initialized" else "null"})" }
        applyVolume()
    }

    actual fun getCurrentSystemVolume(): Int {
        val currentSystemVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val volumePercent = if (maxVolume > 0) {
            (currentSystemVolume * 100 / maxVolume).coerceIn(0, 100)
        } else {
            logger.w { "AudioManager returned max volume 0, defaulting to 0%" }
            0
        }
        logger.d { "System volume: $currentSystemVolume/$maxVolume = $volumePercent%" }
        return volumePercent
    }

    private fun applyVolume() {
        val track = audioTrack ?: return
        val volumeFloat = if (isMuted) {
            0f
        } else {
            (currentVolume / 100f).coerceIn(0f, 1f)
        }

        try {
            track.setVolume(volumeFloat)
            logger.d { "Applied volume: $volumeFloat (volume=$currentVolume, muted=$isMuted)" }
        } catch (e: Exception) {
            logger.e(e) { "Error setting volume" }
        }
    }

    private fun registerNoisyAudioReceiver() {
        if (!isNoisyReceiverRegistered) {
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            context.registerReceiver(noisyAudioReceiver, filter)
            isNoisyReceiverRegistered = true
            logger.d { "Registered noisy audio receiver" }
        }
    }

    private fun registerModeChangedListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || isModeChangedListenerRegistered) {
            return
        }
        try {
            audioManager.addOnModeChangedListener(context.mainExecutor, modeChangedListener)
            isModeChangedListenerRegistered = true
            logger.d { "Registered telephony-mode listener" }
        } catch (e: Exception) {
            logger.w(e) { "Failed to register telephony-mode listener" }
        }
    }

    private fun unregisterModeChangedListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || !isModeChangedListenerRegistered) {
            return
        }
        try {
            audioManager.removeOnModeChangedListener(modeChangedListener)
            isModeChangedListenerRegistered = false
            logger.d { "Unregistered telephony-mode listener" }
        } catch (e: Exception) {
            logger.w(e) { "Failed to unregister telephony-mode listener" }
        }
    }

    private fun unregisterNoisyAudioReceiver() {
        if (isNoisyReceiverRegistered) {
            try {
                context.unregisterReceiver(noisyAudioReceiver)
                isNoisyReceiverRegistered = false
                logger.d { "Unregistered noisy audio receiver" }
            } catch (e: Exception) {
                logger.e(e) { "Error unregistering noisy audio receiver" }
            }
        }
    }

    actual fun setLongFormSeekIntervals(backSeconds: Long, forwardSeconds: Long) {
        // Android handles seek intervals via MediaSession custom actions, not here.
    }

    actual fun release() {
        logger.i { "Releasing MediaPlayerController" }
        unregisterNoisyAudioReceiver()
        unregisterModeChangedListener()
        stopRawPcmStream()
        releaseAudioFocus()
    }
}

actual class PlatformContext(val applicationContext: Context)
