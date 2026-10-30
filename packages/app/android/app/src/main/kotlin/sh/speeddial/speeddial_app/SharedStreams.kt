package sh.speeddial.speeddial_app

import android.content.Context
import android.net.Uri
import java.io.File
import java.io.InputStream
import java.util.UUID

/**
 * Shared files too large to hand to Dart in one message. Dart reads them in
 * order, chunk by chunk, while it uploads them (see ShareStore), and releases
 * them once sent or dismissed. One instance per process, so a recreated
 * activity keeps the streams Dart still holds ids for.
 */
class SharedStreams private constructor(private val context: Context) {
    private class Entry(val uri: Uri, val spill: File?) {
        var input: InputStream? = null
        var position = 0L
    }

    private val entries = HashMap<String, Entry>()

    /** Directory for shares whose size the provider did not report. */
    val spillDirectory: File = File(context.cacheDir, "shared").apply {
        // Spilled files from an earlier process have no owner any more.
        deleteRecursively()
        mkdirs()
    }

    @Synchronized
    fun register(uri: Uri, spill: File? = null): String {
        val id = UUID.randomUUID().toString()
        entries[id] = Entry(uri, spill)
        return id
    }

    /** Reads up to [length] bytes at [offset]. Blocks; call off the main thread. */
    @Synchronized
    fun read(id: String, offset: Long, length: Int): ByteArray {
        val entry = entries[id] ?: throw IllegalArgumentException("The shared file is no longer available")
        var input = entry.input
        if (input == null || entry.position != offset) {
            // First read, or a retry from an earlier offset: start over.
            input?.close()
            input = context.contentResolver.openInputStream(entry.uri)
                ?: throw IllegalStateException("Could not open the shared file")
            entry.input = input
            entry.position = 0
            while (entry.position < offset) {
                val skipped = input.skip(offset - entry.position)
                if (skipped > 0) {
                    entry.position += skipped
                } else if (input.read() < 0) {
                    break
                } else {
                    entry.position += 1
                }
            }
            if (entry.position != offset) return ByteArray(0)
        }
        val buffer = ByteArray(length)
        var filled = 0
        while (filled < length) {
            val read = input.read(buffer, filled, length - filled)
            if (read < 0) break
            filled += read
        }
        entry.position += filled
        return if (filled == length) buffer else buffer.copyOf(filled)
    }

    @Synchronized
    fun release(id: String) {
        val entry = entries.remove(id) ?: return
        entry.input?.close()
        entry.spill?.delete()
    }

    companion object {
        @Volatile
        private var instance: SharedStreams? = null

        fun get(context: Context): SharedStreams =
            instance ?: synchronized(this) {
                instance ?: SharedStreams(context.applicationContext).also { instance = it }
            }
    }
}
