package ai.oriveo.community.core.model

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unified avatars: every place that can draw a relay connection takes its result through [ConnectionAvatarSpec.of] --
 * relay connections use RelayAvatar (brand image / initial / generic), a connection that no longer exists draws generic, local engines and official providers use the badge;
 * production source must no longer pass `relayKind` to `ProviderBadgeIcon` (drawing a relay logo by protocol is the mark of the old defect).
 */
class ConnectionAvatarCoverageTest {

    @Test
    fun `RL2-AVATAR-COVER-01 relay connection with aggregator name draws brand`() {
        val relay = Provider(id = "r", kind = ProviderKind.Relay, customName = "OpenRouter \u5907\u7528", baseUrlText = "https://proxy.example.com/v1")
        assertEquals(
            ConnectionAvatarSpec.Relay(RelayAvatarResult.Brand("openrouter", ProviderKind.OpenRouter)),
            ConnectionAvatarSpec.of(relay, ProviderKind.Relay),
        )
    }

    @Test
    fun `RL2-AVATAR-COVER-02 relay connection without brand draws its default icon not protocol logo`() {
        val relay = Provider(
            id = "r",
            kind = ProviderKind.Relay,
            customName = "Moon Relay",
            baseUrlText = "https://api.myrelay.dev/v1",
            relayKind = RelayKind.OpenAICompatible,
        )
        // Icon layer (relay-avatar-icon.v1.json): without a brand match the default is the icon assigned by connection id; only choosing "Letter" draws the initial.
        assertEquals(
            ConnectionAvatarSpec.Relay(RelayAvatarResolver.resolve(relay.id, relay.customName.orEmpty(), relay.baseUrlText.orEmpty(), null)),
            ConnectionAvatarSpec.of(relay, ProviderKind.Relay, choice = null),
        )
        assertTrue((ConnectionAvatarSpec.of(relay, ProviderKind.Relay, choice = null) as ConnectionAvatarSpec.Relay).result is RelayAvatarResult.Icon)
        assertEquals(ConnectionAvatarSpec.Relay(RelayAvatarResult.Initial("M")), ConnectionAvatarSpec.of(relay, ProviderKind.Relay, choice = RelayAvatarChoiceStore.LETTER))
    }

    @Test
    fun `RL2-AVATAR-COVER-03 missing relay connection draws generic`() {
        assertEquals(ConnectionAvatarSpec.Relay(RelayAvatarResult.Generic), ConnectionAvatarSpec.of(null, ProviderKind.Relay))
        // The connection still exists but name / address are both empty: the icon layer gives the default icon by id (fixture default_when_base_generic); only an empty id stays generic.
        val nameless = Provider(id = "relay-7", kind = ProviderKind.Relay, customName = "", baseUrlText = "")
        assertEquals(ConnectionAvatarSpec.Relay(RelayAvatarResult.Icon(RelayAvatarIcon.Mountains)), ConnectionAvatarSpec.of(nameless, ProviderKind.Relay, choice = null))
        assertEquals(ConnectionAvatarSpec.Relay(RelayAvatarResult.Generic), ConnectionAvatarSpec.of(nameless.copy(id = ""), ProviderKind.Relay))
    }

    @Test
    fun `RL2-AVATAR-COVER-04 local engine and official providers keep badge`() {
        val local = Provider(
            id = "l",
            kind = ProviderKind.Relay,
            customName = "Moon Relay",
            baseUrlText = "http://localhost:11434/v1",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(engineProfile = "ollama"),
        )
        assertEquals(ConnectionAvatarSpec.Badge(resolveProviderLogoKind(local)), ConnectionAvatarSpec.of(local, ProviderKind.Relay))
        val official = Provider(id = "o", kind = ProviderKind.Anthropic)
        assertEquals(ConnectionAvatarSpec.Badge(ProviderKind.Anthropic), ConnectionAvatarSpec.of(official, ProviderKind.Anthropic))
        assertEquals(ConnectionAvatarSpec.Badge(ProviderKind.Gemini), ConnectionAvatarSpec.of(null, ProviderKind.Gemini))
    }

    @Test
    fun `RL2-AVATAR-COVER-05 production ProviderBadgeIcon calls never pass relayKind`() {
        val root = mainRoot()
        val offenders = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file -> badgeCalls(file.readText()).map { (line, args) -> Triple(file, line, args) } }
            .filter { (_, _, args) -> Regex("""\brelayKind\s*=""").containsMatchIn(args) }
            .map { (file, line, _) -> "${file.relativeTo(root)}:$line" }
            .toList()
        assertTrue("ProviderBadgeIcon must not carry relayKind (relays go through ConnectionAvatar / RelayAvatar): $offenders", offenders.isEmpty())
    }

    @Test
    fun `RL2-AVATAR-COVER-06 note source without connection draws generic`() {
        // Notes do not record a connection: the source avatar is resolved uniformly with provider null, relays are always generic, never inferred from the name.
        assertEquals(ConnectionAvatarSpec.Relay(RelayAvatarResult.Generic), ConnectionAvatarSpec.of(null, ProviderKind.Relay))
        val notes = File(mainRoot(), "feature/notes")
        val offenders = notes.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file -> badgeCalls(file.readText()).map { (line, _) -> "${file.name}:$line" } }
            .toList()
        assertTrue("note source avatars must not draw ProviderBadgeIcon directly (use ConnectionAvatar(provider = null)): $offenders", offenders.isEmpty())
        val badge = File(notes, "NotesComponents.kt").readText()
            .substringAfter("internal fun NoteSourceBadge(").substringBefore("\n}\n")
        assertTrue(badge.contains("ConnectionAvatar(provider = null, fallbackKind = it, size = 16.dp)"))
    }

    /** The arguments of each `ProviderBadgeIcon(` call (parentheses balanced across lines); the component's own `fun ProviderBadgeIcon(` declaration is skipped. */
    private fun badgeCalls(text: String): List<Pair<Int, String>> {
        val calls = mutableListOf<Pair<Int, String>>()
        val token = "ProviderBadgeIcon("
        var index = text.indexOf(token)
        while (index >= 0) {
            val isDeclaration = text.substring(maxOf(0, index - 4), index) == "fun "
            val start = index + token.length - 1
            var depth = 0
            var end = start
            while (end < text.length) {
                when (text[end]) {
                    '(' -> depth++
                    ')' -> if (--depth == 0) break
                }
                end++
            }
            if (!isDeclaration) calls += text.substring(0, index).count { it == '\n' } + 1 to text.substring(start, end + 1)
            index = text.indexOf(token, end)
        }
        return calls
    }

    private fun mainRoot(): File {
        val direct = File("src/main/java/ai/oriveo/community")
        if (direct.isDirectory) return direct
        return File("app/src/main/java/ai/oriveo/community")
    }
}
