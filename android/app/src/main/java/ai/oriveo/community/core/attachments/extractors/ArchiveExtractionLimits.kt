package ai.oriveo.community.core.attachments.extractors

internal const val MAX_ARCHIVE_ENTRY_COUNT = 4_096
private const val MIN_ARCHIVE_TOTAL_BYTES = 8L * 1024L * 1024L
private const val MAX_ARCHIVE_TOTAL_BYTES = 64L * 1024L * 1024L
private const val MAX_ARCHIVE_ENTRY_BYTES = 16L * 1024L * 1024L

internal fun archiveTotalBudgetBytes(maxHeapBytes: Long = Runtime.getRuntime().maxMemory()): Long =
    (maxHeapBytes / 8L).coerceIn(MIN_ARCHIVE_TOTAL_BYTES, MAX_ARCHIVE_TOTAL_BYTES)

internal fun archiveEntryBudgetBytes(maxHeapBytes: Long = Runtime.getRuntime().maxMemory()): Long =
    minOf(MAX_ARCHIVE_ENTRY_BYTES, archiveTotalBudgetBytes(maxHeapBytes))
