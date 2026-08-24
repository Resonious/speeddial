package sh.speeddial.speeddial_wear

import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), DataClient.OnDataChangedListener {
    private lateinit var channel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getEndpoints" -> readEndpoints(result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        Wearable.getDataClient(this).addListener(this)
    }

    override fun onStop() {
        Wearable.getDataClient(this).removeListener(this)
        super.onStop()
    }

    override fun onDataChanged(events: DataEventBuffer) {
        for (event in events) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            if (event.dataItem.uri.path != ENDPOINTS_PATH) continue
            val payload = DataMapItem.fromDataItem(event.dataItem)
                .dataMap.getString(PAYLOAD_KEY)
            if (payload != null) channel.invokeMethod("endpointsChanged", payload)
        }
    }

    private fun readEndpoints(result: MethodChannel.Result) {
        Wearable.getDataClient(this).dataItems
            .addOnSuccessListener { items ->
                var newestRevision = Long.MIN_VALUE
                var newestPayload: String? = null
                for (item in items) {
                    if (item.uri.path != ENDPOINTS_PATH) continue
                    val dataMap = DataMapItem.fromDataItem(item).dataMap
                    val revision = dataMap.getLong(REVISION_KEY)
                    if (revision >= newestRevision) {
                        newestRevision = revision
                        newestPayload = dataMap.getString(PAYLOAD_KEY)
                    }
                }
                items.release()
                result.success(newestPayload)
            }
            .addOnFailureListener { error ->
                result.error("wear_sync_failed", error.message, null)
            }
    }

    companion object {
        private const val CHANNEL_NAME = "sh.speeddial/companion"
        private const val ENDPOINTS_PATH = "/speeddial/endpoints"
        private const val PAYLOAD_KEY = "payload"
        private const val REVISION_KEY = "revision"
    }
}
