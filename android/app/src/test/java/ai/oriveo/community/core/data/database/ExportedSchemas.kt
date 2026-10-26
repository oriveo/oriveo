package ai.oriveo.community.core.data.database

import java.io.File

/** The latest exported Room schema version (the structure a fresh install gets). Derived from the schemas directory, so a version bump needs no manual test edit. */
internal val LATEST_SCHEMA_VERSION: Int by lazy {
    File("schemas/${OriveoDatabase::class.java.canonicalName}")
        .listFiles { file -> file.extension == "json" }
        .orEmpty()
        .mapNotNull { it.nameWithoutExtension.toIntOrNull() }
        .maxOrNull()
        ?: error("no exported Room schema in the schemas directory")
}
