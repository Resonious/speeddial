package sh.speeddial.speeddial_app

import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

    companion object {
        private const val CHANNEL_NAME = "sh.speeddial/companion"
        private const val ENDPOINTS_PATH = "/speeddial/endpoints"
        private const val SESSIONS_PATH = "/speeddial/sessions"
        private const val PAYLOAD_KEY = "payload"
        private const val REVISION_KEY = "revision"
    }
}
