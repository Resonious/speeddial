package sh.speeddial.speeddial_wear

import android.app.PendingIntent
import android.content.Intent
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.DimensionBuilders.wrap
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.LayoutElementBuilders.Box
import androidx.wear.protolayout.LayoutElementBuilders.Column
import androidx.wear.protolayout.LayoutElementBuilders.FontStyle
import androidx.wear.protolayout.LayoutElementBuilders.Layout
import androidx.wear.protolayout.LayoutElementBuilders.Row
import androidx.wear.protolayout.LayoutElementBuilders.Spacer
import androidx.wear.protolayout.LayoutElementBuilders.Text
import androidx.wear.protolayout.ModifiersBuilders.Background
import androidx.wear.protolayout.ModifiersBuilders.Clickable
import androidx.wear.protolayout.ModifiersBuilders.Corner
import androidx.wear.protolayout.ModifiersBuilders.Modifiers
import androidx.wear.protolayout.ModifiersBuilders.Padding
import androidx.wear.protolayout.ResourceBuilders.Resources
import androidx.wear.protolayout.TimelineBuilders.Timeline
import androidx.wear.protolayout.TimelineBuilders.TimelineEntry
import androidx.wear.tiles.RequestBuilders.ResourcesRequest
import androidx.wear.tiles.RequestBuilders.TileRequest
import androidx.wear.tiles.TileBuilders.Tile
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture

class RecentSessionsTileService : TileService() {
    override fun onTileRequest(requestParams: TileRequest): ListenableFuture<Tile> =
        CallbackToFutureAdapter.getFuture { completer ->
            completer.set(buildTile())
            "SpeedDial recent sessions tile"
        }

    override fun onTileResourcesRequest(requestParams: ResourcesRequest): ListenableFuture<Resources> =
        CallbackToFutureAdapter.getFuture { completer ->
            completer.set(Resources.Builder().setVersion(RESOURCES_VERSION).build())
            "SpeedDial recent sessions tile resources"
        }

    private fun buildTile(): Tile {
        val snapshot = SessionSnapshotStore.read(this)
        val root = Box.Builder()
            .setWidth(expand())
            .setHeight(expand())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
            .setModifiers(
                Modifiers.Builder()
                    .setBackground(Background.Builder().setColor(argb(BACKGROUND)).build())
                    .setPadding(
                        Padding.Builder()
                            .setStart(dp(22f))
                            .setEnd(dp(22f))
                            .setTop(dp(14f))
                            .setBottom(dp(14f))
                            .build(),
                    )
                    .build(),
            )
            .addContent(buildContent(snapshot))
            .build()
        val timeline = Timeline.Builder()
            .addTimelineEntry(
                TimelineEntry.Builder()
                    .setLayout(Layout.fromLayoutElement(root))
                    .build(),
            )
            .build()
        return Tile.Builder()
            .setResourcesVersion(RESOURCES_VERSION)
            .setTileTimeline(timeline)
            .setFreshnessIntervalMillis(5 * 60 * 1000L)
            .build()
    }

    private fun buildContent(snapshot: SessionSnapshot): Column {
        val column = Column.Builder()
            .setWidth(expand())
            .setHeight(wrap())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .addContent(
                text(
                    value = "Recent sessions",
                    size = 17f,
                    color = PRIMARY_TEXT,
                    weight = LayoutElementBuilders.FONT_WEIGHT_BOLD,
                ),
            )
            .addContent(Spacer.Builder().setHeight(dp(8f)).build())
        if (snapshot.recentSessions.isEmpty()) {
            column.addContent(
                text(
                    value = "Open SpeedDial to sync sessions",
                    size = 14f,
                    color = SECONDARY_TEXT,
                    maxLines = 2,
                    alignment = LayoutElementBuilders.TEXT_ALIGN_CENTER,
                ),
            )
            return column.build()
        }
        snapshot.recentSessions.forEachIndexed { index, session ->
            if (index > 0) column.addContent(Spacer.Builder().setHeight(dp(5f)).build())
            column.addContent(sessionRow(session))
        }
        return column.build()
    }

    private fun sessionRow(session: SurfaceSession): Row {
        val statusColor = when {
            session.done -> DONE
            session.status == "waitingPermission" -> WAITING
            session.status == "running" -> RUNNING
            session.status == "error" -> ERROR
            else -> IDLE
        }
        val statusMark = if (session.done) "✓" else "●"
        val openApp = PendingIntent.getActivity(
            this,
            session.key.hashCode(),
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Row.Builder()
            .setWidth(expand())
            .setHeight(dp(37f))
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
            .setModifiers(
                Modifiers.Builder()
                    .setBackground(
                        Background.Builder()
                            .setColor(argb(ROW_BACKGROUND))
                            .setCorner(Corner.Builder().setRadius(dp(18f)).build())
                            .build(),
                    )
                    .setPadding(
                        Padding.Builder().setStart(dp(10f)).setEnd(dp(10f)).build(),
                    )
                    .setClickable(
                        Clickable.Builder()
                            .setId("session-${session.key}")
                            .setOnClick(openApp)
                            .build(),
                    )
                    .build(),
            )
            .addContent(text(statusMark, 13f, statusColor))
            .addContent(Spacer.Builder().setWidth(dp(7f)).build())
            .addContent(
                Box.Builder()
                    .setWidth(expand())
                    .setHeight(wrap())
                    .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
                    .addContent(
                        text(
                            value = session.title,
                            size = 14f,
                            color = PRIMARY_TEXT,
                            maxLines = 1,
                        ),
                    )
                    .build(),
            )
            .build()
    }

    private fun text(
        value: String,
        size: Float,
        color: Int,
        weight: Int = LayoutElementBuilders.FONT_WEIGHT_NORMAL,
        maxLines: Int = 1,
        alignment: Int = LayoutElementBuilders.TEXT_ALIGN_START,
    ): Text = Text.Builder()
        .setText(value)
        .setFontStyle(
            FontStyle.Builder()
                .setSize(sp(size))
                .setColor(argb(color))
                .setWeight(weight)
                .build(),
        )
        .setMaxLines(maxLines)
        .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE)
        .setMultilineAlignment(alignment)
        .build()

    companion object {
        private const val RESOURCES_VERSION = "1"
        private const val BACKGROUND = 0xFF000000.toInt()
        private const val ROW_BACKGROUND = 0xFF1F2937.toInt()
        private const val PRIMARY_TEXT = 0xFFF9FAFB.toInt()
        private const val SECONDARY_TEXT = 0xFF9CA3AF.toInt()
        private const val RUNNING = 0xFF58A6FF.toInt()
        private const val WAITING = 0xFFF59E0B.toInt()
        private const val DONE = 0xFF34D399.toInt()
        private const val ERROR = 0xFFF87171.toInt()
        private const val IDLE = 0xFF6B7280.toInt()
    }
}
