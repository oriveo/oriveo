package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.bool
import ai.oriveo.community.core.search.SearchContractFixtures.int
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * Conversion between the search-turn / tool-host / injection fixtures and production types: inputs are read from fixtures into production types,
 * outputs are written in the reference implementation's JSON shape (the difference between omitted fields and null follows scripts/lib/search-*.mjs), then compared with expect by JSON semantics.
 */
internal object SearchTurnJson {
    private fun nonNull(e: JsonElement?): JsonElement? = e?.takeIf { it != JsonNull }

    private fun ints(list: List<Int>) = JsonArray(list.map { JsonPrimitive(it) })

    private fun strs(list: List<String>) = JsonArray(list.map { JsonPrimitive(it) })

    private fun s(v: String?): JsonElement = v?.let { JsonPrimitive(it) } ?: JsonNull

    // ───── Input ─────

    fun hostInput(o: JsonObject?, path: String = str(o?.get("path")) ?: ""): SearchToolHostInput = SearchToolHostInput(
        path = path,
        library = bool(o?.get("library")) == true,
        mcp = bool(o?.get("mcp")) == true,
        memoryTools = bool(o?.get("memoryTools")) == true,
        nativeMoonshotLoop = bool(o?.get("nativeMoonshotLoop")) == true,
        serverMaxSteps = int(o?.get("serverMaxSteps")),
        continuationKind = str(o?.get("continuationKind")),
    )

    fun service(o: JsonObject) = SearchTurnService(str(o["id"])!!, str(o["name"])!!, str(o["protocol"])!!, bool(o["custom"]) == true)

    fun planInput(i: JsonObject): SearchTurnPlanInput {
        val thinking = nonNull(i["thinking"])?.jsonObject
        val rej = nonNull(i["upstreamRejection"])?.jsonObject
        val regen = nonNull(i["regenerate"])?.jsonObject
        return SearchTurnPlanInput(
            path = str(i["path"])!!,
            service = nonNull(i["service"])?.jsonObject?.let(::service),
            toolCall = str(i["toolCall"]),
            host = hostInput(nonNull(i["host"])?.jsonObject, ""),
            thinking = SearchThinking(
                on = bool(thinking?.get("on")) == true,
                protocol = str(thinking?.get("protocol")),
                continuationStateAvailable = bool(thinking?.get("continuationStateAvailable")),
            ),
            upstreamRejection = rej?.let { SearchUpstreamRejection(int(it["status"])!!, int(it["leg"])!!) },
            toolsRejectedBefore = bool(i["toolsRejectedBefore"]) == true,
            regenerate = regen?.let { SearchRegenerate(str(it["action"])!!, bool(it["previousResultsPersisted"]) == true) } ?: SearchRegenerate(),
            userText = str(i["userText"]),
            b = int(i["B"]),
            today = str(i["today"]).orEmpty(),
        )
    }

    fun resultItem(o: JsonObject) = SearchResultItem(str(o["title"])!!, str(o["url"])!!, str(o["snippet"]).orEmpty(), str(o["site"]), str(o["date"]))

    fun results(e: JsonElement?) = e!!.jsonArray.map { resultItem(it.jsonObject) }

    fun citationItem(o: JsonObject) = CitationItem(url = str(o["url"]), libraryKey = str(o["libraryKey"]))

    fun batches(e: JsonElement?) = (nonNull(e) as? JsonArray).orEmpty().map { b ->
        val o = b.jsonObject
        CitationBatch(str(o["source"])!!, o.getValue("items").jsonArray.map { citationItem(it.jsonObject) })
    }

    fun replyStart(o: JsonObject): SearchReplyStart {
        val plan = o.getValue("plan").jsonObject
        return SearchReplyStart(
            plan = SearchReplyPlan(str(plan["path"])!!, str(plan["fallbackReason"]), bool(plan["noticeOnce"]) == true),
            service = service(o.getValue("service").jsonObject),
            otherServices = (nonNull(o["otherServices"]) as? JsonArray).orEmpty().map {
                val s = it.jsonObject
                SearchOtherService(str(s["id"])!!, str(s["name"])!!, bool(s["isDefault"]) == true)
            },
            b = int(o["B"]),
            rhoHi = (o.getValue("rhoHi") as JsonPrimitive).content.toDouble(),
            retrievedAt = str(o["retrievedAt"])!!,
            priorBatches = batches(o["priorBatches"]),
        )
    }

