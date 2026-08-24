package sh.speeddial.speeddial_wear

import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Bridges Flutter daemon text frames onto a bidirectional Wear Data Layer channel. */
class PhoneProxyBridge(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) {
    private val methodChannel = MethodChannel(messenger, CHANNEL_NAME)
    private val channelClient = Wearable.getChannelClient(activity)
    private val executor = Executors.newCachedThreadPool()
    private val connections = ConcurrentHashMap<String, WatchProxyConnection>()
    private val opening = ConcurrentHashMap.newKeySet<String>()

    init {
        methodChannel.setMethodCallHandler(::handleMethodCall)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openProxy" -> openProxy(call, result)
            "sendProxyFrame" -> sendFrame(call, result)
            "closeProxy" -> closeProxy(call, result)
            else -> result.notImplemented()
        }
    }

    private fun openProxy(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val url = call.argument<String>("url")
        if (id == null || url == null) {
            result.error("invalid_arguments", "Missing proxy id or daemon URL", null)
            return
        }
        if (connections.containsKey(id) || !opening.add(id)) {
            result.error("duplicate_proxy", "Proxy connection already exists", null)
            return
        }
        Wearable.getNodeClient(activity).connectedNodes
            .addOnSuccessListener { nodes ->
                val phone = nodes.sortedByDescending { it.isNearby }.firstOrNull()
                if (phone == null) {
                    opening.remove(id)
                    result.error("phone_unavailable", "Paired phone is not connected", null)
                    return@addOnSuccessListener
                }
                channelClient.openChannel(phone.id, PROXY_PATH)
                    .addOnSuccessListener { wearChannel ->
                        channelClient.getInputStream(wearChannel)
                            .addOnSuccessListener { input ->
                                channelClient.getOutputStream(wearChannel)
                                    .addOnSuccessListener { output ->
                                        opening.remove(id)
                                        val connection = WatchProxyConnection(
                                            id = id,
                                            channel = wearChannel,
                                            input = DataInputStream(input),
                                            output = DataOutputStream(output),
                                            openResult = result,
                                        )
                                        connections[id] = connection
                                        connection.start(url)
                                    }
                                    .addOnFailureListener { error ->
                                        opening.remove(id)
                                        input.closeQuietly()
                                        channelClient.close(wearChannel)
                                        result.error(
                                            "phone_proxy_failed",
                                            error.message ?: "Could not open proxy output",
                                            null,
                                        )
                                    }
                            }
                            .addOnFailureListener { error ->
                                opening.remove(id)
                                channelClient.close(wearChannel)
                                result.error(
                                    "phone_proxy_failed",
                                    error.message ?: "Could not open proxy input",
                                    null,
                                )
                            }
                    }
                    .addOnFailureListener { error ->
                        opening.remove(id)
                        result.error(
                            "phone_unavailable",
                            error.message ?: "Could not connect to paired phone",
                            null,
                        )
                    }
            }
            .addOnFailureListener { error ->
                opening.remove(id)
                result.error(
                    "phone_unavailable",
                    error.message ?: "Could not find paired phone",
                    null,
                )
            }
    }

    private fun sendFrame(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val payload = call.argument<String>("payload")
        val connection = if (id == null) null else connections[id]
        if (connection == null || payload == null) {
            result.error("proxy_not_connected", "Phone proxy is not connected", null)
            return
        }
        connection.send(payload, result)
    }

    private fun closeProxy(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val connection = if (id == null) null else connections.remove(id)
        if (connection == null) {
            result.success(null)
            return
        }
        connection.close(notifyFlutter = false)
        result.success(null)
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        for (connection in connections.values) connection.close(notifyFlutter = false)
        connections.clear()
        opening.clear()
        executor.shutdownNow()
    }

    private inner class WatchProxyConnection(
        private val id: String,
        private val channel: ChannelClient.Channel,
        private val input: DataInputStream,
        private val output: DataOutputStream,
        private val openResult: MethodChannel.Result,
    ) {
        private val closed = AtomicBoolean(false)
        private val ready = AtomicBoolean(false)
        private val writeLock = Any()

        fun start(url: String) {
            executor.execute {
                try {
                    writeRecord(TYPE_OPEN, url)
                    readLoop()
                } catch (error: Exception) {
                    close(error.message ?: "Phone proxy disconnected")
                }
            }
        }

        fun send(payload: String, result: MethodChannel.Result) {
            executor.execute {
                try {
                    writeRecord(TYPE_DATA, payload)
                    post { result.success(null) }
                } catch (error: Exception) {
                    post {
                        result.error(
                            "phone_proxy_failed",
                            error.message ?: "Could not send daemon frame",
                            null,
                        )
                    }
                    close(error.message ?: "Phone proxy disconnected")
                }
            }
        }

        private fun readLoop() {
            while (!closed.get()) {
                val (type, payload) = readRecord(input)
                when (type) {
                    TYPE_READY -> {
                        if (ready.compareAndSet(false, true)) {
                            post { openResult.success(null) }
                        }
                    }
                    TYPE_DATA -> post {
                        methodChannel.invokeMethod(
                            "proxyFrame",
                            mapOf("id" to id, "payload" to payload),
                        )
                    }
                    TYPE_ERROR -> {
                        close(payload.ifEmpty { "Phone could not reach daemon" })
                        return
                    }
                    TYPE_CLOSED -> {
                        close(error = null)
                        return
                    }
                    else -> throw IOException("Unknown phone proxy record type: $type")
                }
            }
        }

        private fun writeRecord(type: Int, payload: String) {
            val bytes = payload.toByteArray(StandardCharsets.UTF_8)
            if (bytes.size + 1 > MAX_RECORD_BYTES) {
                throw IOException("Daemon frame is too large for phone proxy")
            }
            synchronized(writeLock) {
                output.writeInt(bytes.size + 1)
                output.writeByte(type)
                output.write(bytes)
                output.flush()
            }
        }

        fun close(error: String? = null, notifyFlutter: Boolean = true) {
            if (!closed.compareAndSet(false, true)) return
            connections.remove(id, this)
            input.closeQuietly()
            output.closeQuietly()
            channelClient.close(channel)
            post {
                if (!ready.get()) {
                    ready.set(true)
                    openResult.error(
                        "phone_proxy_failed",
                        error ?: "Phone proxy closed before connecting",
                        null,
                    )
                } else if (notifyFlutter) {
                    methodChannel.invokeMethod(
                        "proxyClosed",
                        mapOf("id" to id, "error" to error),
                    )
                }
            }
        }
    }

    private fun post(callback: () -> Unit) = activity.runOnUiThread(callback)

    companion object {
        private const val CHANNEL_NAME = "sh.speeddial/phone_proxy"
        private const val PROXY_PATH = "/speeddial/proxy/v1"
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
                throw IOException("Phone proxy channel closed", error)
            }
            if (length < 1 || length > MAX_RECORD_BYTES) {
                throw IOException("Invalid phone proxy record length: $length")
            }
            val type = input.readUnsignedByte()
            val bytes = ByteArray(length - 1)
            input.readFully(bytes)
            return type to String(bytes, StandardCharsets.UTF_8)
        }

        private fun AutoCloseable.closeQuietly() {
            try {
                close()
            } catch (_: Exception) {
                // The peer may already have closed the channel.
            }
        }
    }
}
