from pathlib import Path

path = Path("composeApp/src/androidMain/kotlin/io/music_assistant/client/player/MediaPlayerController.android.kt")
text = path.read_text()


def replace_once(old: str, new: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"Expected source block not found:\n{old}")
    text = text.replace(old, new, 1)


replace_once(
    "import android.os.Build\n",
    "import android.os.Build\nimport android.os.Handler\nimport android.os.Looper\n",
)

replace_once(
    "    private val useTransientDuckingFocus = true\n",
    """    private val useTransientDuckingFocus = true

    // PoC announcement endpoint: focus must be a real transient cycle every time.
    // Android Auto can otherwise restore external media after the first announcement
    // but ignore a later MAY_DUCK request from the same still-cached focus state.
    private val focusReleaseHandler = Handler(Looper.getMainLooper())
    private var pendingFocusRelease: Runnable? = null
    private val focusReleaseDelayMs = 900L
    private val focusWriteWatchdogMs = 1500L
""",
)

replace_once(
    """    private fun requestAudioFocus(): Boolean {
        val focusGain = if (useTransientDuckingFocus) {
""",
    """    private fun requestAudioFocus(): Boolean {
        cancelPendingFocusRelease()

        // IMPORTANT: always end any previous transient focus ownership before a new
        // Sendspin stream starts. Do not reuse the old request, even for the next
        // segment. Real Android Auto testing showed that reuse works once, but the
        // following announcement no longer ducks Spotify. A fresh abandon/request
        // pair forces Android to create a new MAY_DUCK focus transition every time.
        if (useTransientDuckingFocus && (hasAudioFocus || audioFocusRequest != null)) {
            logger.i { "Resetting transient audio focus before fresh announcement request" }
            releaseAudioFocus()
        }

        val focusGain = if (useTransientDuckingFocus) {
""",
)

replace_once(
    """        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
""",
    """        val audioAttributes = AudioAttributes.Builder()
            .setUsage(
                if (useTransientDuckingFocus) {
                    AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
                } else {
                    AudioAttributes.USAGE_MEDIA
                },
            )
            .setContentType(
                if (useTransientDuckingFocus) {
                    AudioAttributes.CONTENT_TYPE_SPEECH
                } else {
                    AudioAttributes.CONTENT_TYPE_MUSIC
                },
            )
            .build()
""",
)

replace_once(
    """    private fun releaseAudioFocus() {
""",
    """    private fun cancelPendingFocusRelease() {
        pendingFocusRelease?.let { focusReleaseHandler.removeCallbacks(it) }
        pendingFocusRelease = null
    }

    private fun scheduleAudioFocusRelease(delayMs: Long = focusReleaseDelayMs) {
        cancelPendingFocusRelease()
        val release = Runnable {
            pendingFocusRelease = null
            logger.i { "Announcement focus timeout ended — releasing transient audio focus" }
            releaseAudioFocus()
        }
        pendingFocusRelease = release
        focusReleaseHandler.postDelayed(release, delayMs)
        logger.i { "Transient ducking focus scheduled for release in ${delayMs}ms" }
    }

    private fun releaseAudioFocus() {
        cancelPendingFocusRelease()
""",
)

replace_once(
    """                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
""",
    """                    AudioAttributes.Builder()
                        .setUsage(
                            if (useTransientDuckingFocus) {
                                AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
                            } else {
                                AudioAttributes.USAGE_MEDIA
                            },
                        )
                        .setContentType(
                            if (useTransientDuckingFocus) {
                                AudioAttributes.CONTENT_TYPE_SPEECH
                            } else {
                                AudioAttributes.CONTENT_TYPE_MUSIC
                            },
                        )
                        .build(),
""",
)

replace_once(
    """            } else {
                logger.d { "AudioTrack wrote $written/${data.size} bytes" }
                written
            }
""",
    """            } else {
                logger.d { "AudioTrack wrote $written/${data.size} bytes" }
                if (useTransientDuckingFocus && written > 0) {
                    // Safety watchdog: if Android Auto / Sendspin misses the normal
                    // stream-stop callback, the external media still gets unducked.
                    scheduleAudioFocusRelease(focusWriteWatchdogMs)
                }
                written
            }
""",
)

replace_once(
    """        if (useTransientDuckingFocus) {
            logger.i { "PoC transient stream ended — releasing audio focus so external media can unduck" }
            releaseAudioFocus()
        }
""",
    """        if (useTransientDuckingFocus) {
            logger.i { "PoC transient stream ended — scheduling focus release after announcement grace period" }
            scheduleAudioFocusRelease()
        }
""",
)

replace_once(
    """        val volumeFloat = if (isMuted) {
            0f
        } else {
            (currentVolume / 100f).coerceIn(0f, 1f)
        }
""",
    """        val volumeFloat = if (isMuted) {
            0f
        } else if (useTransientDuckingFocus) {
            // Keep MA announcement PCM at full local gain. Android Auto / the head
            // unit applies its independent navigation-guidance volume on top.
            1f
        } else {
            (currentVolume / 100f).coerceIn(0f, 1f)
        }
""",
)

path.write_text(text)
print("Applied PoC announcement-focus patch")
