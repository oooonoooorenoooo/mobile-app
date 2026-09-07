package io.music_assistant.client.services

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import co.touchlab.kermit.Logger
import io.music_assistant.client.MainActivity
import io.music_assistant.client.R
import io.music_assistant.client.data.LocalPlayerController
import io.music_assistant.client.data.MainDataSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.koin.android.ext.android.inject

/**
 * Keeps the app process, server connection and local Sendspin player alive so this
 * custom build can act as a persistent Home Assistant announcement endpoint.
 *
 * This deliberately uses the specialUse foreground-service type instead of
 * mediaPlayback: Android 15+ forbids mediaPlayback FGS startup from BOOT_COMPLETED.
 */
class AnnouncementEndpointService : Service() {
    private val logger = Logger.withTag("AnnouncementEndpointService")
    private val dataSource: MainDataSource by inject()
    private val localPlayerController: LocalPlayerController by inject()
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()

        // Keep the server connection alive independently of actual playback state.
        // MainDataSource owns playbackActive/playbackInactive and toggles it when
        // the local player starts or stops playing.
        dataSource.apiClient.onExternalConsumerActive()

        val notification = createNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // The persistent endpoint must keep the *local Sendspin player* alive, not
        // just the main MA API session. A healthy UI/login therefore no longer masks
        // a dead local player that Home Assistant reports as unavailable.
        //
        // LocalPlayerController.start() is intentionally idempotent: while Sendspin
        // is Ready/Buffering/Synchronized/Connecting/Authenticating/Handshaking or
        // Reconnecting it returns immediately; if the client is null/Idle/Error it
        // recreates it. Running this watchdog also repairs the race where this
        // foreground service starts after the main API session was already authenticated
        // and no new session-state edge occurs to trigger MainDataSource's start().
        serviceScope.launch {
            while (isActive) {
                if (dataSource.apiClient.isReadyForCommands.value) {
                    try {
                        localPlayerController.start()
                    } catch (e: Exception) {
                        logger.w(e) { "Persistent Sendspin watchdog could not start local player" }
                    }
                }
                delay(SENDSPIN_WATCHDOG_INTERVAL_MS)
            }
        }

        logger.i { "Persistent announcement endpoint started" }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        serviceScope.cancel()
        dataSource.apiClient.onExternalConsumerInactive()
        logger.i { "Persistent announcement endpoint stopped" }
        super.onDestroy()
    }

    private fun createNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, MediaNotificationManager.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("Music Assistant")
            .setContentText("HA announcements ready")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    companion object {
        private const val NOTIFICATION_ID = 941
        private const val SENDSPIN_WATCHDOG_INTERVAL_MS = 10_000L

        fun start(context: Context) {
            context.startForegroundService(Intent(context, AnnouncementEndpointService::class.java))
        }
    }
}
