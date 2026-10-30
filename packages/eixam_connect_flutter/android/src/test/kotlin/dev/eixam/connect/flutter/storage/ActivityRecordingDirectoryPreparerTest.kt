package dev.eixam.connect.flutter.storage

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ActivityRecordingDirectoryPreparerTest {
    @get:Rule val temporary = TemporaryFolder()
    private val files get() = File(temporary.root, "files")
    private val noBackup get() = File(temporary.root, "no_backup")
    private val old get() = File(files, ActivityRecordingDirectoryPreparer.subtree)
    private val target get() = File(noBackup, ActivityRecordingDirectoryPreparer.subtree)

    private fun preparer(
        validate: (File) -> Unit = { assertEquals("committed", it.readText()) },
        rename: (File, File) -> Unit = { a, b ->
            Files.move(a.toPath(), b.toPath(), StandardCopyOption.ATOMIC_MOVE)
        },
    ) = ActivityRecordingDirectoryPreparer(files, noBackup, validate, rename)

    private fun source(): File {
        assertTrue(old.mkdirs())
        return File(old, "recordings.sqlite").apply { writeText("committed") }
    }

    @Test fun absentSourceCreatesExactNoBackupSubtree() {
        val result = preparer().prepare()
        assertEquals(target.canonicalFile, result)
        assertTrue(result.isDirectory)
        assertFalse(old.exists())
    }

    @Test fun existingDestinationIsIdempotentAndNeverReplaced() {
        val result = preparer().prepare()
        File(result, "recordings.sqlite").writeText("retained finished records")
        assertEquals(result, preparer().prepare())
        assertEquals("retained finished records", File(result, "recordings.sqlite").readText())
    }

    @Test fun closedDirectoryMovePreservesDatabaseSidecarsAndMetadata() {
        source()
        val expected = mapOf("recordings.sqlite" to "committed", "recordings.sqlite-wal" to "wal",
            "recordings.sqlite-shm" to "shm", "store-metadata" to "metadata")
        expected.forEach { (name, value) -> File(old, name).writeText(value) }
        preparer().prepare()
        assertFalse(old.exists())
        expected.forEach { (name, value) -> assertEquals(value, File(target, name).readText()) }
    }

    @Test fun bothPathsConflictWithoutDeletingEitherDatabase() {
        source()
        target.mkdirs()
        File(target, "recordings.sqlite").writeText("different")
        assertThrows(IOException::class.java) { preparer().prepare() }
        assertEquals("committed", File(old, "recordings.sqlite").readText())
        assertEquals("different", File(target, "recordings.sqlite").readText())
    }

    @Test fun corruptSourceIsNotMovedOrReset() {
        source().writeText("corrupt evidence")
        assertThrows(IOException::class.java) {
            preparer(validate = { throw IOException("corrupt") }).prepare()
        }
        assertEquals("corrupt evidence", File(old, "recordings.sqlite").readText())
        assertFalse(target.exists())
    }

    @Test fun interruptionBeforeRenameRetainsSourceAndRetryMigrates() {
        source()
        assertThrows(IOException::class.java) {
            preparer(rename = { _, _ -> throw IOException("before commit") }).prepare()
        }
        assertTrue(old.isDirectory)
        assertFalse(target.exists())
        preparer().prepare()
        assertEquals("committed", File(target, "recordings.sqlite").readText())
    }

    @Test fun interruptionAfterRenameReconcilesUsingIntactDestination() {
        source()
        assertThrows(IOException::class.java) {
            preparer(rename = { a, b ->
                Files.move(a.toPath(), b.toPath(), StandardCopyOption.ATOMIC_MOVE)
                throw IOException("acknowledgement lost")
            }).prepare()
        }
        assertFalse(old.exists())
        assertEquals(target.canonicalFile, preparer().prepare())
        assertEquals("committed", File(target, "recordings.sqlite").readText())
    }

    @Test fun orphanedWalFailsClosedAndPreservesEvidence() {
        old.mkdirs()
        File(old, "recordings.sqlite-wal").writeText("only WAL remains")
        assertThrows(IOException::class.java) { preparer().prepare() }
        assertEquals("only WAL remains", File(old, "recordings.sqlite-wal").readText())
        assertFalse(target.exists())
    }

    @Test fun unavailableNoBackupRootDoesNotFallBackToFiles() {
        source()
        noBackup.writeText("not a directory")
        assertThrows(IOException::class.java) { preparer().prepare() }
        assertEquals("committed", File(old, "recordings.sqlite").readText())
    }

    @Test fun failedAtomicRenameDoesNotCopyOrRemoveTheSource() {
        source()
        assertThrows(IOException::class.java) {
            preparer(rename = { _, _ -> throw IOException("different volume") }).prepare()
        }
        assertEquals("committed", File(old, "recordings.sqlite").readText())
        assertFalse(target.exists())
    }

    @Test fun emptyLegacyDirectoryCanMoveWithoutFabricatingMetadata() {
        old.mkdirs()
        preparer().prepare()
        assertFalse(old.exists())
        assertTrue(target.listFiles()!!.isEmpty())
    }

    @Test fun aliasedDatabaseCannotEscapeNoBackupPolicy() {
        source()
        val outside = File(files, "outside.sqlite").apply { writeText("outside") }
        File(old, "recordings.sqlite").delete()
        Files.createSymbolicLink(File(old, "recordings.sqlite").toPath(), outside.toPath())
        assertThrows(IOException::class.java) { preparer().prepare() }
        assertEquals("outside", outside.readText())
        assertFalse(target.exists())
    }
}
