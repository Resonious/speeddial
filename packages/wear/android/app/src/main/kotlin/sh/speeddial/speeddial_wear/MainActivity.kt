package sh.speeddial.speeddial_wear

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.MotionEvent
import android.view.ScrollFeedbackProvider
import android.view.ViewConfiguration
import androidx.annotation.RequiresApi
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity(), DataClient.OnDataChangedListener {
    private lateinit var companionChannel: MethodChannel
    private lateinit var rotaryChannel: MethodChannel
    private lateinit var phoneProxy: PhoneProxyBridge
    private var scrollFeedbackProvider: Any? = null
    private var pendingLaunchTarget: Map<String, String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingLaunchTarget = launchTarget(intent)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        companionChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            COMPANION_CHANNEL_NAME,
        )
        companionChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getEndpoints" -> readEndpoints(result)
                "cacheSessions" -> {
                    val payload = call.arguments as? String
                    if (payload == null) {
                        result.error("invalid_arguments", "Missing session payload", null)
                    } else {
                        SessionSnapshotStore.mergeFromWatch(this, payload)
                        result.success(null)
                    }
                }
                "takeLaunchTarget" -> {
                    result.success(pendingLaunchTarget)
                    pendingLaunchTarget = null
                }
                else -> result.notImplemented()
            }
        }
        rotaryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ROTARY_CHANNEL_NAME,
        )
        phoneProxy = PhoneProxyBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val target = launchTarget(intent) ?: return
        pendingLaunchTarget = target
        if (::companionChannel.isInitialized) {
            companionChannel.invokeMethod(
                "launchTarget",
                target,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (pendingLaunchTarget == target) pendingLaunchTarget = null
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) = Unit

                    override fun notImplemented() = Unit
                },
            )
        }
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
                val logicalPixels = -axis * verticalScrollFactor()
                val inputDeviceId = event.deviceId
                val source = event.source
                rotaryChannel.invokeMethod(
                    "scroll",
                    logicalPixels,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            val moved = (result as? Number)?.toFloat() ?: return
                            if (moved == 0f) return
                            val physicalPixels = nonZeroRound(
                                moved * resources.displayMetrics.density,
                            )
                            provideRotaryFeedback(inputDeviceId, source, physicalPixels)
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?,
                        ) = Unit

                        override fun notImplemented() = Unit
                    },
                )
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

    private fun provideRotaryFeedback(inputDeviceId: Int, source: Int, deltaInPixels: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            providePlatformScrollFeedback(inputDeviceId, source, deltaInPixels)
            return
        }
        val feedback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            HapticFeedbackConstants.SEGMENT_FREQUENT_TICK
        } else {
            HapticFeedbackConstants.CLOCK_TICK
        }
        window.decorView.performHapticFeedback(feedback)
    }

    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    private fun providePlatformScrollFeedback(
        inputDeviceId: Int,
        source: Int,
        deltaInPixels: Int,
    ) {
        val provider = scrollFeedbackProvider as? ScrollFeedbackProvider
            ?: ScrollFeedbackProvider.createProvider(window.decorView).also {
                scrollFeedbackProvider = it
            }
        provider.onScrollProgress(
            inputDeviceId,
            source,
            MotionEvent.AXIS_SCROLL,
            deltaInPixels,
        )
    }

    private fun nonZeroRound(value: Float): Int {
        val rounded = value.roundToInt()
        if (rounded != 0) return rounded
        return if (value > 0) 1 else -1
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

    private fun launchTarget(intent: Intent?): Map<String, String>? {
        return when (intent?.getStringExtra(EXTRA_DESTINATION)) {
            DESTINATION_ATTENTION -> mapOf(EXTRA_DESTINATION to DESTINATION_ATTENTION)
            DESTINATION_SESSION -> {
                val daemonId = intent.getStringExtra(EXTRA_DAEMON_ID)
                val projectId = intent.getStringExtra(EXTRA_PROJECT_ID)
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
                if (daemonId.isNullOrBlank() ||
                    projectId.isNullOrBlank() ||
                    sessionId.isNullOrBlank()
                ) {
                    null
                } else {
                    mapOf(
                        EXTRA_DESTINATION to DESTINATION_SESSION,
                        EXTRA_DAEMON_ID to daemonId,
                        EXTRA_PROJECT_ID to projectId,
                        EXTRA_SESSION_ID to sessionId,
                    )
                }
            }
            else -> null
        }
    }

    companion object {
        const val EXTRA_DESTINATION = "wearDestination"
        const val EXTRA_DAEMON_ID = "daemonId"
        const val EXTRA_PROJECT_ID = "projectId"
        const val EXTRA_SESSION_ID = "sessionId"
        const val DESTINATION_ATTENTION = "attention"
        const val DESTINATION_SESSION = "session"
        private const val COMPANION_CHANNEL_NAME = "sh.speeddial/companion"
        private const val ROTARY_CHANNEL_NAME = "sh.speeddial/rotary"
        private const val ENDPOINTS_PATH = "/speeddial/endpoints"
        private const val PAYLOAD_KEY = "payload"
        private const val REVISION_KEY = "revision"
    }
}
