package ai.oriveo.community.core.util

private const val MIN_BACKUP_MEMORY_BUDGET = 16L * 1024L * 1024L
private const val MAX_BACKUP_MEMORY_BUDGET = 256L * 1024L * 1024L

/**
 * Backup parsing temporarily holds both compressed and expanded data. Keeping each side within a
 * quarter of the app heap prevents low-memory devices from crossing the process limit while still
 * allowing substantially larger backups on modern devices.
 */
fun backupMemoryBudgetBytes(maxHeapBytes: Long = Runtime.getRuntime().maxMemory()): Long =
    (maxHeapBytes / 4L).coerceIn(MIN_BACKUP_MEMORY_BUDGET, MAX_BACKUP_MEMORY_BUDGET)
