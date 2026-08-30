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

    // MA announcements can consist of several consecutive Sendspin streams
    // (pre-announce chime + speech). Keep focus alive briefly between streams so
    // Android does not unduck/reduck the external app between those segments.
    private val focusReleaseHandler = Handler(Looper.getMainLooper())
    private var pendingFocusRelease: Runnable? = null
    private val focusReleaseDelayMs = 900L
""",
)

replace_once(
    """    private fun requestAudioFocus(): Boolean {
        val focusGain = if (useTransientDuckingFocus) {
""",
    """    private fun requestAudioFocus(): Boolean {
        cancelPendingFocusRelease()

        // A new segment of the same announcement arrived while we still own the
        // transient focus. Reuse it instead of abandoning and immediately requesting
        // again; that caused audible gaps and incomplete pre-announce chimes.
        if (useTransientDuckingFocus && hasAudioFocus && audioFocusRequest != null) {
            logger.i { "Reusing transient ducking focus for next announcement segment" }
            return true
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

    private fun scheduleAudioFocusRelease() {
        cancelPendingFocusRelease()
        val release = Runnable {
            pendingFocusRelease = null
            logger.i { "Announcement grace period ended — releasing transient audio focus" }
            releaseAudioFocus()
        }
        pendingFocusRelease = release
        focusReleaseHandler.postDelayed(release, focusReleaseDelayMs)
        logger.i { "Announcement segment ended — keeping ducking focus for ${focusReleaseDelayMs}ms" }
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
    """        if (useTransientDuckingFocus) {
            logger.i { "PoC transient stream ended — releasing audio focus so external media can unduck" }
            releaseAudioFocus()
        }
""",
    """        if (useTransientDuckingFocus) {
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
            // This PoC player is used as an announcement endpoint. Do not attenuate
            // the announcement with the persisted local-player volume while Android
            // is already ducking the external media app.
            1f
        } else {
            (currentVolume / 100f).coerceIn(0f, 1f)
        }
""",
)

path.write_text(text)
print("Applied PoC announcement-focus patch")