    private fun outcome(o: JsonObject): SearchCallOutcome {
        val latency = int(o["latencyMs"])?.toLong()
        val error = nonNull(o["error"])?.jsonObject
        return when {
            o["results"] != null -> SearchCallOutcome.Results(results(o["results"]), latency)
            bool(o["empty"]) == true -> SearchCallOutcome.Empty(latency)
            else -> SearchCallOutcome.Failed(
                errorClass = str(error!!["errorClass"])!!,
                retryOnce = bool(error["retryOnce"]) == true,
                sent = bool(o["sent"]) != false,
                latencyMs = latency,
            )
        }
    }

    fun event(o: JsonObject): SearchEvent = when (val type = str(o["type"])) {
        "call" -> SearchEvent.Call(str(o["query"]), int(o["count"]))
        "result" -> SearchEvent.Result(outcome(o.getValue("outcome").jsonObject))
        "reuse" -> SearchEvent.Reuse(str(o["query"])!!, results(o["results"]))
        "other_sources" -> SearchEvent.OtherSources(str(o["source"])!!, o.getValue("items").jsonArray.map { citationItem(it.jsonObject) })
        "stopped" -> SearchEvent.Stopped
        else -> error("unknown event type $type")
    }

    fun citation(o: JsonObject) = SearchCitation(
        number = int(o["number"])!!,
        source = str(o["source"])!!,
        title = str(o["title"])!!,
        url = str(o["url"])!!,
        snippet = str(o["snippet"]).orEmpty(),
        query = str(o["query"]),
        serviceId = str(o["serviceId"]),
        serviceName = str(o["serviceName"]),
        retrievedAt = str(o["retrievedAt"]),
        site = str(o["site"]),
        date = str(o["date"]),
    )

    // ───── Output ─────

    fun toolHost(h: SearchToolHost): JsonObject = buildJsonObject {
        put("host", JsonPrimitive(h.host))
        put("tools", strs(h.tools))
        put("webSearchRegistered", JsonPrimitive(h.webSearchRegistered))
        if (h.unchanged) {
            put("unchanged", JsonPrimitive(true))
        } else {
            put("maxSteps", JsonPrimitive(h.maxSteps))
            put("prompts", s(h.prompts))
            put("consecutiveFailureBreaker", h.consecutiveFailureBreaker?.let { JsonPrimitive(it) } ?: JsonPrimitive("off"))
            put("webSearchDisposition", s(h.webSearchDisposition))
            put("writeToolConfirm", s(h.writeToolConfirm))
            put("memoryTailLeg", s(h.memoryTailLeg))
        }
    }

    fun budget(b: SearchInjectionBudget) = buildJsonObject {
        put("perSearch", JsonPrimitive(b.perSearch))
        put("perReply", JsonPrimitive(b.perReply))
    }

    fun telemetry(list: List<SearchTelemetryEvent>) = JsonArray(
        list.map { t ->
            buildJsonObject {
                put("event", JsonPrimitive(t.event))
                put(
                    "props",
                    JsonObject(
                        t.props.mapValues { (_, v) ->
                            when (v) {
                                is Boolean -> JsonPrimitive(v)
                                is Number -> JsonPrimitive(v)
                                else -> JsonPrimitive(v.toString())
                            }
                        },
                    ),
                )
            }
        },
    )

    fun plan(p: SearchTurnPlan): JsonObject = buildJsonObject {
        put("path", JsonPrimitive(p.path))
        put("fallbackReason", s(p.fallbackReason))
        put("noticeOnce", JsonPrimitive(p.noticeOnce))
        put("requestHasNativeSearchFields", JsonPrimitive(p.requestHasNativeSearchFields))
        put("requestHasWebSearchTool", JsonPrimitive(p.requestHasWebSearchTool))
        put("toolHost", toolHost(p.toolHost))
        put(
            "webSearchTool",
            p.webSearchTool?.let {
                buildJsonObject {
                    put("name", JsonPrimitive(it.name))
                    put("description", JsonPrimitive(it.description))
                    put("parameters", it.parameters)
                }
            } ?: JsonNull,
        )
        put(
            "presearch",
            p.presearch?.let {
                buildJsonObject {
                    put("query", JsonPrimitive(it.query))
                    put("count", JsonPrimitive(it.count))
                }
            } ?: JsonNull,
        )
        put("reuse", JsonPrimitive(p.reuse))
        put("budget", p.budget?.let(::budget) ?: JsonNull)
        put("writeToolConfirm", JsonPrimitive(p.writeToolConfirm))
        put("telemetry", telemetry(p.telemetry))
    }

