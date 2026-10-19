package dev.eixam.connect.flutter.storage

import java.io.File
import java.io.IOException

/** Closed-store migration only. The SDK's single-isolate writer lease owns IO.
 * Rename the entire directory; never copy a database or discard WAL/SHM/metadata.
 * An interrupted atomic rename leaves exactly the source or destination intact.
 */
internal class ActivityRecordingDirectoryPreparer(
    private val filesRoot: File,
    private val noBackupRoot: File,
    private val validateSource: (File) -> Unit,
    private val atomicRename: (File, File) -> Unit,
) {
    fun prepare(): File {
        val source = child(filesRoot, subtree)
        val destination = child(noBackupRoot, subtree)
        if (source == destination) throw IOException("Invalid storage roots")
        ensureDirectory(noBackupRoot.canonicalFile)
        ensureDirectory(destination.parentFile!!)
        if (source.exists()) {
            // Even an apparently empty conflicting directory is evidence. Never
            // merge, replace, or delete either tree during ordinary preparation.
            if (destination.exists()) throw IOException("Conflicting recording stores")
            verifyDirectory(source)
            val database = File(source, databaseName)
            if (database.exists()) {
                if (!database.isFile) throw IOException("Invalid recording database")
                validateSource(database)
            } else if (listOf("-wal", "-shm", "-journal").any {
                    File(source, databaseName + it).exists()
                }) {
                throw IOException("Orphaned SQLite sidecars")
            }
            atomicRename(source, destination)
            if (source.exists() || !destination.isDirectory) {
                throw IOException("Migration did not complete")
            }
        }
        ensureDirectory(destination)
        verifyDirectory(destination)
        return destination
    }

    private fun child(root: File, relative: String): File {
        val canonicalRoot = root.canonicalFile
        val file = File(canonicalRoot, relative).absoluteFile
        if (file.canonicalFile != file) throw IOException("Aliased recording path")
        return file
    }

    private fun ensureDirectory(directory: File) {
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw IOException("Cannot prepare recording directory")
        }
    }

    private fun verifyDirectory(directory: File) {
        if (!directory.isDirectory) throw IOException("Invalid recording directory")
        val children = directory.listFiles() ?: throw IOException("Unreadable recording directory")
        if (children.any { it.canonicalFile != it.absoluteFile }) {
            throw IOException("Aliased recording artifact")
        }
    }

    companion object {
        const val subtree = "eixam/activity_recordings"
        const val databaseName = "recordings.sqlite"
    }
}
