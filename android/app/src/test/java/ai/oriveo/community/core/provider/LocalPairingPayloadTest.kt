package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class LocalPairingPayloadTest {
    @Test fun `parses v1 without credentials`() {
        val result = LocalPairingPayload.decode("""{"v":1,"name":"Fixture Mac","urls":["http://192.168.1.20:8080","http://100.101.102.103:8080"],"engine":"llamacpp","auth":"none"}""")
        assertEquals(LocalEngineKind.LlamaCpp, result.engine)
        assertEquals(RelayConnectionSecurityMode.LocalHttp, result.securityMode)
        assertEquals(2, result.candidates.size)
        assertEquals(RelayConnectionSecurityMode.PrivateVpn, result.candidates[1].securityMode)
    }

    @Test fun `rejects embedded secret`() {
        assertThrows(IllegalArgumentException::class.java) {
            LocalPairingPayload.decode("oriveo://local-provider?v=1&engine=ollama&endpoint=http%3A%2F%2F127.0.0.1%3A11434&mode=local_http&auth=none&token=secret")
        }
    }

    @Test fun `rejects secret nested in endpoint`() {
        assertThrows(IllegalArgumentException::class.java) {
            LocalPairingPayload.decode("oriveo://local-provider?v=1&engine=ollama&endpoint=http%3A%2F%2F127.0.0.1%3A11434%2F%3Fclient_secret%3Dx&mode=local_http&auth=none")
        }
    }
}
