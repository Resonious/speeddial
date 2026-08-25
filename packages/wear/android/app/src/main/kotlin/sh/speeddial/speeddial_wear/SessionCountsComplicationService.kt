package sh.speeddial.speeddial_wear

import android.app.PendingIntent
import android.content.Intent
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.LongTextComplicationData
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.data.WeightedElementsComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService

class SessionCountsComplicationService : SuspendingComplicationDataSourceService() {
    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        val snapshot = SessionSnapshotStore.read(this)
        return buildData(request.complicationType, snapshot.inProgressCount, snapshot.doneCount)
    }

    override fun getPreviewData(type: ComplicationType): ComplicationData? =
        buildData(type, inProgress = 2, done = 1)

    private fun buildData(
        type: ComplicationType,
        inProgress: Int,
        done: Int,
    ): ComplicationData? {
        val description = text("$inProgress in progress, $done done")
        val tapAction = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return when (type) {
            ComplicationType.SHORT_TEXT -> ShortTextComplicationData.Builder(
                text("$inProgress▶ $done✓"),
                description,
            ).setTapAction(tapAction).build()

            ComplicationType.LONG_TEXT -> LongTextComplicationData.Builder(
                text("$inProgress in progress · $done done"),
                description,
            ).setTapAction(tapAction).build()

            ComplicationType.WEIGHTED_ELEMENTS -> {
                val elements = buildList {
                    if (done > 0) {
                        add(
                            WeightedElementsComplicationData.Element(
                                done.toFloat(),
                                DONE_COLOR,
                            ),
                        )
                    }
                    if (inProgress > 0) {
                        add(
                            WeightedElementsComplicationData.Element(
                                inProgress.toFloat(),
                                IN_PROGRESS_COLOR,
                            ),
                        )
                    }
                    if (isEmpty()) {
                        add(WeightedElementsComplicationData.Element(1f, EMPTY_COLOR))
                    }
                }
                WeightedElementsComplicationData.Builder(elements, description)
                    .setTitle(text("Sessions"))
                    .setText(text("$done✓ $inProgress▶"))
                    .setElementBackgroundColor(EMPTY_COLOR)
                    .setTapAction(tapAction)
                    .build()
            }

            else -> null
        }
    }

    private fun text(value: String) = PlainComplicationText.Builder(value).build()

    private companion object {
        const val DONE_COLOR = 0xFF34D399.toInt()
        const val IN_PROGRESS_COLOR = 0xFF58A6FF.toInt()
        const val EMPTY_COLOR = 0xFF374151.toInt()
    }
}
