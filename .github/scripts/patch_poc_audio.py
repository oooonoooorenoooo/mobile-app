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

    // Treat chime + speech as one logical announcement focus session. The focus
    // watchdog is reset by every PCM write and releases focus only after audio has
    // actually gone quiet. This avoids tearing down focus between Sendspin segments.
    private val focusReleaseHandler = Handler(Looper.getMainLooper())
    private var pendingFocusRelease: Runnable? = null
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

        if (continuingAnnouncement && audioFocusRequest != null) {
            logger.i { "Continuing current announcement focus session" }
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
            // Important for Build 9: CONTENT_TYPE_SPEECH suppresses Android's
            // automatic MAY_DUCK attenuation of the current media app. Keep the
            // navigation usage, but make the focus request non-speech so Spotify
            // remains playing and Android can actually lower it.
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
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

    private fun scheduleAudioFocusRelease(delayMs: Long = focusWriteWatchdogMs) {
        cancelPendingFocusRelease()
        val release = Runnable {
            pendingFocusRelease = null
            logger.i { "Announcement PCM idle timeout ended — releasing transient audio focus" }
            releaseAudioFocus()
        }
        pendingFocusRelease = release
        focusReleaseHandler.postDelayed(release, delayMs)
        logger.d { "Transient ducking focus release watchdog reset to ${delayMs}ms" }
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
                    scheduleAudioFocusRelease()
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
            logger.i { "Sendspin segment ended — waiting for PCM idle timeout before releasing focus" }
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
            1f
        } else {
            (currentVolume / 100f).coerceIn(0f, 1f)
        }
""",
)

path.write_text(text)
print("Applied PoC announcement-focus patch (Build 9 auto-duck focus attributes)")
