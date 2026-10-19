package ai.oriveo.community.core.util

import ai.oriveo.community.core.model.ProviderKind
import java.security.MessageDigest

object DeterministicProviderId {

    private val NAMESPACE_BYTES: ByteArray = byteArrayOf(
        0x9A.toByte(), 0x11.toByte(), 0x95.toByte(), 0xDE.toByte(),
        0x3A.toByte(), 0xF9.toByte(), 0x58.toByte(), 0x88.toByte(),
        0xAB.toByte(), 0xC8.toByte(), 0xB8.toByte(), 0x17.toByte(),
        0x7C.toByte(), 0x45.toByte(), 0x8C.toByte(), 0x07.toByte(),
    )

    /**
     * Derives the deterministic Provider id (a valid upper-case v5 UUID) from (kind, regionId).
     *
     * @param kind the official ProviderKind (rawValue is the canonical string).
     * @param regionId the region option id; pass an empty string for a provider without a region.
     */
    fun forProvider(kind: ProviderKind, regionId: String): String {
        // The China region was derived with an empty region before the region selector existed, so it must keep hitting the old doc id.
        val identityRegionId = if (kind == ProviderKind.SiliconFlow && regionId == "cn") "" else regionId
        return uuidV5(NAMESPACE_BYTES, "${kind.rawValue}|$identityRegionId")
    }

    /** One entry of the identity table: only the region id and address, no display name. */
    data class IdentityRegion(val id: String, val baseURL: String)

    /**
     * Frozen identity table: the region segment of the deterministic id consults only this table, not metadata nor the selectable regions
     * (Qwen us is no longer selectable but remains in the table, so ids of existing `qwen|us` records are unchanged). It equals the fixture
     * `endpoint-source.v1.json` `identityRegions` verbatim, pinned by EndpointSourceContractTest;
     * providers outside the table always have an empty region segment. An entry is added only when a fifth provider needs an identity region (via a release).
     */
    val identityRegions: Map<ProviderKind, List<IdentityRegion>> = mapOf(
        ProviderKind.MiniMax to listOf(
            IdentityRegion("global", "https://api.minimax.io/v1"),
            IdentityRegion("cn", "https://api.minimaxi.com/v1"),
        ),
        ProviderKind.Qwen to listOf(
            IdentityRegion("sg", "https://dashscope-intl.aliyuncs.com"),
            IdentityRegion("bj", "https://dashscope.aliyuncs.com"),
            IdentityRegion("hk", "https://cn-hongkong.dashscope.aliyuncs.com"),
            IdentityRegion("us", "https://dashscope-us.aliyuncs.com"),
        ),
        ProviderKind.Moonshot to listOf(
            IdentityRegion("intl", "https://api.moonshot.ai/v1"),
            IdentityRegion("cn", "https://api.moonshot.cn/v1"),
        ),
        ProviderKind.SiliconFlow to listOf(
            IdentityRegion("cn", "https://api.siliconflow.cn/v1"),
            IdentityRegion("intl", "https://api.siliconflow.com/v1"),
        ),
    )

    /**
     * Region segment of the deterministic id (before the SiliconFlow cn fold): a `region:<id>` source whose id is in the identity table takes priority,
     * otherwise the identity table is looked up by the literal address (empty or unmatched falls to the first entry, same as before sources existed); providers outside the table get an empty string.
     * Both registration and migration grouping go through here.
     */
    fun identityRegionId(kind: ProviderKind, baseUrlText: String?, endpointSource: String?): String {
        val table = identityRegions[kind].orEmpty()
        if (table.isEmpty()) return ""
        ai.oriveo.community.core.provider.transport.OfficialEndpointSource.regionId(endpointSource)
            ?.takeIf { id -> table.any { it.id == id } }
            ?.let { return it }
        return kind.resolveRegionOption(baseUrlText)?.id ?: ""
    }

    /**
     * Hand-written UUIDv5: SHA-1(NS_bytes ++ name_utf8), first 16 bytes, version=5 / variant=RFC4122,
     * formatted as 8-4-4-4-12 hex and upper-cased as a whole (round-trips with normalizeUuid on every platform).
     */
    internal fun uuidV5(namespace: ByteArray, name: String): String {
        val md = MessageDigest.getInstance("SHA-1")
        md.update(namespace)
        md.update(name.toByteArray(Charsets.UTF_8))

        val hash = md.digest()

        val bytes = hash.copyOf(16)

        bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x50).toByte()

        bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte()

        val hex = StringBuilder(36)
        for (i in 0 until 16) {
            if (i == 4 || i == 6 || i == 8 || i == 10) hex.append('-')
            hex.append("%02X".format(bytes[i].toInt() and 0xFF))
        }
        return hex.toString()
    }
}
