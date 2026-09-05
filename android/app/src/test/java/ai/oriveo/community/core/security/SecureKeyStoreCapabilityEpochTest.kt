package ai.oriveo.community.core.security

import android.content.Context
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SecureKeyStoreCapabilityEpochTest {
    private val context = mockk<Context> {
        every { applicationContext } returns this@mockk
    }

    @Test
    fun `connection semantic change advances only connection generation`() {
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        val before = store.capabilityEpochs("account-a", "provider-a")
        val observationBefore = CapabilityEvidenceObservationBridge.revision.value

        val after = store.advanceCapabilityConnectionGeneration("account-a", "provider-a")

        assertNotEquals(before.connectionGeneration, after.connectionGeneration)
        assertEquals(before.credentialEpoch, after.credentialEpoch)
        assertEquals(after, store.capabilityEpochs("account-a", "provider-a"))
        assertEquals(observationBefore + 1, CapabilityEvidenceObservationBridge.revision.value)
    }

    @Test
    fun `credential write advances only credential epoch`() {
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        val before = store.capabilityEpochs("account-a", "provider-a")
        val observationBefore = CapabilityEvidenceObservationBridge.revision.value

        store.saveApiKey("account-a", "provider-a", "sk-new")
        val after = store.capabilityEpochs("account-a", "provider-a")

        assertEquals(before.connectionGeneration, after.connectionGeneration)
        assertNotEquals(before.credentialEpoch, after.credentialEpoch)
        assertEquals(observationBefore + 1, CapabilityEvidenceObservationBridge.revision.value)
    }

    @Test
    fun `persisting unchanged credential does not advance capability epochs`() {
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        store.saveApiKey("account-a", "provider-a", "sk-same")
        val afterFirstWrite = store.capabilityEpochs("account-a", "provider-a")
        val observationBeforeRepeat = CapabilityEvidenceObservationBridge.revision.value

        store.saveApiKey("account-a", "provider-a", "sk-same")
        val afterRepeatWrite = store.capabilityEpochs("account-a", "provider-a")

        assertEquals(afterFirstWrite.connectionGeneration, afterRepeatWrite.connectionGeneration)
        assertEquals(afterFirstWrite.credentialEpoch, afterRepeatWrite.credentialEpoch)
        assertEquals(observationBeforeRepeat, CapabilityEvidenceObservationBridge.revision.value)
    }

    @Test
    fun `saving empty or blank credential when absent does not advance epoch`() {
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        val before = store.capabilityEpochs("account-a", "provider-a")
        val observationBefore = CapabilityEvidenceObservationBridge.revision.value

        store.saveApiKey("account-a", "provider-a", "")
        store.saveApiKey("account-a", "provider-a", "   ")

        assertEquals(before, store.capabilityEpochs("account-a", "provider-a"))
        assertNull(store.getApiKey("account-a", "provider-a"))
        assertEquals(observationBefore, CapabilityEvidenceObservationBridge.revision.value)
    }

    @Test
    fun `saving empty credential deletes existing material and advances epoch once`() {
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        store.saveApiKey("account-a", "provider-a", "sk-existing")
        val beforeDelete = store.capabilityEpochs("account-a", "provider-a")
        val observationBeforeDelete = CapabilityEvidenceObservationBridge.revision.value

        store.saveApiKey("account-a", "provider-a", "")
        val afterDelete = store.capabilityEpochs("account-a", "provider-a")

        assertEquals(beforeDelete.connectionGeneration, afterDelete.connectionGeneration)
        assertNotEquals(beforeDelete.credentialEpoch, afterDelete.credentialEpoch)
        assertNull(store.getApiKey("account-a", "provider-a"))
        assertEquals(observationBeforeDelete + 1, CapabilityEvidenceObservationBridge.revision.value)
    }

    @Test
    fun `repeated delete does not advance epoch after credential is absent`() {
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        store.saveApiKey("account-a", "provider-a", "sk-existing")
        store.deleteApiKey("account-a", "provider-a")
        val afterFirstDelete = store.capabilityEpochs("account-a", "provider-a")
        val observationBeforeRepeat = CapabilityEvidenceObservationBridge.revision.value

        store.deleteApiKey("account-a", "provider-a")

        assertEquals(afterFirstDelete, store.capabilityEpochs("account-a", "provider-a"))
        assertNull(store.getApiKey("account-a", "provider-a"))
        assertEquals(observationBeforeRepeat, CapabilityEvidenceObservationBridge.revision.value)
    }

    @Test
    fun `beginning a capability connection replaces both epochs and invalidates once`() {
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        val before = store.capabilityEpochs("account-a", "provider-a")
        val observationBefore = CapabilityEvidenceObservationBridge.revision.value

        val after = store.beginCapabilityConnection("account-a", "provider-a")

        assertNotEquals(before.connectionGeneration, after.connectionGeneration)
        assertNotEquals(before.credentialEpoch, after.credentialEpoch)
        assertEquals(observationBefore + 1, CapabilityEvidenceObservationBridge.revision.value)
    }

    @Test
    fun `advancing a capability connection delegates to one whole connection invalidation`() {
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        val observationBefore = CapabilityEvidenceObservationBridge.revision.value

        store.advanceCapabilityConnection("account-a", "provider-a")

        assertEquals(observationBefore + 1, CapabilityEvidenceObservationBridge.revision.value)
    }
}
