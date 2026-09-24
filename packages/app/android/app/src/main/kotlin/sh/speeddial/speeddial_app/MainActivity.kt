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
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var shareChannel: MethodChannel? = null
    private var shareReady = false
    private var pendingShare: Map<String, String>? = null

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
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeInitial" -> {
                    shareReady = true
                    result.success(pendingShare)
                    pendingShare = null
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
        val shortcutId = shareIntent.getStringExtra(Intent.EXTRA_SHORTCUT_ID)
        val mimeType = shareIntent.type
        thread(name = "speeddial-share-read") {
            val payload = try {
                if (uri == null) throw IllegalArgumentException("No file was shared")
                val name = displayName(uri) ?: uri.lastPathSegment ?: "shared-file"
                val stream = contentResolver.openInputStream(uri)
                    ?: throw IllegalArgumentException("Could not open the shared file")
                val bytes = stream.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (output.size() + read > MAX_SHARE_BYTES) {
                            throw IllegalArgumentException("Shared files must be 8 MiB or smaller")
                        }
                        output.write(buffer, 0, read)
                    }
                    output.toByteArray()
                }
                buildMap {
                    put("name", name)
                    put("mimeType", mimeType ?: contentResolver.getType(uri) ?: "application/octet-stream")
                    put("data", Base64.encodeToString(bytes, Base64.NO_WRAP))
                    if (shortcutId != null) put("shortcutId", shortcutId)
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
        private const val MAX_SHARE_BYTES = 8 * 1024 * 1024
        private const val CHANNEL_NAME = "sh.speeddial/companion"
        private const val ENDPOINTS_PATH = "/speeddial/endpoints"
        private const val SESSIONS_PATH = "/speeddial/sessions"
        private const val PAYLOAD_KEY = "payload"
        private const val REVISION_KEY = "revision"
    }
}
