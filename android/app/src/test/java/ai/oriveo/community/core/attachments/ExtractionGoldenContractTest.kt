package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables
import ai.oriveo.community.core.attachments.extractors.OcrScript
import ai.oriveo.community.core.attachments.extractors.PdfOcr
import ai.oriveo.community.core.attachments.extractors.PdfOcrDocument
import ai.oriveo.community.core.attachments.extractors.PdfOcrEngine
import ai.oriveo.community.core.attachments.extractors.PdfTextExtractor
import androidx.test.core.app.ApplicationProvider
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.w3c.dom.Element

/**
 * Shared fixtures `shared/test-fixtures/attachments/extraction/`: the byte-for-byte contract of the attachment extraction spec across all three platforms.
 * This file covers section 2 type classification, section 4 plain-text decoding (golden cases with id prefix `text_`), HTML / EPUB / RTF of sections 8 / 10 / 11
 * (id prefixes `html_` `epub_` `rtf_` and EPUB DRM error cases), OOXML and ODF of sections 4A-7 / 9 / 15 / 16
 * (id prefixes `docx_` `xlsx_` `pptx_` `odt_` `ods_` `odp_` and DOCTYPE / non-zip / encryption error cases), PDF of section 12 (`pdfCases`,
 * fully scanned documents without OCR assert `scannedWithoutOcr`; the `ocr` half of section 13 asserts the format with a fake engine producing the same text), the encoding score tables and the legacy-format prompt copy.
 * The number of cases per category is locked, so newly added fixture cases are not silently skipped.
 */
