package sh.speeddial.speeddial_app

import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.database.Cursor
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Base64
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val downloadSaver = DownloadSaver(this)

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!downloadSaver.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private var shareChannel: MethodChannel? = null
    private var shareReady = false
    private var pendingShare: Map<String, Any>? = null
    private val sharedStreams by lazy { SharedStreams.get(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readShareIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sh.speeddial/downloads")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCacheDirectory" -> result.success(cacheDir.absolutePath)
                    "save" -> downloadSaver.save(call.argument<String>("path"), call.argument<String>("name"), result)
                    else -> result.notImplemented()
                }
            }
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeInitial" -> {
                    shareReady = true
                    result.success(pendingShare)
                    pendingShare = null
                }
                "readShared" -> {
                    val streamId = call.argument<String>("streamId")
                    val offset = call.argument<Number>("offset")?.toLong()
                    val length = call.argument<Number>("length")?.toInt()
                    if (streamId == null || offset == null || length == null || length <= 0) {
                        result.error("invalid_arguments", "Missing shared file range", null)
                        return@setMethodCallHandler
                    }
                    thread(name = "speeddial-share-chunk") {
                        try {
                            val bytes = sharedStreams.read(streamId, offset, length)
                            runOnUiThread { result.success(bytes) }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error("share_read", error.message ?: "Could not read the shared file", null)
                            }
                        }
                    }
                }
                "releaseShared" -> {
                    call.argument<String>("streamId")?.let { sharedStreams.release(it) }
                    result.success(null)
                }
                "publishTargets" -> {
                    try {
                        @Suppress("UNCHECKED_CAST")
                        val targets = call.argument<List<Map<String, String>>>("targets")
                            ?: emptyList()
                        publishTargets(targets)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("share_targets", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "publishEndpoints", "publishSessions" -> {
                    val payload = call.argument<String>("payload")
                    val revision = call.argument<Number>("revision")?.toLong()
                    if (payload == null || revision == null) {
                        result.error("invalid_arguments", "Missing companion payload", null)
                        return@setMethodCallHandler
                    }
                    val path = if (call.method == "publishEndpoints") {
                        ENDPOINTS_PATH
                    } else {
                        SESSIONS_PATH
                    }
                    val request = PutDataMapRequest.create(path).apply {
                        dataMap.putString(PAYLOAD_KEY, payload)
                        dataMap.putLong(REVISION_KEY, revision)
                    }.asPutDataRequest().setUrgent()
                    Wearable.getDataClient(this).putDataItem(request)
                        .addOnSuccessListener { result.success(null) }
                        .addOnFailureListener { error ->
                            result.error("wear_sync_failed", error.message, null)
                        }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        shareReady = false
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun readShareIntent(shareIntent: Intent?) {
        if (shareIntent?.action != Intent.ACTION_SEND) return
        // Consume the intent once, so a configuration change does not stage
        // the same attachment a second time.
        shareIntent.action = null
        val uri = if (Build.VERSION.SDK_INT >= 33) {
            shareIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            shareIntent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        } ?: shareIntent.data ?: shareIntent.clipData?.getItemAt(0)?.uri
        val text = shareIntent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: shareIntent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
        val linkText = if (uri?.scheme == "https" || uri?.scheme == "http") uri.toString() else text
        if ((uri == null || uri.scheme == "https" || uri.scheme == "http") && linkText != null) {
            val payload = mapOf("text" to linkText)
            if (shareReady) shareChannel?.invokeMethod("incoming", payload)
            else pendingShare = payload
            return
        }
        val shortcutId = shareIntent.getStringExtra(Intent.EXTRA_SHORTCUT_ID)
        val mimeType = shareIntent.type
        thread(name = "speeddial-share-read") {
            val payload: Map<String, Any> = try {
                if (uri == null) throw IllegalArgumentException("No file was shared")
                val name = displayName(uri) ?: uri.lastPathSegment ?: "shared-file"
                val type = mimeType ?: contentResolver.getType(uri) ?: "application/octet-stream"
                val reportedSize = sizeOf(uri)
                if (reportedSize != null && reportedSize > MAX_SHARE_BYTES) {
                    // Too large to cross the channel at once: Dart reads it in
                    // chunks while it uploads.
                    if (reportedSize > MAX_UPLOAD_BYTES) throw IllegalArgumentException(TOO_LARGE)
                    buildMap {
                        put("name", name)
                        put("mimeType", type)
                        put("size", reportedSize)
                        put("streamId", sharedStreams.register(uri))
                        if (shortcutId != null) put("shortcutId", shortcutId)
                    }
                } else {
                    readShare(uri, name, type, shortcutId)
                }
            } catch (error: Exception) {
                mapOf("error" to (error.message ?: "Could not read the shared file"))
            }
            runOnUiThread {
                if (shareReady) shareChannel?.invokeMethod("incoming", payload)
                else pendingShare = payload
            }
        }
    }

    /**
     * Reads a share of unknown or small size. A small file goes to Dart
     * inline; one that turns out to be large is spilled to the cache and
     * streamed like a file with a reported size.
     */
    private fun readShare(uri: Uri, name: String, type: String, shortcutId: String?): Map<String, Any> {
        val stream = contentResolver.openInputStream(uri)
            ?: throw IllegalArgumentException("Could not open the shared file")
        stream.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (output.size() + read > MAX_SHARE_BYTES) {
                    val spill = File.createTempFile("share-", null, sharedStreams.spillDirectory)
                    try {
                        var size = output.size().toLong() + read
                        FileOutputStream(spill).use { file ->
                            output.writeTo(file)
                            file.write(buffer, 0, read)
                            while (true) {
                                val more = input.read(buffer)
                                if (more < 0) break
                                size += more
                                if (size > MAX_UPLOAD_BYTES) throw IllegalArgumentException(TOO_LARGE)
                                file.write(buffer, 0, more)
                            }
                        }
                        return buildMap {
                            put("name", name)
                            put("mimeType", type)
                            put("size", size)
                            put("streamId", sharedStreams.register(Uri.fromFile(spill), spill))
                            if (shortcutId != null) put("shortcutId", shortcutId)
                        }
                    } catch (error: Exception) {
                        spill.delete()
                        throw error
                    }
                }
                output.write(buffer, 0, read)
            }
            return buildMap {
                put("name", name)
                put("mimeType", type)
                put("data", Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP))
                if (shortcutId != null) put("shortcutId", shortcutId)
            }
        }
    }

    private fun sizeOf(uri: Uri): Long? {
        val cursor: Cursor = contentResolver.query(
            uri, arrayOf(OpenableColumns.SIZE), null, null, null,
        ) ?: return null
        return cursor.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null
        }
    }

    private fun displayName(uri: Uri): String? {
        val cursor: Cursor = contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
        ) ?: return null
        return cursor.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }

    private fun publishTargets(targets: List<Map<String, String>>) {
        if (Build.VERSION.SDK_INT < 29) return
        val manager = getSystemService(ShortcutManager::class.java) ?: return
        val shortcuts = targets.take(manager.maxShortcutCountPerActivity).mapNotNull { target ->
            val id = target["id"] ?: return@mapNotNull null
            val label = target["label"] ?: return@mapNotNull null
            ShortcutInfo.Builder(this, id)
                .setShortLabel(label.take(40))
                .setLongLabel(label)
                .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
                .setIntent(Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    putExtra("targetId", id)
                })
                .setCategories(setOf(PROJECT_CATEGORY))
                .setLongLived(true)
                .build()
        }
        manager.dynamicShortcuts = shortcuts
    }

    companion object {
        private const val SHARE_CHANNEL = "sh.speeddial/share"
        private const val PROJECT_CATEGORY = "sh.speeddial.share.PROJECT"
        /** Inline limit; larger shares stream (PROTOCOL.md `uploads.*`). */
        private const val MAX_SHARE_BYTES = 8 * 1024 * 1024
        private const val MAX_UPLOAD_BYTES = 1024L * 1024 * 1024
        private const val TOO_LARGE = "Shared files must be 1 GiB or smaller"
        private const val CHANNEL_NAME = "sh.speeddial/companion"
        private const val ENDPOINTS_PATH = "/speeddial/endpoints"
        private const val SESSIONS_PATH = "/speeddial/sessions"
        private const val PAYLOAD_KEY = "payload"
        private const val REVISION_KEY = "revision"
    }
}
