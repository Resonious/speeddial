package sh.speeddial.speeddial_wear

import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import org.json.JSONArray
import org.json.JSONObject

internal data class SurfaceSession(
    val daemonId: String,
    val sessionId: String,
    val projectId: String,
    val title: String,
    val status: String,
    val lastActivityAtMs: Long,
    val done: Boolean,
) {
    val key: String
        get() = "$daemonId/$sessionId"
}

internal data class SessionSnapshot(val sessions: List<SurfaceSession>) {
    val inProgressCount: Int
        get() = sessions.count { it.status == "running" || it.status == "waitingPermission" }

    val doneCount: Int
        get() = sessions.count { it.done }

    val recentSessions: List<SurfaceSession>
        get() = sessions.take(3)
}

internal object SessionSnapshotStore {
    private const val PREFERENCES_NAME = "speeddial.session_surfaces.v1"
    private const val PAYLOAD_KEY = "payload"
    private const val REMOTE_REVISION_KEY = "remoteRevision"

    fun read(context: Context): SessionSnapshot {
        val payload = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .getString(PAYLOAD_KEY, null)
        return parse(payload)
    }

    @Synchronized
    fun replaceFromPhone(context: Context, payload: String, revision: Long) {
        val parsed = parseOrNull(payload) ?: return
        val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        if (revision < preferences.getLong(REMOTE_REVISION_KEY, Long.MIN_VALUE)) return
        val encoded = encode(parsed)
        val current = preferences.getString(PAYLOAD_KEY, null)
        preferences.edit()
            .putString(PAYLOAD_KEY, encoded)
            .putLong(REMOTE_REVISION_KEY, revision)
            .apply()
        if (current != encoded) SurfaceUpdateScheduler.request(context)
    }

    @Synchronized
    fun mergeFromWatch(context: Context, payload: String) {
        val incoming = parseOrNull(payload) ?: return
        val byKey = linkedMapOf<String, SurfaceSession>()
        for (session in read(context).sessions) byKey[session.key] = session
        for (session in incoming.sessions) byKey[session.key] = session
        val merged = SessionSnapshot(sort(byKey.values))
        val encoded = encode(merged)
        val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        if (preferences.getString(PAYLOAD_KEY, null) == encoded) return
        preferences.edit().putString(PAYLOAD_KEY, encoded).apply()
        SurfaceUpdateScheduler.request(context)
    }

    private fun parse(payload: String?): SessionSnapshot =
        parseOrNull(payload) ?: SessionSnapshot(emptyList())

    private fun parseOrNull(payload: String?): SessionSnapshot? {
        if (payload.isNullOrBlank()) return null
        return try {
            val root = JSONObject(payload)
            if (root.optInt("version", 0) != 1) return null
            val items = root.optJSONArray("sessions") ?: JSONArray()
            val sessions = ArrayList<SurfaceSession>(items.length())
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                val daemonId = item.optString("daemonId")
                val sessionId = item.optString("sessionId")
                if (daemonId.isBlank() || sessionId.isBlank()) continue
                sessions.add(
                    SurfaceSession(
                        daemonId = daemonId,
                        sessionId = sessionId,
                        projectId = item.optString("projectId"),
                        title = item.optString("title", "Untitled session"),
                        status = item.optString("status", "idle"),
                        lastActivityAtMs = item.optLong("lastActivityAtMs", 0L),
                        done = item.optBoolean("done", false),
                    ),
                )
            }
            SessionSnapshot(sort(sessions))
        } catch (error: Exception) {
            Log.w(TAG, "Ignoring malformed companion session snapshot", error)
            null
        }
    }

    private fun sort(sessions: Collection<SurfaceSession>): List<SurfaceSession> =
        sessions.sortedWith(
            compareByDescending<SurfaceSession> { it.lastActivityAtMs }
                .thenBy { it.sessionId }
                .thenBy { it.daemonId },
        )

    private fun encode(snapshot: SessionSnapshot): String {
        val items = JSONArray()
        for (session in snapshot.sessions) {
            items.put(
                JSONObject()
                    .put("daemonId", session.daemonId)
                    .put("sessionId", session.sessionId)
                    .put("projectId", session.projectId)
                    .put("title", session.title)
                    .put("status", session.status)
                    .put("lastActivityAtMs", session.lastActivityAtMs)
                    .put("done", session.done),
            )
        }
        return JSONObject().put("version", 1).put("sessions", items).toString()
    }

    private const val TAG = "SpeedDialSessions"
}

private object SurfaceUpdateScheduler {
    private const val COMPLICATION_MIN_UPDATE_MS = 5 * 60 * 1000L
    private const val LAST_COMPLICATION_UPDATE_KEY = "lastComplicationUpdate"
    private val handler = Handler(Looper.getMainLooper())
    private var pendingComplicationUpdate = false

    fun request(context: Context) {
        val appContext = context.applicationContext
        TileService.getUpdater(appContext).requestUpdate(RecentSessionsTileService::class.java)
        requestComplication(appContext)
    }

    @Synchronized
    private fun requestComplication(context: Context) {
        val preferences = context.getSharedPreferences(
            "speeddial.session_surfaces.v1",
            Context.MODE_PRIVATE,
        )
        val now = System.currentTimeMillis()
        val elapsed = now - preferences.getLong(LAST_COMPLICATION_UPDATE_KEY, 0L)
        if (elapsed >= COMPLICATION_MIN_UPDATE_MS || elapsed < 0L) {
            pendingComplicationUpdate = false
            preferences.edit().putLong(LAST_COMPLICATION_UPDATE_KEY, now).apply()
            complicationRequester(context).requestUpdateAll()
            return
        }
        if (pendingComplicationUpdate) return
        pendingComplicationUpdate = true
        handler.postDelayed(
            {
                synchronized(this) {
                    pendingComplicationUpdate = false
                    val updatedAt = System.currentTimeMillis()
                    preferences.edit()
                        .putLong(LAST_COMPLICATION_UPDATE_KEY, updatedAt)
                        .apply()
                    complicationRequester(context).requestUpdateAll()
                }
            },
            COMPLICATION_MIN_UPDATE_MS - elapsed,
        )
    }

    private fun complicationRequester(context: Context) =
        ComplicationDataSourceUpdateRequester.create(
            context,
            ComponentName(context, SessionCountsComplicationService::class.java),
        )
}