// PDF cases need PDFBox glyph resources, which PDFBoxResourceLoader fetches from Android resources, so a Robolectric Context is required.
@RunWith(RobolectricTestRunner::class)
class ExtractionGoldenContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixtureDir = "shared/test-fixtures/attachments/extraction"
    private val golden: JsonObject by lazy { readJson("$fixtureDir/extraction-golden.v1.json") }

    @Test
    fun `text golden cases decode byte for byte through the production entry`() {
        val cases = golden["cases"]!!.jsonArray.map { it.jsonObject }
            .filter { it.string("id").startsWith("text_") }
        assertEquals("text_ case count", 12, cases.size)

        val mismatches = cases.mapNotNull { case ->
            val expected = case["expect"]!!.jsonObject.string("content")
            val actual = runCatching { extract(case).content }.getOrElse { "<threw $it>" }
            if (actual == expected) null else "${case.string("id")}: expected=${expected.quoted()} actual=${actual.quoted()}"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun `text error cases report the contract error code`() {
        val cases = golden["errorCases"]!!.jsonArray.map { it.jsonObject }
            .filter { it.string("id") == "text_binary_png" }
        assertEquals("text error case count", 1, cases.size)

        cases.forEach { case ->
            val expected = case["expect"]!!.jsonObject.string("error")
            val actual = try {
                "content=" + extract(case).content.quoted()
            } catch (e: ExtractionException) {
                e.code.raw
            }
            assertEquals(case.string("id"), expected, actual)
        }
    }

    @Test
    fun `html epub rtf golden cases match byte for byte through the production entry`() {
        val counts = mapOf("html_" to 2, "epub_" to 3, "rtf_" to 4)
        val cases = golden["cases"]!!.jsonArray.map { it.jsonObject }
            .filter { case -> counts.keys.any { case.string("id").startsWith(it) } }
        counts.forEach { (prefix, count) ->
            assertEquals("${prefix} case count", count, cases.count { it.string("id").startsWith(prefix) })
        }

        val mismatches = cases.mapNotNull { case ->
            val expected = case["expect"]!!.jsonObject.string("content")
            val actual = runCatching { extract(case).content }.getOrElse { "<threw $it>" }
            if (actual == expected) null else "${case.string("id")}: expected=${expected.quoted()} actual=${actual.quoted()}"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun `epub drm error cases report unsupported format`() {
        val ids = setOf("epub_drm_aes", "epub_drm_lcp")
        val cases = golden["errorCases"]!!.jsonArray.map { it.jsonObject }.filter { it.string("id") in ids }
        assertEquals("epub DRM error case count", 2, cases.size)

        cases.forEach { case ->
            val expected = case["expect"]!!.jsonObject.string("error")
            val actual = try {
                "content=" + extract(case).content.quoted()
            } catch (e: ExtractionException) {
                assertEquals(case.string("id"), "epub_drm", e.underlying)
                e.code.raw
            }
            assertEquals(case.string("id"), expected, actual)
        }
    }

    @Test
    fun `ooxml and odf golden cases match byte for byte through the production entry`() {
        val counts = mapOf("docx_" to 12, "xlsx_" to 6, "pptx_" to 2, "odt_" to 1, "ods_" to 1, "odp_" to 1)
        val cases = golden["cases"]!!.jsonArray.map { it.jsonObject }
            .filter { case -> counts.keys.any { case.string("id").startsWith(it) } }
        counts.forEach { (prefix, count) ->
            assertEquals("${prefix} case count", count, cases.count { it.string("id").startsWith(prefix) })
        }

        val mismatches = cases.mapNotNull { case ->
            val expected = case["expect"]!!.jsonObject.string("content")
            val actual = runCatching { extract(case).content }.getOrElse { "<threw $it>" }
            if (actual == expected) null else "${case.string("id")}: expected=${expected.quoted()} actual=${actual.quoted()}"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun `office error cases report the contract error code`() {
        val ids = setOf("docx_doctype", "docx_not_zip", "docx_ole_encrypted", "xlsx_ole_encrypted")
        val cases = golden["errorCases"]!!.jsonArray.map { it.jsonObject }.filter { it.string("id") in ids }
        assertEquals("office error case count", 4, cases.size)

        val mismatches = cases.mapNotNull { case ->
            val expected = case["expect"]!!.jsonObject.string("error")
            val actual = try {
                "content=" + extract(case).content.quoted()
            } catch (e: ExtractionException) {
                e.code.raw
            }
            if (actual == expected) null else "${case.string("id")}: expected=$expected actual=$actual"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun `edge golden cases match byte for byte and edge error cases report corrupted file`() {
        val edges = readJson("$fixtureDir/extraction-golden-edges.v1.json")
        val cases = edges["cases"]!!.jsonArray.map { it.jsonObject }
        assertEquals("edges success case count", 5, cases.size)
        val errorCases = edges["errorCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals("edges error case count", 3, errorCases.size)

        val mismatches = cases.mapNotNull { case ->
            val expected = case["expect"]!!.jsonObject.string("content")
            val actual = runCatching { extract(case).content }.getOrElse { "<threw $it>" }
            if (actual == expected) null else "${case.string("id")}: expected=${expected.quoted()} actual=${actual.quoted()}"
        } + errorCases.mapNotNull { case ->
            val expected = case["expect"]!!.jsonObject.string("error")
            val actual = try {
                "content=" + extract(case).content.quoted()
            } catch (e: ExtractionException) {
                e.code.raw
            }
            if (actual == expected) null else "${case.string("id")}: expected=$expected actual=$actual"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun `embedded radical table equals cjk-radicals fixture`() {
        val map = readJson("$fixtureDir/cjk-radicals.v1.json")["map"]!!.jsonObject
        assertEquals("radical table count", 328, map.size)
        val expected = map.entries.associate { (radical, ideograph) -> radical.toInt(16) to ideograph.jsonPrimitive.content.toInt(16) }
        assertEquals(expected, PdfTextExtractor.radicalMap)
        // Mapped back item by item through the production path.
        val mismatches = expected.mapNotNull { (radical, ideograph) ->
            val actual = PdfTextExtractor.normalizePageText(String(Character.toChars(radical)))
            val want = String(Character.toChars(ideograph))
            if (actual == want) null else "%04X: expected=%s actual=%s".format(radical, want, actual)
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun `pdf cases lock page markers fragments error and scanned flag`() {
        PDFBoxResourceLoader.init(ApplicationProvider.getApplicationContext())
        val cases = golden["pdfCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals("pdfCases count", 5, cases.size)

        val mismatches = cases.flatMap { case ->
            val id = case.string("id")
            val expect = case["expect"]!!.jsonObject
            // Fully scanned: OCR is not connected here, so scannedWithoutOcr should be reported; the OCR half is in the next case.
            val expectedError = expect["error"]?.jsonPrimitive?.content
                ?: expect["scannedWithoutOcr"]?.jsonObject?.string("error")
            val outcome = try {
                Result.success(extract(case))
            } catch (e: ExtractionException) {
                Result.failure(e)
            }
            if (expectedError != null) {
                val actual = outcome.fold({ "content=" + it.content.quoted() }, { (it as ExtractionException).code.raw })
                return@flatMap if (actual == expectedError) emptyList() else listOf("$id: expected=$expectedError actual=$actual")
            }
            val result = outcome.getOrElse { return@flatMap listOf("$id: threw $it") }
            val markers = result.content.lines().filter { it.startsWith("--- Page ") }
            buildList {
                if (markers != expect.strings("markers")) add("$id: markers=$markers")
                expect.strings("contains").filterNot { result.content.contains(it) }.forEach { add("$id: missing ${it.quoted()} in ${result.content.quoted()}") }
                expect.strings("notContains").filter { result.content.contains(it) }.forEach { add("$id: unexpected ${it.quoted()}") }
                if (result.scanned != expect["scanned"]!!.jsonPrimitive.boolean) add("$id: scanned=${result.scanned}")
            }
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun `pdf ocr half matches the golden through a fake engine`() {
        PDFBoxResourceLoader.init(ApplicationProvider.getApplicationContext())
        val cases = golden["pdfCases"]!!.jsonArray.map { it.jsonObject }.associateBy { it.string("id") }
        // The fake engine produces the fixture's expected text in place of ML Kit: the fully scanned file recognizes "123", and the image page has no text.
        val recognized = mapOf("pdf_full_scan" to "123", "pdf_image_page" to "")
        val checked = recognized.map { (id, text) ->
            val case = cases.getValue(id)
            val expect = case["expect"]!!.jsonObject.let { it["ocr"]?.jsonObject ?: it }
            val engine = PdfOcrEngine {
                object : PdfOcrDocument {
                    override fun recognize(pageIndex: Int, script: OcrScript, timeoutNanos: Long): String = text
                    override fun close() = Unit
                }
            }
            val result = extract(case, PdfOcr(engine) { case.string("uiLanguage") })
            val markers = result.content.lines().filter { it.startsWith("--- Page ") }
            assertEquals("$id markers", expect.strings("markers"), markers)
            expect.strings("contains").forEach { assertTrue("$id missing ${it.quoted()} in ${result.content.quoted()}", result.content.contains(it)) }
            expect["notContains"]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty()
                .forEach { assertTrue("$id unexpected ${it.quoted()}", !result.content.contains(it)) }
            assertEquals("$id scanned", expect["scanned"]!!.jsonPrimitive.boolean, result.scanned)
            id
        }
        assertEquals("OCR half case count", 2, checked.size)
    }

    @Test
    fun `classification matches every fixture row`() {
        val rows = golden["classification"]!!.jsonArray.map { it.jsonObject }
        assertEquals("classification count", 24, rows.size)

        val mismatches = rows.mapNotNull { row ->
            val actual = ExtractionFileTypes.classify(row.string("fileName"), row.string("mime")).raw
            if (actual == row.string("kind")) null
            else "${row.string("fileName")} + ${row.string("mime")}: expected=${row.string("kind")} actual=$actual"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun `supported type lists equal supported-types fixture`() {
        val fixture = readJson("$fixtureDir/supported-types.v1.json")
        val categories = ExtractionFileTypes.categories.associateBy { it.kind.raw }
        val fixtureKinds = fixture.keys - setOf("v", "doc", "text")
        assertEquals(fixtureKinds, categories.keys)
        fixtureKinds.forEach { kind ->
            val entry = fixture[kind]!!.jsonObject
            assertEquals("$kind extensions", entry.strings("extensions").toSet(), categories.getValue(kind).extensions)
            assertEquals("$kind mimes", entry.strings("mimes").toSet(), categories.getValue(kind).mimes)
        }

        val text = fixture["text"]!!.jsonObject
        assertEquals("text extensions", text.strings("extensions").toSet(), ExtractionFileTypes.textExtensions)
        assertEquals("text filenames", text.strings("filenames").toSet(), ExtractionFileTypes.textFilenames)
        assertEquals("text mimes", text.strings("mimes").toSet(), ExtractionFileTypes.textMimes)
        assertTrue("anyTextMime", text["anyTextMime"]!!.jsonPrimitive.boolean)
        assertEquals(ExtractionFileKind.Text, ExtractionFileTypes.classify("x.unlisted", "text/x-anything"))
    }

    @Test
    fun `embedded charset tables equal charset-tables fixture`() {
        val fixture = readJson("$fixtureDir/charset-tables.v1.json")
        assertEquals(fixture.strings("candidates"), LegacyCharsetTables.candidates)
        assertEquals(
            fixture["localeTieBreak"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content },
            LegacyCharsetTables.localeTieBreak,
        )
        val common = fixture["commonChars"]!!.jsonObject
        assertEquals(common.keys, LegacyCharsetTables.commonChars.keys)
        common.forEach { (candidate, codes) ->
            val expected = codes.jsonArray.map { it.jsonPrimitive.content.toInt(16) }
            assertEquals("$candidate count", expected.size, LegacyCharsetTables.commonChars.getValue(candidate).size)
            assertEquals(candidate, expected.toSet(), LegacyCharsetTables.commonChars.getValue(candidate))
        }
        assertEquals(fixture.strings("punct1252").map { it.toInt(16) }.toSet(), LegacyCharsetTables.punct1252)
        assertEquals(fixture.strings("ok1251").map { it.toInt(16) }.toSet(), LegacyCharsetTables.ok1251)
    }

    @Test
    fun `single byte tables are the WHATWG mappings`() {
        assertWhatwg("windows-1252", LegacyCharsetTables.windows1252High, setOf(0x81, 0x8D, 0x8F, 0x90, 0x9D))
        assertWhatwg("windows-1251", LegacyCharsetTables.windows1251High, setOf(0x98))
    }

    @Test
    fun `legacy format copy equals fixture in all 16 locales`() {
        val copy = readJson("shared/test-fixtures/attachments/extraction/legacy-format-copy.v1.json")["copy"]!!.jsonObject
        val folders = mapOf(
            "en" to "values", "zh-Hans" to "values-zh-rCN", "zh-Hant" to "values-zh-rTW", "ja" to "values-ja",
            "ko" to "values-ko", "de" to "values-de", "fr" to "values-fr", "es" to "values-es",
            "pt-BR" to "values-pt-rBR", "ru" to "values-ru", "tr" to "values-tr", "id" to "values-in",
            "vi" to "values-vi", "th" to "values-th", "hi" to "values-hi", "ar" to "values-ar",
        )
        assertEquals(16, copy.size)
        assertEquals(copy.keys, folders.keys)

        val mismatches = folders.mapNotNull { (language, folder) ->
            val expected = copy[language]!!.jsonPrimitive.content.replace("{fileName}", "%1\$s")
            val actual = androidString(folder, "file_extraction_error_legacy_format")
            if (actual == expected) null else "$language ($folder): expected=${expected.quoted()} actual=${actual?.quoted()}"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    private fun extract(case: JsonObject, pdfOcr: PdfOcr? = null): ExtractedText =
        FileTextExtractor.extract(
            File(repoRoot(), "$fixtureDir/${case.string("file")}").readBytes(),
            fileName = case.string("fileName"),
            mimeType = case.string("mime"),
            uiLanguage = case.string("uiLanguage"),
            pdfOcr = pdfOcr,
        )

    /** Compare byte by byte with the JDK mapping; WHATWG-specific code points map to the same-valued C1 control characters. */
    private fun assertWhatwg(name: String, table: CharArray, whatwgOnly: Set<Int>) {
        val decoder = Charset.forName(name).newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        for (byte in 0x80..0xFF) {
            val actual = table[byte - 0x80]
            if (byte in whatwgOnly) {
                assertEquals("$name ${byte.toString(16)}", byte.toChar(), actual)
            } else {
                val expected = decoder.decode(ByteBuffer.wrap(byteArrayOf(byte.toByte()))).toString()
                assertEquals("$name ${byte.toString(16)}", expected, actual.toString())
            }
        }
    }

    /** Read raw XML under res, restoring `\'` and `\uXXXX` escapes by aapt's rules. */
    private fun androidString(folder: String, name: String): String? {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/$folder/strings.xml"))
        val nodes = document.getElementsByTagName("string")
        for (index in 0 until nodes.length) {
            val element = nodes.item(index) as? Element ?: continue
            if (element.getAttribute("name") != name) continue
            return Regex("""\\u([0-9a-fA-F]{4})|\\(.)""").replace(element.textContent) { match ->
                match.groupValues[1].takeIf { it.isNotEmpty() }?.toInt(16)?.toChar()?.toString()
                    ?: match.groupValues[2]
            }
        }
        return null
    }

    private fun JsonObject.string(key: String): String = this[key]!!.jsonPrimitive.content

    private fun JsonObject.strings(key: String): List<String> = this[key]!!.jsonArray.map { it.jsonPrimitive.content }

    private fun String.quoted(): String = Json.encodeToString(String.serializer(), this)

    private fun repoRoot(): File = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

    private fun readJson(relativePath: String): JsonObject =
        json.parseToJsonElement(File(repoRoot(), relativePath).readText()).jsonObject
}
