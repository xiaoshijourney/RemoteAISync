package com.remotaisync.remote_ai_sync

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.remotaisync/downloads")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.error("downloads_unavailable", "Public Downloads storage is unavailable", null)
                    return@setMethodCallHandler
                }

                val requestedName = call.argument<String>("name")
                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                val bytes = call.argument<ByteArray>("bytes")
                if (requestedName.isNullOrBlank() || bytes == null) {
                    result.error("invalid_download", "Missing file name or contents", null)
                    return@setMethodCallHandler
                }
                val fileName = requestedName.substringAfterLast('/').substringAfterLast('\\')
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/RemoteAISync")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
                val uri = contentResolver.insert(collection, values)
                if (uri == null) {
                    result.error("downloads_unavailable", "Could not create a Downloads entry", null)
                    return@setMethodCallHandler
                }
                try {
                    contentResolver.openOutputStream(uri)?.use { output -> output.write(bytes) }
                        ?: throw IllegalStateException("Could not open the Downloads entry")
                    contentResolver.update(uri, ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    }, null, null)
                    result.success("Downloads/RemoteAISync/$fileName")
                } catch (error: Exception) {
                    contentResolver.delete(uri, null, null)
                    result.error("download_write_failed", error.message, null)
                }
            }
    }
}
