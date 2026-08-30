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
import io.music_assistant.client.data.MainDataSource
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

    override fun onCreate() {
        super.onCreate()

        // Resolving MainDataSource creates the local-player stack. Mark the connection as
        // active so the normal background-disconnect policy does not tear Sendspin down.
        dataSource.apiClient.onPlaybackActive()

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

        logger.i { "Persistent announcement endpoint started" }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        dataSource.apiClient.onPlaybackInactive()
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

        fun start(context: Context) {
            context.startForegroundService(Intent(context, AnnouncementEndpointService::class.java))
        }
    }
}
