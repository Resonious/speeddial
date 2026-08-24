package sh.speeddial.speeddial_wear

import android.os.Build
import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), DataClient.OnDataChangedListener {
    private lateinit var companionChannel: MethodChannel
    private lateinit var rotaryChannel: MethodChannel
    private lateinit var phoneProxy: PhoneProxyBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        companionChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            COMPANION_CHANNEL_NAME,
        )
        companionChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getEndpoints" -> readEndpoints(result)
                else -> result.notImplemented()
            }
        }
        rotaryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ROTARY_CHANNEL_NAME,
        )
        phoneProxy = PhoneProxyBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (
            event.actionMasked == MotionEvent.ACTION_SCROLL &&
            event.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)
        ) {
            val axis = event.getAxisValue(MotionEvent.AXIS_SCROLL)
            if (axis != 0f && ::rotaryChannel.isInitialized) {
                // Match Android and Flutter's mouse-wheel direction and scale
                // the device-specific encoder units into logical scroll pixels.
                rotaryChannel.invokeMethod("scroll", -axis * verticalScrollFactor())
                return true
            }
        }
        return super.onGenericMotionEvent(event)
    }

    override fun onStart() {
        super.onStart()
        Wearable.getDataClient(this).addListener(this)
    }

    override fun onStop() {
        Wearable.getDataClient(this).removeListener(this)
        super.onStop()
    }

    override fun onDestroy() {
        if (::phoneProxy.isInitialized) phoneProxy.dispose()
        super.onDestroy()
    }

    override fun onDataChanged(events: DataEventBuffer) {
        for (event in events) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            if (event.dataItem.uri.path != ENDPOINTS_PATH) continue
            val payload = DataMapItem.fromDataItem(event.dataItem)
                .dataMap.getString(PAYLOAD_KEY)
            if (payload != null) companionChannel.invokeMethod("endpointsChanged", payload)
        }
    }

    private fun verticalScrollFactor(): Float {
        val physicalPixels = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ViewConfiguration.get(this).scaledVerticalScrollFactor
        } else {
            48f * resources.displayMetrics.density
        }
        return physicalPixels / resources.displayMetrics.density
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
        private const val COMPANION_CHANNEL_NAME = "sh.speeddial/companion"
        private const val ROTARY_CHANNEL_NAME = "sh.speeddial/rotary"
        private const val ENDPOINTS_PATH = "/speeddial/endpoints"
        private const val PAYLOAD_KEY = "payload"
        private const val REVISION_KEY = "revision"
    }
}
