package sh.speeddial.speeddial_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/** Opens daemon WebSockets on behalf of a paired watch over the phone's VPN route. */
class WearProxyService : WearableListenerService() {
    private val executor = Executors.newCachedThreadPool()
    private val sessions = ConcurrentHashMap<ChannelClient.Channel, ProxySession>()
    private lateinit var channelClient: ChannelClient
    private lateinit var webSocketClient: OkHttpClient

    override fun onCreate() {
        super.onCreate()
        channelClient = Wearable.getChannelClient(this)
        webSocketClient = OkHttpClient.Builder()
            .pingInterval(30, TimeUnit.SECONDS)
            .build()
        createNotificationChannel()
    }

    override fun onChannelOpened(channel: ChannelClient.Channel) {
        if (channel.path != PROXY_PATH) {
            channelClient.close(channel, ERROR_UNSUPPORTED_PATH)
            return
        }
        val session = ProxySession(channel)
        sessions[channel] = session
        ensureForeground()
        session.start()
    }

    override fun onChannelClosed(
        channel: ChannelClient.Channel,
        closeReason: Int,
        appSpecificErrorCode: Int,
    ) {
        sessions.remove(channel)?.finish(sendTerminal = false)
    }

    override fun onDestroy() {
        for (session in sessions.values) session.finish(sendTerminal = false)
        sessions.clear()
        executor.shutdownNow()
        webSocketClient.dispatcher.executorService.shutdown()
        webSocketClient.connectionPool.evictAll()
        super.onDestroy()
    }

    private fun ensureForeground() {
        val serviceIntent = Intent(this, WearProxyService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (_: RuntimeException) {
            // The Data Layer still keeps this listener bound while the channel
            // is active. Promotion below is best effort on vendor builds that
            // reject starting an already-bound service.
        }
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    private fun sessionFinished(channel: ChannelClient.Channel, session: ProxySession) {
        sessions.remove(channel, session)
        if (sessions.isEmpty()) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "SpeedDial watch connection",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("SpeedDial watch connected")
            .setContentText("Routing daemon traffic through this phone")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private inner class ProxySession(
        private val channel: ChannelClient.Channel,
    ) : WebSocketListener() {
        private val closed = AtomicBoolean(false)
        private val writeLock = Any()
        private var input: DataInputStream? = null
        private var output: DataOutputStream? = null
        private var webSocket: WebSocket? = null

        fun start() {
            executor.execute {
                try {
                    input = DataInputStream(Tasks.await(channelClient.getInputStream(channel)))
                    output = DataOutputStream(Tasks.await(channelClient.getOutputStream(channel)))
                    val (type, url) = readRecord(input!!)
                    if (type != TYPE_OPEN) throw IOException("Missing daemon proxy handshake")
                    val request = Request.Builder().url(url).build()
                    webSocket = webSocketClient.newWebSocket(request, this)
                    readWatchFrames()
                } catch (error: Exception) {
                    finish(error.message ?: "Could not open daemon proxy")
                }
            }
        }

        private fun readWatchFrames() {
            val source = input ?: return
            while (!closed.get()) {
                val (type, payload) = readRecord(source)
                if (type != TYPE_DATA) {
                    throw IOException("Unknown watch proxy record type: $type")
                }
                if (webSocket?.send(payload) != true) {
                    throw IOException("Daemon WebSocket is not connected")
                }
            }
        }

        override fun onOpen(webSocket: WebSocket, response: Response) {
            writeRecord(TYPE_READY, "")
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            writeRecord(TYPE_DATA, text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            finish("Daemon sent an unsupported binary WebSocket frame")
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, reason)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            finish(error = null, terminalType = TYPE_CLOSED)
        }

        override fun onFailure(webSocket: WebSocket, error: Throwable, response: Response?) {
            finish(error.message ?: "Daemon WebSocket failed")
        }

        private fun writeRecord(type: Int, payload: String) {
            if (closed.get()) return
            val bytes = payload.toByteArray(StandardCharsets.UTF_8)
            if (bytes.size + 1 > MAX_RECORD_BYTES) {
                finish("Daemon frame is too large for phone proxy")
                return
            }
            val sink = output ?: return
            try {
                synchronized(writeLock) {
                    sink.writeInt(bytes.size + 1)
                    sink.writeByte(type)
                    sink.write(bytes)
                    sink.flush()
                }
            } catch (error: IOException) {
                finish(error.message ?: "Watch proxy disconnected", sendTerminal = false)
            }
        }

        fun finish(
            error: String? = null,
            terminalType: Int = TYPE_ERROR,
            sendTerminal: Boolean = true,
        ) {
            if (!closed.compareAndSet(false, true)) return
            if (sendTerminal) writeTerminal(terminalType, error ?: "")
            webSocket?.cancel()
            input.closeQuietly()
            output.closeQuietly()
            channelClient.close(channel)
            sessionFinished(channel, this)
        }

        private fun writeTerminal(type: Int, payload: String) {
            val sink = output ?: return
            val bytes = payload.toByteArray(StandardCharsets.UTF_8)
            try {
                synchronized(writeLock) {
                    sink.writeInt(bytes.size + 1)
                    sink.writeByte(type)
                    sink.write(bytes)
                    sink.flush()
                }
            } catch (_: IOException) {
                // The watch already knows the channel is gone.
            }
        }
    }

    companion object {
        private const val PROXY_PATH = "/speeddial/proxy/v1"
        private const val NOTIFICATION_CHANNEL_ID = "speeddial_wear_proxy"
        private const val NOTIFICATION_ID = 7332
        private const val ERROR_UNSUPPORTED_PATH = 1
        private const val MAX_RECORD_BYTES = 32 * 1024 * 1024
        private const val TYPE_OPEN = 1
        private const val TYPE_READY = 2
        private const val TYPE_DATA = 3
        private const val TYPE_ERROR = 4
        private const val TYPE_CLOSED = 5

        private fun readRecord(input: DataInputStream): Pair<Int, String> {
            val length = try {
                input.readInt()
            } catch (error: EOFException) {
                throw IOException("Watch proxy channel closed", error)
            }
            if (length < 1 || length > MAX_RECORD_BYTES) {
                throw IOException("Invalid watch proxy record length: $length")
            }
            val type = input.readUnsignedByte()
            val bytes = ByteArray(length - 1)
            input.readFully(bytes)
            return type to String(bytes, StandardCharsets.UTF_8)
        }

        private fun AutoCloseable?.closeQuietly() {
            try {
                this?.close()
            } catch (_: Exception) {
                // The peer may already have closed the channel.
            }
        }
    }
}
