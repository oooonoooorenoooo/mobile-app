package io.music_assistant.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import co.touchlab.kermit.Logger
import io.music_assistant.client.services.AnnouncementEndpointService

/** Starts the persistent announcement endpoint after a normal device boot or app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> {
                Logger.withTag("BootReceiver").i { "Starting announcement endpoint after ${intent.action}" }
                runCatching { AnnouncementEndpointService.start(context) }
                    .onFailure { error ->
                        Logger.withTag("BootReceiver").e(error) {
                            "Could not start announcement endpoint"
                        }
                    }
            }
        }
    }
}