    fun citation(c: SearchCitation): JsonObject = buildJsonObject {
        put("number", JsonPrimitive(c.number))
        put("source", JsonPrimitive(c.source))
        put("title", JsonPrimitive(c.title))
        put("url", JsonPrimitive(c.url))
        put("snippet", JsonPrimitive(c.snippet))
        put("query", s(c.query))
        put("serviceId", s(c.serviceId))
        put("serviceName", s(c.serviceName))
        put("retrievedAt", s(c.retrievedAt))
        c.site?.let { put("site", JsonPrimitive(it)) }
        c.date?.let { put("date", JsonPrimitive(it)) }
    }

    private fun citations(list: List<SearchCitation>) = JsonArray(list.map(::citation))

    fun effect(e: SearchEffect): JsonObject = when (e) {
        is SearchEffect.Send -> buildJsonObject {
            put("kind", JsonPrimitive("send"))
            put("retry", JsonPrimitive(e.retry))
            put(
                "activity",
                buildJsonObject {
                    put("kind", JsonPrimitive(e.activity.kind))
                    put("serviceName", JsonPrimitive(e.activity.serviceName))
                    put("query", JsonPrimitive(e.activity.query))
                },
            )
        }
        is SearchEffect.Deliver -> buildJsonObject {
            put("kind", JsonPrimitive("deliver"))
            put("content", JsonPrimitive(e.content))
            put("citations", citations(e.citations))
            put("webResultsPresent", JsonPrimitive(e.webResultsPresent))
            put("telemetry", telemetry(e.telemetry))
        }
        is SearchEffect.Numbers -> buildJsonObject {
            put("kind", JsonPrimitive("numbers"))
            put("numbers", ints(e.numbers))
        }
        SearchEffect.None -> buildJsonObject { put("kind", JsonPrimitive("none")) }
    }

    fun facts(f: SearchFacts): JsonObject = buildJsonObject {
        put("state", JsonPrimitive(f.state))
        put("source", s(f.source))
        put("evidenceKind", s(f.evidenceKind))
        put("searchCount", JsonPrimitive(f.searchCount))
        put("sourceCount", JsonPrimitive(f.sourceCount))
        // not_requested carries no serviceName (the reference implementation returns early)
        if (f.state != "not_requested") put("serviceName", s(f.serviceName))
    }

    fun finish(f: SearchReplyFinish): JsonObject = buildJsonObject {
        put("facts", facts(f.facts))
        put(
            "sourcesLine",
            f.sourcesLine?.let {
                buildJsonObject {
                    put("searchCount", JsonPrimitive(it.searchCount))
                    put("serviceName", JsonPrimitive(it.serviceName))
                    put("sourceCount", JsonPrimitive(it.sourceCount))
                    put("reused", JsonPrimitive(it.reused))
                    put("custom", JsonPrimitive(it.custom))
                }
            } ?: JsonNull,
        )
        put(
            "errorCard",
            f.errorCard?.let { c ->
                buildJsonObject {
                    put("errorClass", JsonPrimitive(c.errorClass))
                    put("headline", JsonPrimitive(c.headline))
                    put("primaryAction", JsonPrimitive(c.primaryAction))
                    c.secondaryAction?.let { put("secondaryAction", JsonPrimitive(it)) }
                    put("serviceName", JsonPrimitive(c.serviceName))
                    put(
                        "switchTo",
                        c.switchTo?.let {
                            buildJsonObject {
                                put("id", JsonPrimitive(it.id))
                                put("name", JsonPrimitive(it.name))
                            }
                        } ?: JsonNull,
                    )
                }
            } ?: JsonNull,
        )
        put("notice", s(f.notice))
        put("citations", citations(f.citations))
        put("webResultsPresent", JsonPrimitive(f.webResultsPresent))
    }

    fun fit(r: WebFitResult): JsonObject = buildJsonObject {
        put("envelope", s(r.envelope))
        put("ids", ints(r.ids))
        put("includedCount", JsonPrimitive(r.includedCount))
        put("droppedCount", JsonPrimitive(r.droppedCount))
        put("truncatedIds", ints(r.truncatedIds))
        put("estimatedTokens", JsonPrimitive(r.estimatedTokens))
    }
}
