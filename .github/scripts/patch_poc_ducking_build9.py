from pathlib import Path

path = Path("composeApp/src/androidMain/kotlin/io/music_assistant/client/player/MediaPlayerController.android.kt")
text = path.read_text()

old = """        val audioAttributes = AudioAttributes.Builder()
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
"""

new = """        val audioAttributes = AudioAttributes.Builder()
            .setUsage(
                if (useTransientDuckingFocus) {
                    AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
                } else {
                    AudioAttributes.USAGE_MEDIA
                },
            )
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
"""

if old not in text:
    raise SystemExit("Build 9 focus attributes block not found")

# Keep the AudioTrack itself as navigation/speech so Android Auto retains its
# separate guidance-volume path. Only the *focus request* is marked non-speech:
# Android's automatic MAY_DUCK handling is intentionally suppressed for speech
# requesters, which is exactly what Build 8 was triggering on Spotify.
text = text.replace(old, new, 1)
path.write_text(text)
print("Applied Build 9 focus attributes: navigation usage + non-speech duck request")
