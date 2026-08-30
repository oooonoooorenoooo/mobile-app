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

    // Announcements can consist of multiple consecutive Sendspin streams
    // (pre-announce chime + speech). Keep focus briefly between those streams,
    // but always release it after the final audio so external media unducks.
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
        val continuingAnnouncement =
            useTransientDuckingFocus && hasAudioFocus && pendingFocusRelease != null

        cancelPendingFocusRelease()

        // Only reuse focus when a new Sendspin segment arrives during the short
        // post-stream grace period (for example chime -> speech). If focus is still
        // marked as held without that grace period, treat it as stale and abandon it
        // before making a fresh request. This guarantees that every new announcement
        // generates a new MAY_DUCK cycle.
        if (continuingAnnouncement && audioFocusRequest != null) {
            logger.i { "Reusing transient ducking focus for next announcement segment" }
            return true
        }

        if (useTransientDuckingFocus && (hasAudioFocus || audioFocusRequest != null)) {
            logger.i { "Clearing stale transient audio focus before new announcement" }
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
    """            if (written < 0) {
                val errorName = when (written) {
""",
    """            if (written < 0) {
                val errorName = when (written) {
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
                    // Safety watchdog: some Android Auto / Sendspin combinations do
                    // not reliably reach stopRawPcmStream after the final packet.
                    // Reset this timer on every PCM write; once audio really stops,
                    // focus is abandoned and Spotify/etc. must be allowed to unduck.
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
            // This PoC player is used as an announcement endpoint. Keep the MA
            // announcement itself at full local gain; vehicle guidance volume remains
            // independently controlled by Android Auto / the head unit.
            1f
        } else {
            (currentVolume / 100f).coerceIn(0f, 1f)
        }
""",
)

path.write_text(text)
print("Applied PoC announcement-focus patch")
