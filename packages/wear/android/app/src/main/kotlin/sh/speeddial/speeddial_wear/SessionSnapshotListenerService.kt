package sh.speeddial.speeddial_wear

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.WearableListenerService

class SessionSnapshotListenerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        for (event in events) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            if (event.dataItem.uri.path != SESSIONS_PATH) continue
            val dataMap = DataMapItem.fromDataItem(event.dataItem).dataMap
            val payload = dataMap.getString(PAYLOAD_KEY) ?: continue
            SessionSnapshotStore.replaceFromPhone(
                this,
                payload,
                dataMap.getLong(REVISION_KEY),
            )
        }
    }

    companion object {
        const val SESSIONS_PATH = "/speeddial/sessions"
        private const val PAYLOAD_KEY = "payload"
        private const val REVISION_KEY = "revision"
    }
}
