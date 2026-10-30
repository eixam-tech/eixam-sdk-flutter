package dev.eixam.connect.flutter.storage

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabaseCorruptException
import android.system.Os
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/** Private, recording-only storage policy. No host manifest/rules are involved. */
internal class ActivityRecordingStorageBridge(
    messenger: BinaryMessenger,
    prepareDirectory: () -> File,
) {
    private val channel = MethodChannel(messenger, channelName)

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "prepare") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                result.success(prepareDirectory().path)
            } catch (_: Exception) {
                result.error(
                    "E_RECORDING_PERSISTENCE_FAILED",
                    "Recording storage privacy preparation failed.",
                    null,
                )
            }
        }
    }

    fun unregister() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val channelName = "dev.eixam.connect.flutter/activity_recording_storage"
        private val preparationLock = Any()

        fun register(messenger: BinaryMessenger, context: Context): ActivityRecordingStorageBridge {
            val application = context.applicationContext
            return ActivityRecordingStorageBridge(messenger) {
                synchronized(preparationLock) {
                    ActivityRecordingDirectoryPreparer(
                        filesRoot = application.filesDir,
                        noBackupRoot = application.noBackupFilesDir,
                        validateSource = ::validateLegacyDatabase,
                        atomicRename = { source, destination ->
                            // These roots belong to the same Context and app
                            // volume. Never replace atomic rename with a copy.
                            if (Os.stat(source.path).st_dev !=
                                Os.stat(destination.parentFile!!.path).st_dev) {
                                throw IOException("Recording storage volume mismatch")
                            }
                            Os.rename(source.path, destination.path)
                        },
                    ).prepare()
                }
            }
        }

        private fun validateLegacyDatabase(file: File) {
            SQLiteDatabase.openDatabase(
                file.path,
                null,
                SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
                // The default handler can delete corruption evidence.
                DatabaseErrorHandler { throw SQLiteDatabaseCorruptException("Recording source unreadable") },
            ).use { database ->
                if (database.version != 1) throw IOException("Unsupported recording schema")
                database.rawQuery("PRAGMA quick_check", null).use { cursor ->
                    if (!cursor.moveToFirst() || cursor.getString(0) != "ok" || cursor.moveToNext()) {
                        throw IOException("Unreadable recording database")
                    }
                }
                val tables = mutableSetOf<String>()
                database.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'", null).use { cursor ->
                    while (cursor.moveToNext()) tables.add(cursor.getString(0))
                }
                if (!tables.containsAll(setOf("recording_store_metadata", "recordings", "route_points", "route_gaps"))) {
                    throw IOException("Invalid recording schema")
                }
            }
        }
    }
}
