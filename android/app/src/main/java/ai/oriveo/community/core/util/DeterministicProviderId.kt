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

    
    fun forProvider(kind: ProviderKind, regionId: String): String {
        
        val identityRegionId = if (kind == ProviderKind.SiliconFlow && regionId == "cn") "" else regionId
        return uuidV5(NAMESPACE_BYTES, "${kind.rawValue}|$identityRegionId")
    }

    
    private fun uuidV5(namespace: ByteArray, name: String): String {
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
