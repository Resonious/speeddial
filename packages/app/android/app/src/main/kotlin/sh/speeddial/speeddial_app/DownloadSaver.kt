package sh.speeddial.speeddial_app

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

/** Exports a staged file without sending its contents through the Flutter channel. */
class DownloadSaver(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var source: File? = null

    fun save(path: String?, name: String?, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("download_busy", "A save picker is already open", null)
            return
        }
        try {
            val file = File(requireNotNull(path)).canonicalFile
            require(file.isFile && file.path.startsWith(activity.cacheDir.canonicalPath + File.separator)) {
                "Invalid temporary download file"
            }
            pending = result
            source = file
            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, name ?: file.name)
            }, REQUEST_CODE)
        } catch (error: Exception) {
            pending = null
            source = null
            result.error("download_save", error.message, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        val file = source
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            pending = null
            source = null
            result.success(false)
            return true
        }
        thread(name = "speeddial-download-save") {
            try {
                val output = activity.contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("Could not open the destination")
                output.use { sink -> file.inputStream().use { it.copyTo(sink, 64 * 1024) } }
                activity.runOnUiThread {
                    pending = null
                    source = null
                    result.success(true)
                }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    pending = null
                    source = null
                    result.error("download_save", error.message, null)
                }
            }
        }
        return true
    }

    companion object {
        private const val REQUEST_CODE = 8401
    }
}
