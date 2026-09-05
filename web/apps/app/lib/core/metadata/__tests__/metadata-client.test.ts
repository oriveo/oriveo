import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { pruneBlobs } from "../../../infra/storage/blob-cache";
import {
  __seedMetadataCacheForTest as seedMetadataCache,
  __readMetadataCacheForTest as readMetadataCache,
  __readModelFactsCacheForTest as readModelFactsCache,
} from "../metadata-client";

/**
 * Text form of whatever the cache has persisted.
 *
 * The privacy assertions (private provenance must never be written to disk) originally read
 * localStorage. Once the snapshot moved to IndexedDB they had to follow, otherwise they would
 * pass vacuously against a localStorage that is always empty - the worst kind of green, with the
 * allowlist regression guard silently disarmed.
 */
async function persistedCacheText(): Promise<string> {
  return JSON.stringify((await readMetadataCache()) ?? {});
}

async function persistedModelFactsText(): Promise<string> {
  return JSON.stringify((await readModelFactsCache()) ?? {});
}

describe("metadata-client", () => {
  beforeEach(async () => {
    vi.resetModules();
    vi.restoreAllMocks();
    await new Promise((r) => setTimeout(r, 20));
    localStorage.clear();
    await pruneBlobs("oriveo:metadata:c", []);
    await pruneBlobs("oriveo:metadata:model-facts", []);
  });

  afterEach(async () => {
    await new Promise((r) => setTimeout(r, 20));
    localStorage.clear();
    await pruneBlobs("oriveo:metadata:c", []);
    await pruneBlobs("oriveo:metadata:model-facts", []);
  });

  it("hydrates the production modelFacts slice from cold cache and advances on a new revision", async () => {
    const fixture = JSON.parse(readFileSync(
      "../../../shared/test-fixtures/model-facts/production-slice.v1.json",
      "utf8",
    ));
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith("/api/metadata/model-facts")) {
        return new Response(JSON.stringify({
          code: 0,
          data: {
            facts: fixture.modelFacts,
            revision: fixture.modelFactsRevision,
          },
          message: "ok",
        }), { status: 200, headers: { "Content-Type": "application/json", ETag: '"facts-r1"' } });
      }
      return new Response(JSON.stringify({
        code: 0,
        data: {
          view: "lean",
          version: 83,
          contractVersion: 1,
          capabilityContractVersion: 2,
          updatedAt: "2026-08-22T00:00:00Z",
          profiles: {},
          providers: {},
          generationParameterTables: {},
        },
      }), { status: 200, headers: { "Content-Type": "application/json", ETag: '"lean-r1"' } });
    });

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(String(fetchSpy.mock.calls[0]?.[0])).toMatch(/\/api\/metadata\?view=lean$/);
    await metadata.ensureModelFacts();
    expect(String(fetchSpy.mock.calls[1]?.[0])).toMatch(/\/api\/metadata\/model-facts$/);

    expect(metadata.getModelFacts("grok", "GROK-4.6-2026-08-22")).toMatchObject({
      toolCall: true,
      reasoningEfforts: ["low", "medium", "high", "xhigh"],
      source: "models_dev",
    });
    expect(metadata.getModelFactsRevision()).toBe(fixture.modelFactsRevision);
    expect(metadata.subscriptionDeclaredReasoningLevels("grok", {
      id: "grok-4.6", upstreamReasoningLevels: [],
    } as never)).toEqual(["low", "medium", "high", "xhigh"]);
    expect(metadata.subscriptionDeclaredToolCall("grok", { id: "grok-4.6" } as never)).toBe(true);
    expect(metadata.normalizeModelFactsID("accounts/fireworks/models/Model-3p1-20260822"))
      .toBe("model-3.1");

    await new Promise((resolve) => setTimeout(resolve, 20));
    let persisted = await persistedModelFactsText();
    expect(persisted).toContain(fixture.modelFactsRevision);
    expect(persisted).not.toContain("artifactHash");

    // Simulate a brand-new renderer process: erase all module state while
    // preserving localStorage, then let the background confirmation return 304.
    metadata.__resetMetadataClientForTest();
    vi.mocked(globalThis.fetch).mockImplementation(async (input, init) => {
      if (String(input).endsWith("/api/metadata/model-facts")) {
        expect(new Headers(init?.headers).get("If-None-Match")).toBe('"facts-r1"');
      }
      return new Response(null, { status: 304 });
    });
    await metadata.initMetadata();
    await metadata.ensureModelFacts();

    expect(metadata.getModelFactsRevision()).toBe(fixture.modelFactsRevision);
    expect(metadata.getModelFacts("grok", "grok-4.5")?.reasoningEfforts)
      .toEqual(["low", "medium", "high"]);
    expect(metadata.getModelFacts("grok", "grok-build-0.1")).toMatchObject({
      reasoning: true,
      toolCall: true,
    });
    expect(metadata.getModelFacts("grok", "grok-build-0.1")?.reasoningEfforts).toBeUndefined();
    expect(metadata.getModelFacts("openAI", "gpt-5.6-sol")?.reasoningEfforts)
      .toEqual(["none", "low", "medium", "high", "xhigh", "max"]);
    expect(metadata.getModelFacts("anthropic", "claude-sonnet-5")?.reasoningToggle).toBe(true);
    expect(metadata.getModelFacts("gemini", "gemini-2.5-flash-image")?.toolCall).toBe(false);

    await new Promise((resolve) => setTimeout(resolve, 20));
    const coldRevision = metadata.getCachedMetadataVersion();
    const nextFacts = structuredClone(fixture.modelFacts);
    nextFacts["grok/grok-4.6"].toolCall = false;
    vi.mocked(globalThis.fetch).mockImplementation(async (input) => {
      if (String(input).endsWith("/api/metadata/model-facts")) {
        return new Response(JSON.stringify({
          code: 0,
          data: { facts: nextFacts, revision: "sha256:revision-2" },
          message: "ok",
        }), { status: 200, headers: { "Content-Type": "application/json", ETag: '"facts-r2"' } });
      }
      return new Response(JSON.stringify({
        code: 0,
        data: {
          view: "lean",
          version: 84,
          contractVersion: 1,
          capabilityContractVersion: 2,
          updatedAt: "2026-08-23T00:00:00Z",
          profiles: {},
          providers: {},
          generationParameterTables: {},
        },
      }), { status: 200, headers: { "Content-Type": "application/json", ETag: '"lean-r2"' } });
    });
    await metadata.refreshMetadata();
    await metadata.ensureModelFacts();

    expect(metadata.getCachedMetadataVersion()).toBeGreaterThan(coldRevision);
    expect(metadata.getModelFactsRevision()).toBe("sha256:revision-2");
    expect(metadata.getModelFacts("grok", "grok-4.6")?.toolCall).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 20));
    persisted = await persistedModelFactsText();
    expect(persisted).toContain("sha256:revision-2");
    expect(persisted).not.toContain("artifactHash");
  });

  it("keeps modelFacts unavailable on sidecar 404 instead of synthesizing an empty artifact", async () => {
    const contractFixture = JSON.parse(readFileSync(
      "../../../shared/model-contracts/metadata_lean_contract.v1.json",
      "utf8",
    ));
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => (
      String(input).endsWith("/api/metadata/model-facts")
        ? new Response(null, { status: 404 })
        : new Response(JSON.stringify(contractFixture.leanResponse), {
            status: 200,
            headers: { "Content-Type": "application/json", ETag: '"lean-404"' },
          })
    ));

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    await metadata.ensureModelFacts();

    expect(metadata.getModelFactsRevision()).toBeUndefined();
    expect(metadata.getModelFacts("openAI", "gpt-out-of-catalog")).toBeUndefined();
    expect(await readModelFactsCache()).toBeNull();
  });

  it("Library fallback shares the same authoritative object as the shared defaults", async () => {
    const [metadata, library] = await Promise.all([
      import("../metadata-client"),
      import("../../library/types"),
    ]);

    expect(metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG).toBe(
      library.DEFAULT_LIBRARY_RUNTIME_CONFIG,
    );
    // v5 added directMaxDocuments / directContextMaxChars (injection budget for the pick-a-document path)
    // v6 added serverResearch* (server-side retrieval)
    expect(metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.version).toBe(6);
    expect(metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.directMaxDocuments).toBe(12);
    expect(metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.directContextMaxChars).toBe(60_000);
    // Bundled catalog default: server research off 
    expect(metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.serverResearchEnabled).toBe(false);
    expect(metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.serverResearchProviderDenylist)
      .toEqual([]);
    expect(metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.serverResearchMaxDocuments).toBe(5);
  });

  it("memoizes the production catalog projection by cached snapshot identity", async () => {
    const payload = (version: number, displayName: string) => ({
      version,
      contractVersion: 1,
      updatedAt: `2026-08-${String(version).padStart(2, "0")}T00:00:00Z`,
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        openAI: {
          defaultModelId: "gpt-memo",
          models: {
            "gpt-memo": {
              canonicalModelId: "gpt-memo",
              displayName,
              capabilities: ["text"],
            },
          },
        },
      },
      providerConfigs: [],
    });
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload(1, "Memo One")), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: '"memo-1"' },
      }),
    );
    const metadata = await import("../metadata-client");
    metadata.__resetMetadataClientForTest();
    await metadata.refreshMetadata();

    const firstSnapshot = metadata.getMetadataSnapshot();
    expect(metadata.getMetadataSnapshot()).toBe(firstSnapshot);

    const { selectResolvedCatalog } = await import("../../store/selectors");
    const provider = {
      id: "provider-memo",
      kind: "openAI",
      status: { kind: "connected" },
      models: [],
      catalogModels: [],
      apiKey: "sk-test",
      apiKeyPreview: "test",
    } as Parameters<typeof selectResolvedCatalog>[0];
    const firstCatalog = selectResolvedCatalog(provider);
    expect(selectResolvedCatalog(provider)).toBe(firstCatalog);
    expect(firstCatalog.catalog[0]?.name).toBe("Memo One");

    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 304 }));
    await metadata.refreshMetadata();
    expect(metadata.getMetadataSnapshot()).toBe(firstSnapshot);
    expect(selectResolvedCatalog(provider)).toBe(firstCatalog);

    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify(payload(2, "Memo Two")), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: '"memo-2"' },
      }),
    );
    await metadata.refreshMetadata();

    expect(metadata.getMetadataSnapshot()).not.toBe(firstSnapshot);
    const secondCatalog = selectResolvedCatalog(provider);
    expect(secondCatalog).not.toBe(firstCatalog);
    expect(secondCatalog.catalog[0]?.name).toBe("Memo Two");
  });

  // Regression: the capability evidence chain calls resolveCatalogModel 4-5 times per model
  // (currentCapabilityEvidenceModel calls it in several places, and
  // projectModelCapabilityPresentation / nextCapabilityEvidenceExpiry each call it a few more).
  // buildResolvedFromEntry runs the whole normalize/decode pass, so without memoization opening a
  // 355-model catalog repeats the projection thousands of times.
  it("memoizes resolveCatalogModel per model object and re-projects on a new snapshot", async () => {
    const payload = (version: number, displayName: string) => ({
      version,
      contractVersion: 1,
      updatedAt: `2026-08-${String(version).padStart(2, "0")}T00:00:00Z`,
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        openAI: {
          defaultModelId: "gpt-proj",
          models: {
            "gpt-proj": {
              canonicalModelId: "gpt-proj",
              displayName,
              capabilities: ["text"],
            },
          },
        },
      },
      providerConfigs: [],
    });
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload(1, "Proj One")), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: '"proj-1"' },
      }),
    );
    const metadata = await import("../metadata-client");
    metadata.__resetMetadataClientForTest();
    await metadata.refreshMetadata();

    const first = metadata.resolveCatalogModel("gpt-proj", "openAI");
    expect(first?.displayName).toBe("Proj One");
    // Resolving twice within one snapshot has to hit the cache and hand back the same object.
    expect(metadata.resolveCatalogModel("gpt-proj", "openAI")).toBe(first);

    // A 304 does not swap the snapshot, so the projection stays identical.
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 304 }));
    await metadata.refreshMetadata();
    expect(metadata.resolveCatalogModel("gpt-proj", "openAI")).toBe(first);

    // A new snapshot rebuilds every model object, so the WeakMap misses naturally and a new projection must be produced.
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify(payload(2, "Proj Two")), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: '"proj-2"' },
      }),
    );
    await metadata.refreshMetadata();

    const second = metadata.resolveCatalogModel("gpt-proj", "openAI");
    expect(second).not.toBe(first);
    expect(second?.displayName).toBe("Proj Two");
  });

  it("marks metadata refresh due only after the successful snapshot TTL expires", async () => {
    let now = 1_800_000_000_000;
    vi.spyOn(Date, "now").mockImplementation(() => now);
    const payload = {
      version: 1,
      contractVersion: 1,
      updatedAt: "2026-08-25T00:00:00Z",
      profiles: {},
      providers: {},
      providerConfigs: [],
    };
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: '"ttl-1"' },
      }),
    );
    const metadata = await import("../metadata-client");
    metadata.__resetMetadataClientForTest();

    expect(metadata.isMetadataRefreshDue()).toBe(true);
    await metadata.refreshMetadata();
    expect(metadata.isMetadataRefreshDue()).toBe(false);

    now += 24 * 60 * 60 * 1000;
    expect(metadata.isMetadataRefreshDue()).toBe(true);

    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 304 }));
    await metadata.refreshMetadata();
    expect(metadata.isMetadataRefreshDue()).toBe(false);
  });

  it("resolves a runtime model ID to the canonical model through resolveMap, unwrapping code+data", async () => {
    // Mimic the backend httputil.OK envelope: { code, data, message }
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          code: 0,
          message: "ok",
          data: {
            version: 7,
            updatedAt: "2026-03-26T10:00:00Z",
            profiles: {},
            providers: {
              openAI: {
                displayName: "OpenAI",
                defaultModelId: "o4-mini",
                resolveMap: {
                  "o4-mini": "o4-mini",
                  "o4-mini-20250301": "o4-mini",
                },
                models: {
                  "o4-mini": {
                    canonicalModelId: "o4-mini",
                    modelRef: "p1EU7mt_cAwN4Cjgsk1T6Q",
                    displayName: "o4-mini",
                    transport: "openai_responses",
                    pricing: {
                      promptPerMToken: 1.1,
                      completionPerMToken: 4.4,
                    },
                    capabilities: ["text", "image", "reasoning"],
                    profiles: {
                      reasoning: "oai_responses",
                      webSearch: null,
                      imageGen: null,
                    },
                    uiHints: {
                      groupKey: "o-series",
                      groupName: "o Series",
                      rank: 90,
                      recommended: true,
                      badgeOrder: ["reasoning", "image"],
                    },
                  },
                },
              },
            },
          },
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      ),
    );

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    const resolved = metadata.resolveCatalogModel("o4-mini-20250301", "openAI");
    expect(resolved).toMatchObject({
      canonicalModelId: "o4-mini",
      modelRef: "p1EU7mt_cAwN4Cjgsk1T6Q",
      displayName: "o4-mini",
      transport: "openai_responses",
      isDefault: true,
      capabilities: ["text", "reasoning", "image"],
      profiles: { reasoning: "oai_responses" },
      uiHints: {
        groupKey: "o-series",
        groupName: "o Series",
        rank: 90,
        recommended: true,
        badgeOrder: ["reasoning", "image"],
      },
    });

    expect(metadata.lookupPricing("o4-mini-20250301", "openAI")).toEqual({
      promptPerToken: 0.0000011,
      completionPerToken: 0.0000044,
    });
    expect(metadata.getLibraryRuntimeConfig()).toEqual(
      metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG,
    );
  });

  it("decodes capabilityEvidenceView v1 strictly and treats only the ETag as the metadata revision", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        version: 8,
        updatedAt: "2026-08-09T00:00:00Z",
        profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
        providers: {
          openAI: {
            resolveMap: {
              "gpt-evidence": "gpt-evidence",
              "gpt-bare-candidates": "gpt-bare-candidates",
              "gpt-legacy-without-view": "gpt-legacy-without-view",
              "gpt-missing-model-transport": "gpt-missing-model-transport",
              "gpt-owned-malformed": "gpt-owned-malformed",
            },
            models: {
              "gpt-evidence": {
                canonicalModelId: "gpt-evidence",
                transport: "openai_responses",
                sourceRef: "root-private-source",
                artifactHash: "root-private-artifact",
                decisionNote: "root-private-decision",
                rawError: "root-private-error",
                endpoint: "https://private.example/v1",
                futureProvenancePayload: { opaqueSecret: "future-private-root" },
                capabilityEvidenceView: {
                  schema: "capability-evidence-view/v1",
                  candidates: [
                    {
                      key: "secret/foo",
                      support: "supported",
                      source: "server_typed",
                      grade: "machine_verified",
                      scope: "provider_model_transport",
                      providerKind: "openAI",
                      modelId: "gpt-evidence",
                      transport: "openai_responses",
                    },
                    {
                      key: "tool_call",
                      support: "supported",
                      source: "server_typed",
                      grade: "machine_verified",
                      scope: "provider_model_transport",
                      providerKind: "openAI",
                      modelId: "gpt-evidence",
                      transport: "openai_responses",
                      evidenceRevision: "safe-evidence-r1",
                      observedAt: 1_000,
                      expiresAt: 2_000,
                      sourceRef: "private-sentinel",
                      artifactHash: "private-hash",
                    },
                    {
                      key: "tool_call",
                      support: "supported",
                      source: "future_unknown_source",
                      grade: "machine_verified",
                      scope: "provider_model_transport",
                      providerKind: "openAI",
                      modelId: "gpt-evidence",
                      transport: "openai_responses",
                    },
                    {
                      key: "tool_call",
                      support: "supported",
                      source: "server_typed",
                      grade: "machine_verified",
                      scope: "provider_model_transport",
                      providerKind: "openAI",
                      modelId: "gpt-evidence",
                      transport: "openai_responses",
                      observedAt: 0,
                    },
                  ],
                },
              },
              "gpt-bare-candidates": {
                canonicalModelId: "gpt-bare-candidates",
                transport: "openai_responses",
                // A bare array is a persisted local shape, never a server wire view.
                capabilityEvidenceView: [{
                  key: "tool_call",
                  support: "supported",
                  source: "server_typed",
                  grade: "machine_verified",
                  scope: "provider_model_transport",
                  providerKind: "openAI",
                  modelId: "gpt-bare-candidates",
                  transport: "openai_responses",
                }],
              },
              "gpt-legacy-without-view": {
                canonicalModelId: "gpt-legacy-without-view",
                transport: "openai_responses",
                toolCall: true,
              },
              "gpt-missing-model-transport": {
                canonicalModelId: "gpt-missing-model-transport",
                capabilityEvidenceView: {
                  schema: "capability-evidence-view/v1",
                  candidates: [{
                    key: "tool_call",
                    support: "supported",
                    source: "server_typed",
                    grade: "machine_verified",
                    scope: "provider_model_transport",
                    providerKind: "openAI",
                    modelId: "gpt-missing-model-transport",
                    transport: "openai_responses",
                  }],
                },
              },
              "gpt-owned-malformed": {
                canonicalModelId: "gpt-owned-malformed",
                transport: "openai_responses",
                capabilityEvidenceView: {
                  schema: "capability-evidence-view/v1",
                  candidates: [{
                    key: "generation_parameter/temperature",
                    support: "supported",
                    source: "future_private_source",
                    grade: "effect_verified",
                    scope: "provider_model_transport",
                    providerKind: "openAI",
                    modelId: "gpt-owned-malformed",
                    transport: "openai_responses",
                    sourceRef: "owned-private-provenance",
                  }],
                },
              },
            },
          },
        },
      }), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: '"evidence-etag"' },
      }),
    );

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    const resolved = metadata.resolveCatalogModel("gpt-evidence", "openAI");
    expect(resolved?.metadataRevision).toBe('"evidence-etag"');
    expect(resolved?.capabilityEvidenceCandidates).toEqual([{
      key: "tool_call",
      support: "supported",
      source: "server_typed",
      grade: "machine_verified",
      scope: "provider_model_transport",
      providerKind: "openAI",
      modelId: "gpt-evidence",
      transport: "openai_responses",
      metadataRevision: '"evidence-etag"',
      evidenceRevision: "safe-evidence-r1",
      observedAt: 1_000,
      expiresAt: 2_000,
    }]);
    expect(resolved?.capabilityEvidenceOwnedKeys).toEqual(["tool_call"]);

    const ownedMalformed = metadata.resolveCatalogModel("gpt-owned-malformed", "openAI");
    expect(ownedMalformed?.capabilityEvidenceCandidates).toEqual([]);
    expect(ownedMalformed?.capabilityEvidenceOwnedKeys).toEqual([
      "generation_parameter/temperature",
    ]);
    // Candidate-level rejection owns the key, but the namespace schema itself
    // is valid. Consumers distinguish this from a schema-level malformed view.
    expect(ownedMalformed?.capabilityEvidenceViewMalformed).toBe(false);

    const snapshot = metadata.getMetadataSnapshot();
    expect(JSON.stringify(snapshot)).not.toContain("private-sentinel");
    expect(JSON.stringify(snapshot)).not.toContain("private-hash");
    expect(JSON.stringify(snapshot)).not.toContain("root-private-");
    expect(JSON.stringify(snapshot)).not.toContain("future-private-root");
    expect(JSON.stringify(snapshot)).not.toContain("private.example");
    expect(JSON.stringify(snapshot)).not.toContain("secret/foo");
    expect(snapshot?.providers.openAI.models["gpt-evidence"]
      .capabilityEvidenceCandidates).toEqual(resolved?.capabilityEvidenceCandidates);
    expect(snapshot?.providers.openAI.models["gpt-owned-malformed"]
      .capabilityEvidenceOwnedKeys).toEqual(["generation_parameter/temperature"]);
    expect(metadata.resolveCatalogModel("gpt-bare-candidates", "openAI")
      ?.capabilityEvidenceCandidates).toEqual([]);
    expect(metadata.resolveCatalogModel("gpt-bare-candidates", "openAI")
      ?.capabilityEvidenceViewMalformed).toBe(true);
    expect(metadata.resolveCatalogModel("gpt-legacy-without-view", "openAI")
      ?.capabilityEvidenceCandidates).toBeUndefined();
    expect(metadata.resolveCatalogModel("gpt-missing-model-transport", "openAI")
      ?.capabilityEvidenceCandidates).toEqual([]);
    expect(snapshot?.providers.openAI.models["gpt-bare-candidates"])
      .toHaveProperty("capabilityEvidenceCandidates", []);

    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(await persistedCacheText())
      .not.toContain("private-sentinel");
    expect(await persistedCacheText())
      .not.toContain("root-private-");
    expect(await persistedCacheText())
      .not.toContain("future-private-root");
    expect(await persistedCacheText())
      .not.toContain("secret/foo");
    expect(await persistedCacheText())
      .not.toContain("owned-private-provenance");
    expect(await persistedCacheText())
      .toContain("generation_parameter/temperature");
    const cachedEntry = ((await readMetadataCache()) ?? {}) as any;
    const cachedModels = cachedEntry.data.providers.openAI.models;
    expect(cachedModels["gpt-bare-candidates"]).toMatchObject({
      capabilityEvidenceCandidates: [],
      capabilityEvidenceOwnedKeys: [],
      capabilityEvidenceViewMalformed: true,
    });
    expect(cachedModels["gpt-owned-malformed"]).toMatchObject({
      capabilityEvidenceCandidates: [],
      capabilityEvidenceOwnedKeys: ["generation_parameter/temperature"],
      capabilityEvidenceViewMalformed: false,
    });
    expect(cachedModels["gpt-bare-candidates"]).not.toHaveProperty("capabilityEvidenceView");
  });

  it("a fresh 200 on the same server version still advances the client content revision, a 304 does not", async () => {
    const payload = (evidenceRevision: string) => ({
      version: 8,
      updatedAt: "2026-08-09T00:00:00Z",
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        openAI: {
          resolveMap: { "gpt-evidence": "gpt-evidence" },
          models: {
            "gpt-evidence": {
              canonicalModelId: "gpt-evidence",
              transport: "openai_responses",
              capabilityEvidenceView: {
                schema: "capability-evidence-view/v1",
                candidates: [{
                  key: "tool_call",
                  support: "supported",
                  source: "server_typed",
                  grade: "machine_verified",
                  scope: "provider_model_transport",
                  providerKind: "openAI",
                  modelId: "gpt-evidence",
                  transport: "openai_responses",
                  evidenceRevision,
                }],
              },
            },
          },
        },
      },
    });
    const fetchSpy = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(new Response(JSON.stringify(payload("candidate-r1")), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: '"etag-r1"' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify(payload("candidate-r2")), {
        status: 200,
        headers: { "Content-Type": "application/json", ETag: '"etag-r2"' },
      }))
      .mockResolvedValueOnce(new Response(null, { status: 304 }));

    const metadata = await import("../metadata-client");
    metadata.__resetMetadataClientForTest();
    await metadata.refreshMetadata();
    const firstRevision = metadata.getCachedMetadataVersion();
    expect(firstRevision).toBeGreaterThan(0);

    await metadata.refreshMetadata();
    const secondRevision = metadata.getCachedMetadataVersion();
    expect(secondRevision).toBe(firstRevision + 1);
    expect(metadata.getMetadataVersion()).toBe(8);
    expect(metadata.resolveCatalogModel("gpt-evidence", "openAI")
      ?.capabilityEvidenceCandidates?.[0]?.evidenceRevision).toBe("candidate-r2");

    await metadata.refreshMetadata();
    expect(metadata.getCachedMetadataVersion()).toBe(secondRevision);
    expect(fetchSpy).toHaveBeenCalledTimes(3);
  });

  it("clears the stored revision on a 200 without an ETag instead of stamping the previous payload generation onto the new candidate", async () => {
    const payload = (evidenceRevision: string) => ({
      version: 8,
      updatedAt: "2026-08-09T00:00:00Z",
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        openAI: {
          resolveMap: { "gpt-evidence": "gpt-evidence" },
          models: {
            "gpt-evidence": {
              canonicalModelId: "gpt-evidence",
              transport: "openai_responses",
              capabilityEvidenceView: {
                schema: "capability-evidence-view/v1",
                candidates: [{
                  key: "tool_call",
                  support: "supported",
                  source: "server_typed",
                  grade: "machine_verified",
                  scope: "provider_model_transport",
                  providerKind: "openAI",
                  modelId: "gpt-evidence",
                  transport: "openai_responses",
                  evidenceRevision,
                }],
              },
            },
          },
        },
      },
    });

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify(payload("evidence-r1")), {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          ETag: '"old-etag"',
        },
      }),
    );
    const metadata = await import("../metadata-client");
    await metadata.initMetadata();
    expect(metadata.resolveCatalogModel("gpt-evidence", "openAI")?.metadataRevision)
      .toBe('"old-etag"');

    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify(payload("evidence-r2")), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    await metadata.refreshMetadata();

    const resolved = metadata.resolveCatalogModel("gpt-evidence", "openAI");
    expect(resolved?.metadataRevision).toBeUndefined();
    expect(resolved?.capabilityEvidenceCandidates).toEqual([
      expect.objectContaining({ evidenceRevision: "evidence-r2" }),
    ]);
    expect(resolved?.capabilityEvidenceCandidates?.[0]).not.toHaveProperty(
      "metadataRevision",
    );
    // The ETag lives in the same IDB blob as the snapshot; localStorage must hold no metadata bytes at all.
    expect(await persistedCacheText()).not.toContain('"old-etag"');
    expect(localStorage.length).toBe(0);
  });

  it("drives both the profile and the server candidate from the production generation revision, and rejects stale evidence when it changes", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        version: 8,
        updatedAt: "2026-08-09T00:00:00Z",
        profiles: {
          reasoning: {},
          webSearch: {},
          imageGen: {},
          generation: {
            parameters: {
              temperature: { group: "sampling", valueSchema: "number" },
            },
            templates: {
              openai_responses: { wire: { temperature: "temperature" } },
            },
          },
        },
        providers: {
          openAI: {
            resolveMap: { "gpt-generation": "gpt-generation" },
            models: {
              "gpt-generation": {
                canonicalModelId: "gpt-generation",
                transport: "openai_responses",
                profiles: {
                  generation: {
                    template: "openai_responses",
                    revision: "sha256:generation-r1",
                    parameters: [{
                      id: "temperature",
                      support: "supported",
                      source: "authoritative_metadata",
                    }],
                  },
                },
                capabilityEvidenceView: {
                  schema: "capability-evidence-view/v1",
                  candidates: [{
                    key: "generation_parameter/temperature",
                    support: "supported",
                    source: "server_profile",
                    grade: "effect_verified",
                    scope: "provider_model_transport",
                    providerKind: "openAI",
                    modelId: "gpt-generation",
                    transport: "openai_responses",
                    generationRevision: "sha256:generation-r1",
                    evidenceRevision: "evidence-r1",
                  }],
                },
              },
            },
          },
        },
      }), {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          ETag: '"metadata-r1"',
        },
      }),
    );

    const [metadata, facade] = await Promise.all([
      import("../metadata-client"),
      import("@oriveo/core/providers/capability-evidence-facade"),
    ]);
    await metadata.initMetadata();
    const resolved = metadata.resolveCatalogModel("gpt-generation", "openAI");
    const profile = metadata.resolveGenerationProfileRef(
      resolved?.profiles.generation,
    );
    expect(profile?.revision).toBe("sha256:generation-r1");

    const query = {
      partitionId: "u1",
      connectionInstanceId: "openai-default",
      connectionGeneration: "cg1",
      credentialEpoch: "ce1",
      providerKind: "openAI",
      modelId: "gpt-generation",
      canonicalModelId: "gpt-generation",
      effectiveTransport: "openai_responses",
      metadataRevision: resolved?.metadataRevision,
      generationRevision: profile?.revision,
      now: 1,
      hasExplicitValue: false,
    };
    const current = facade.resolveCapabilityEvidence(
      "generation_parameter/temperature",
      query,
      resolved?.capabilityEvidenceCandidates ?? [],
    );
    expect(current).toMatchObject({
      support: "supported",
      source: "server_profile",
      requestPolicy: "allow",
    });

    const stale = facade.resolveCapabilityEvidence(
      "generation_parameter/temperature",
      { ...query, generationRevision: "sha256:generation-r2" },
      resolved?.capabilityEvidenceCandidates ?? [],
    );
    expect(stale).toMatchObject({
      support: "unknown",
      source: "none",
      reasonCode: "stale_generation",
      requestPolicy: "omit_unknown",
    });
  });

  it("requests lean, restores omitted candidate identity, resolves parametersRef, and preserves generation verdicts", async () => {
    const contractFixture = JSON.parse(readFileSync(
      "../../../shared/model-contracts/metadata_lean_contract.v1.json",
      "utf8",
    ));
    const responseFixture = structuredClone(contractFixture.leanResponse);
    const fixtureData = responseFixture.data;
    const fixtureModel = fixtureData.providers.openAI.models["gpt-fixture"];
    const parametersRef = fixtureModel.profiles.generation.parametersRef;
    fixtureModel.capabilityEvidenceView.candidates.push({
      key: "web_search",
      support: "supported",
      source: "server_typed",
      grade: "machine_verified",
      providerKind: "attacker",
    }, {
      key: "vision_input",
      support: "supported",
      source: "server_typed",
      grade: "machine_verified",
      scope: null,
    });
    fixtureData.providers.openAI.models["gpt-invalid-ref"] = {
      canonicalModelId: "gpt-invalid-ref",
      transport: "openai_chat_completions",
      profiles: {
        generation: {
          template: "openai_chat_completions",
          revision: "sha256:generation-r2",
          parametersRef: "sha256:missing-matrix",
          parameters: [{
            id: "temperature",
            support: "supported",
            source: "must_not_fallback",
          }],
        },
      },
    };
    fixtureData.providers.openAI.resolveMap["gpt-invalid-ref"] = "gpt-invalid-ref";
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify(responseFixture), {
      status: 200,
      headers: { "Content-Type": "application/json", ETag: '"lean-r1"' },
    }));

    const [metadata, evidence, facade] = await Promise.all([
      import("../metadata-client"),
      import("../../chat/capability-evidence"),
      import("@oriveo/core/providers/capability-evidence-facade"),
    ]);
    await metadata.initMetadata();

    expect(String(fetchSpy.mock.calls[0]?.[0])).toMatch(/\/api\/metadata\?view=lean$/);
    const resolved = metadata.resolveCatalogModel("gpt-fixture", "openAI");
    expect(resolved?.capabilityEvidenceCandidates).toEqual([expect.objectContaining({
      key: "tool_call",
      scope: "provider_model_transport",
      providerKind: "openAI",
      modelId: "gpt-fixture",
      transport: "openai_chat_completions",
    })]);

    const profile = metadata.resolveGenerationProfileRef(resolved?.profiles.generation);
    expect(profile?.parameters).toEqual(expect.arrayContaining([expect.objectContaining({
      id: "temperature",
      support: "supported",
      group: "sampling",
    })]));
    expect(metadata.getMetadataSnapshot()?.providers.openAI.models["gpt-fixture"]
      .profiles?.generation?.parameters).toEqual([
        expect.objectContaining({ id: "temperature", support: "supported" }),
        expect.objectContaining({ id: "top_p", support: "supported" }),
      ]);
    expect(metadata.resolveCatalogModel("gpt-invalid-ref", "openAI")
      ?.profiles.generation?.parameters).toBeUndefined();

    const provider = {
      id: "openai-1",
      kind: "openAI",
      authMode: "apiKey",
      models: [],
    } as never;
    const model = {
      id: "gpt-fixture",
      canonicalModelId: "gpt-fixture",
      transport: "openai_chat_completions",
      capabilities: ["text"],
      generationProfile: resolved?.profiles.generation,
    } as never;
    const leanVerdict = evidence.resolveGenerationParameterEvidence({
      provider,
      model,
      profile: profile!,
      parameterId: "temperature",
      hasExplicitValue: false,
    });
    const fullVerdict = facade.resolveCapabilityEvidence(
      "generation_parameter/temperature",
      {
        partitionId: "guest",
        connectionInstanceId: "",
        connectionGeneration: "",
        credentialEpoch: "",
        providerKind: "openAI",
        modelId: "gpt-fixture",
        canonicalModelId: "gpt-fixture",
        effectiveTransport: "openai_chat_completions",
        metadataRevision: '"lean-r1"',
        generationRevision: fixtureModel.profiles.generation.revision,
        now: Date.now(),
        hasExplicitValue: false,
      },
      [{
        key: "generation_parameter/temperature",
        support: "supported",
        source: "server_profile",
        grade: "effect_verified",
        scope: "provider_model_transport",
        providerKind: "openAI",
        modelId: "gpt-fixture",
        transport: "openai_chat_completions",
        metadataRevision: '"lean-r1"',
        generationRevision: fixtureModel.profiles.generation.revision,
      }],
    );
    expect(parametersRef).toMatch(/^sha256:/);
    expect(leanVerdict).toMatchObject({
      support: fullVerdict.support,
      source: fullVerdict.source,
      requestPolicy: fullVerdict.requestPolicy,
    });
  });

  it("parses model toolCall and falls back field by field for the Library runtime config", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-07-24T10:00:00Z",
          profiles: {},
          providers: {
            openAI: {
              defaultModelId: "gpt-library",
              resolveMap: { "gpt-library": "gpt-library" },
              models: {
                "gpt-library": {
                  canonicalModelId: "gpt-library",
                  capabilities: ["text"],
                  toolCall: true,
                },
                "gpt-no-tools": {
                  canonicalModelId: "gpt-no-tools",
                  capabilities: ["text"],
                },
              },
            },
          },
          libraryRuntimeConfig: {
            version: 2,
            toolDescriptions: {
               library_search: "Custom search description",
              library_read: "",
            },
            maxSteps: 8,
            toolTimeoutMs: -1,
            maxEmptyHits: 0,
            maxSelfCorrections: "invalid",
            tokenBudget: 12_000,
            estimatedTokensPerStep: 3_000,
            highCostConfirmationUSD: 0.5,
            weakModelDenylist: ["weak-model", 42, "  second-model  "],
            sensitiveGateEnabled: false,
          },
        },
      });
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(
      metadata.resolveCatalogModel("gpt-library", "openAI")?.toolCall,
    ).toBe(true);
    // Missing means unknown, not false: a model the server could not probe must not be collapsed into "confirmed unsupported".
    expect(
      metadata.resolveCatalogModel("gpt-no-tools", "openAI")?.toolCall,
    ).toBeUndefined();
    expect(
      metadata.getMetadataSnapshot()?.providers.openAI.models["gpt-library"]
        .toolCall,
    ).toBe(true);
    expect(metadata.getLibraryRuntimeConfig()).toEqual({
      version: 2,
      toolDescriptions: {
        ...metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.toolDescriptions,
         library_search: "Custom search description",
      },
      maxSteps: 8,
      toolTimeoutMs: metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.toolTimeoutMs,
      maxEmptyHits: 0,
      maxSelfCorrections:
        metadata.DEFAULT_LIBRARY_RUNTIME_CONFIG.maxSelfCorrections,
      tokenBudget: 12_000,
      estimatedTokensPerStep: 3_000,
      highCostConfirmationUSD: 0.5,
      weakModelDenylist: ["weak-model", "second-model"],
      sensitiveGateEnabled: false,
      // Bundled catalog default: server research off
      serverResearchEnabled: false,
    });
  });

  it("v2 decoding preserves true / false / null and exposes the root-level capability contract version", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 2,
          contractVersion: 1,
          capabilityContractVersion: 3,
          updatedAt: "2026-08-07T10:00:00Z",
          profiles: {},
          providers: {
            openAI: {
              resolveMap: { yes: "yes", no: "no", unknown: "unknown" },
              models: {
                yes: { canonicalModelId: "yes", toolCall: true, libraryAgentic: true },
                no: { canonicalModelId: "no", toolCall: false, libraryAgentic: false },
                unknown: { canonicalModelId: "unknown", toolCall: null, libraryAgentic: null },
              },
            },
          },
        },
      });
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(metadata.getCapabilityContractVersion()).toBe(3);
    expect(metadata.getMetadataSnapshot()?.capabilityContractVersion).toBe(3);
    expect(metadata.resolveCatalogModel("yes", "openAI")).toMatchObject({
      capabilityContractVersion: 3,
      toolCall: true,
      libraryAgentic: true,
    });
    expect(metadata.resolveCatalogModel("no", "openAI")).toMatchObject({
      toolCall: false,
      libraryAgentic: false,
    });
    expect(metadata.resolveCatalogModel("unknown", "openAI")).toMatchObject({
      toolCall: null,
      libraryAgentic: null,
    });
  });

  it("passes optional v4/v5/v6 fields through and leaves missing ones undefined for the resolver to handle", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-07-27T10:00:00Z",
          profiles: {},
          providers: {},
          libraryRuntimeConfig: {
            version: 6,
            enabled: false,
            availableProviders: ["notion", "google"],
            directMaxDocuments: 8,
            directContextMaxChars: 40_000,
            serverResearchEnabled: true,
            serverResearchProviderDenylist: ["relay"],
            serverResearchMaxDocuments: 3,
          },
        },
      });
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    const config = metadata.getLibraryRuntimeConfig();
    expect(config.enabled).toBe(false);
    expect(config.availableProviders).toEqual(["notion", "google"]);
    expect(config.directMaxDocuments).toBe(8);
    expect(config.directContextMaxChars).toBe(40_000);
    expect(config.serverResearchEnabled).toBe(true);
    expect(config.serverResearchProviderDenylist).toEqual(["relay"]);
    expect(config.serverResearchMaxDocuments).toBe(3);
  });

  it("parses the authoritative libraryAgentic flag and keeps 'not sent' distinguishable from 'sent as false'", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-07-27T10:00:00Z",
          profiles: {},
          providers: {
            openAI: {
              defaultModelId: "gpt-agentic",
              resolveMap: {
                "gpt-agentic": "gpt-agentic",
                "gpt-blocked": "gpt-blocked",
                "gpt-legacy": "gpt-legacy",
              },
              models: {
                "gpt-agentic": {
                  canonicalModelId: "gpt-agentic",
                  capabilities: ["text"],
                  toolCall: true,
                  libraryAgentic: true,
                },
                "gpt-blocked": {
                  canonicalModelId: "gpt-blocked",
                  capabilities: ["text"],
                  toolCall: true,
                  libraryAgentic: false,
                },
                "gpt-legacy": {
                  canonicalModelId: "gpt-legacy",
                  capabilities: ["text"],
                  toolCall: true,
                },
              },
            },
          },
        },
      });
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(
      metadata.resolveCatalogModel("gpt-agentic", "openAI")?.libraryAgentic,
    ).toBe(true);
    expect(
      metadata.resolveCatalogModel("gpt-blocked", "openAI")?.libraryAgentic,
    ).toBe(false);
    // Older servers do not send it: it must stay undefined, since flattening to false would make the entry point vanish for a whole batch of models.
    expect(
      metadata.resolveCatalogModel("gpt-legacy", "openAI")?.libraryAgentic,
    ).toBeUndefined();
  });

  it("parses runtimeConfig and reads feature flags with a default-on semantic", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          code: 0,
          message: "ok",
          data: {
            version: 8,
            updatedAt: "2026-07-04T10:00:00Z",
            profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
            providers: {},
            runtimeConfig: {
              featureFlags: { imageGen: false },
              appGate: {
                ios: { minSupportedBuild: 0, storeUrl: "", message: "" },
                android: { minSupportedBuild: 0, storeUrl: "", message: "" },
                maintenanceBanner: {
                  id: "ops-1",
                  text: "Under maintenance",
                  level: "warn",
                },
              },
              freeAccessGrant: {
                limits: {
                  customSkills: 2,
                  pinnedSkills: 2,
                  pinnedConversations: 2,
                  folders: 3,
                  syncDevices: 1,
                  storageBytes: 0,
                  singleFileBytes: 26214400,
                },
                features: {},
              },
              selfHealPatterns: [
                { pattern: "unsupported parameter", flags: "i" },
                // Padded on purpose: the client has to trim `param` before it can be matched
                // against the field named in an upstream 400.
                {
                  pattern: "must be verified to generate reasoning summaries",
                  flags: "i",
                  param: "  reasoning.summary  ",
                },
              ],
              networkPolicy: {
                chatTimeoutSecs: 60,
                streamTimeoutSecs: 120,
                imageGenTimeoutSecs: 180,
                keyValidationTimeoutSecs: 18,
                upstreamFirstByteTimeoutSecs: 120,
              },
              promptBudget: {
                totalChars: 12000,
                pinnedNotesMaxCount: 3,
                pinnedNotesBudgetChars: 6000,
                noteRecallLimit: 2,
              },
              attachment: {
                maxFiles: 3,
                maxNativeBytesByProvider: {
                  default: 26214400,
                  gemini: 20971520,
                },
              },
              budgetAlert: { thresholds: [50, 70, 80, 90], debounceMins: 30 },
            },
          },
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      ),
    );

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(metadata.getMetadataVersion()).toBe(8);
    expect(metadata.getRuntimeConfig()).toMatchObject({
      featureFlags: { imageGen: false },
      appGate: { maintenanceBanner: { id: "ops-1", level: "warn" } },
      freeAccessGrant: { limits: { folders: 3 } },
      selfHealPatterns: [
        { pattern: "unsupported parameter", flags: "i" },
        {
          pattern: "must be verified to generate reasoning summaries",
          flags: "i",
          param: "reasoning.summary",
        },
      ],
    });
    expect(metadata.isRuntimeFeatureEnabled("imageGen")).toBe(false);
    expect(metadata.isRuntimeFeatureEnabled("webSearch")).toBe(true);
  });

  it('expands generation references against the same metadata schema and injects nothing for unknown references', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({
      code: 0,
      data: {
        version: 1,
        updatedAt: '2026-08-05T00:00:00Z',
        profiles: {
          reasoning: {}, webSearch: {}, imageGen: {},
          generation: {
            parameters: {
              temperature: {
                group: 'sampling',
                valueSchema: 'number',
                range: { min: 0, max: 2 },
                interactionGroup: 'sampling_strategy',
                conflictsWith: ['top_p'],
                constraints: [{ mode: 'normal' }],
                portability: 'portable',
                risk: 'normal',
              },
            },
            templates: { vllm_extra_body: { wire: { top_k: 'extra_body.top_k' } } },
          },
        },
        providers: {},
      },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }));

    const metadata = await import('../metadata-client');
    await metadata.initMetadata();

    expect(metadata.resolveGenerationProfileRef({
      template: 'vllm_extra_body',
      revision: 'sha256:profile-r1',
      parameters: [{ id: 'temperature', support: 'accepted_unverified', source: 'engine_profile' }],
    })).toEqual({
      template: 'vllm_extra_body',
      revision: 'sha256:profile-r1',
      wire: { top_k: 'extra_body.top_k' },
      parameters: [{
        id: 'temperature', support: 'accepted_unverified', source: 'engine_profile',
        group: 'sampling', valueSchema: 'number', range: { min: 0, max: 2 },
        interactionGroup: 'sampling_strategy', conflictsWith: ['top_p'], constraints: [{ mode: 'normal' }], portability: 'portable', risk: 'normal',
      }],
    });
    expect(metadata.resolveGenerationProfileRef({ template: 'not_declared' })).toBeUndefined();
    expect(metadata.resolveGenerationProfileRef({
      template: 'vllm_extra_body',
      revision: 'bad\nrevision',
      parameters: [],
    })).not.toHaveProperty('revision');
  });

  it('model-level generation enumValues override the shared schema globals, and fall back to the globals when absent', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({
      code: 0,
      data: {
        version: 1,
        updatedAt: '2026-08-07T00:00:00Z',
        profiles: {
          reasoning: {}, webSearch: {}, imageGen: {},
          generation: {
            parameters: {
              reasoning_effort: {
                group: 'reasoning',
                valueSchema: 'string',
                enumValues: ['low', 'medium', 'high', 'xhigh'],
              },
            },
            templates: { openai_responses: { wire: { reasoning_effort: 'reasoning.effort' } } },
          },
        },
        providers: {},
      },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }));

    const metadata = await import('../metadata-client');
    await metadata.initMetadata();

    const narrowed = metadata.resolveGenerationProfileRef({
      template: 'openai_responses',
      parameters: [{
        id: 'reasoning_effort', support: 'supported', source: 'authoritative_metadata',
        enumValues: ['low', 'high'],
      }],
    });
    expect(narrowed?.parameters?.[0]?.enumValues).toEqual(['low', 'high']);

    const fallback = metadata.resolveGenerationProfileRef({
      template: 'openai_responses',
      parameters: [{ id: 'reasoning_effort', support: 'supported', source: 'provider_metadata' }],
    });
    expect(fallback?.parameters?.[0]?.enumValues).toEqual(['low', 'medium', 'high', 'xhigh']);
  });

  it("stops inferring legacy mappings on the client when resolveMap is missing", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-03-26T10:00:00Z",
          profiles: {},
          providers: {
            anthropic: {
              models: {
                "claude-sonnet-4-6": {
                  canonicalModelId: "claude-sonnet-4-6",
                  displayName: "Claude Sonnet 4.6",
                  pricing: {
                    promptPerMToken: 3,
                    completionPerMToken: 15,
                  },
                  capabilities: ["text", "image", "file", "reasoning"],
                  profiles: {
                    reasoning: "ant_adaptive",
                  },
                },
              },
            },
          },
        },
      });

    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(
      metadata.lookupCapabilities("claude-sonnet-4-6-20250929", "anthropic"),
    ).toBeNull();
  });

  it("getReasoningProfile returns the complete reasoning profile definition", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-07-04T10:00:00Z",
          profiles: {
            reasoning: {
              kimi_thinking: {
                levels: ["fast", "deep"],
                params: {
                  deep: { thinking: { type: "enabled", budget_tokens: 8192 } },
                },
                streamShape: { reasoningDeltaPath: "delta.reasoning_content" },
              },
            },
            webSearch: {},
            imageGen: {},
          },
          providers: {},
        },
      });

    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(metadata.getReasoningProfile("kimi_thinking")).toEqual({
      name: "kimi_thinking",
      levels: ["fast", "deep"],
      params: {
        deep: { thinking: { type: "enabled", budget_tokens: 8192 } },
      },
      streamShape: { reasoningDeltaPath: "delta.reasoning_content" },
    });
    expect(metadata.getReasoningProfile(null)).toBeNull();
    expect(metadata.getReasoningProfile("missing")).toBeNull();
  });

  it("normalizes OpenAI snapshot model IDs with a dashed date even without an alias", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-03-27T10:00:00Z",
          profiles: {},
          providers: {
            openAI: {
              defaultModelId: "gpt-5.4-nano",
              resolveMap: {
                "gpt-5.4-nano": "gpt-5.4-nano",
              },
              models: {
                "gpt-5.4-nano": {
                  canonicalModelId: "gpt-5.4-nano",
                  displayName: "GPT-5.4 nano",
                  pricing: {
                    promptPerMToken: 0.2,
                    completionPerMToken: 1.25,
                  },
                  capabilities: ["text", "image", "reasoning"],
                  profiles: {
                    reasoning: "oai_responses",
                  },
                },
              },
            },
          },
        },
      });

    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    const resolved = metadata.resolveCatalogModel(
      "gpt-5.4-nano-2026-03-01",
      "openAI",
    );
    expect(resolved).toMatchObject({
      canonicalModelId: "gpt-5.4-nano",
      displayName: "GPT-5.4 nano",
      isDefault: true,
    });

    const pricing = metadata.lookupPricing("gpt-5.4-nano-2026-03-01", "openAI");
    expect(pricing?.promptPerToken).toBeCloseTo(0.0000002, 15);
    expect(pricing?.completionPerToken).toBeCloseTo(0.00000125, 15);
  });

  it("exposes providerConfigs and returns them in sortOrder", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-04-08T10:00:00Z",
          profiles: {},
          providers: {},
          providerConfigs: [
            {
              kind: "qwen",
              displayName: "Qwen",
              defaultBaseURL:
                "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
              sortOrder: 20,
              regionOptions: [
                {
                  id: "sg",
                  label: "Singapore",
                  baseURL:
                    "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                },
              ],
            },
            {
              kind: "miniMax",
              displayName: "MiniMax",
              defaultBaseURL: "https://api.minimax.io/v1",
              sortOrder: 10,
            },
          ],
        },
      });

    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(
      metadata.listPublicProviderConfigs().map((item) => item.kind),
    ).toEqual(["miniMax", "qwen"]);
    expect(metadata.getPublicProviderConfig("qwen")?.regionOptions).toEqual([
      {
        id: "sg",
        label: "Singapore",
        baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      },
    ]);
    expect(metadata.hasPublicProviderConfigSource()).toBe(true);
  });

  it("exposes the relay probePolicy so the web probe runner can read it", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-04-21T10:00:00Z",
          profiles: {},
          providers: {},
          providerConfigs: [
            {
              kind: "relay",
              displayName: "Relay",
              defaultBaseURL: "https://relay.example.com",
              protocolFeatures: {
                probePolicy: {
                  version: 1,
                  defaultFamilyHint: "unknown",
                  apiRootCandidates: [{ rootPath: "/v1", priority: "default" }],
                  preflightFingerprints: [
                    {
                      name: "new-api",
                      path: "/api/status",
                      method: "GET",
                      inferTransports: ["openai_responses"],
                      inferApiRoot: "/v1",
                    },
                  ],
                  catalogDiscovery: [
                    {
                      kind: "openai_models",
                      path: "/models",
                      authModes: ["bearer"],
                    },
                  ],
                  transportOrder: {
                    openai: ["openai_responses"],
                    anthropic: [],
                    gemini: [],
                    unknown: ["openai_chat_completions"],
                  },
                  transportSteps: [],
                  failureFingerprints: [],
                  fallbackPolicy: {
                    allowManualModel: true,
                    requireCatalogBeforeManual: false,
                  },
                  probeBudget: {
                    maxConcurrency: 4,
                    maxPreflightRequests: 2,
                    maxCatalogRequests: 4,
                    maxHandshakeAttempts: 2,
                    maxDurationMs: 10000,
                    abortOnRateLimit: true,
                  },
                  stopRules: {
                    stopOnFirstTransportSuccess: true,
                    stopOnAuthFailure: true,
                    stopOnCliOnlyFingerprint: true,
                    stopOnBudgetExceeded: true,
                  },
                  userAgent: {
                    template: "Oriveo/{version} ({platform})",
                    applyOn: "native_only",
                  },
                },
              },
            },
          ],
        },
      });

    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(metadata.getRelayProbePolicy()).toMatchObject({
      version: 1,
      apiRootCandidates: [{ rootPath: "/v1", priority: "default" }],
      probeBudget: {
        maxPreflightRequests: 2,
        maxCatalogRequests: 4,
        maxHandshakeAttempts: 2,
      },
    });
  });

  it("keeps the enhanced fields of non-token billing models and stops lookupPricing from returning token prices for them", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-04-20T10:00:00Z",
          profiles: {},
          providers: {
            openAI: {
              defaultModelId: "gpt-image-1",
              resolveMap: {
                "gpt-image-1": "gpt-image-1",
              },
              models: {
                "gpt-image-1": {
                  canonicalModelId: "gpt-image-1",
                  displayName: "GPT Image 1",
                  billingSku: "gpt-image-1/payg",
                  pricingUnit: "per_image",
                  sourceSummary: {
                    sourceKind: "official_registry",
                    sourceName: "OpenAI Pricing Registry",
                    fetchedAt: "2026-04-20T10:00:00Z",
                  },
                  pricing: {
                    promptPerMToken: null,
                    completionPerMToken: null,
                    costPerUnit: 0.04,
                    costInputBatches: 0.5,
                  },
                  pricingStatus: "priced",
                  capabilities: ["text", "imageGeneration"],
                  supportsPdfInput: true,
                  supportsServiceTier: true,
                  profiles: {},
                },
              },
            },
          },
        },
      });

    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    const resolved = metadata.resolveCatalogModel("gpt-image-1", "openAI");
    expect(resolved).toMatchObject({
      canonicalModelId: "gpt-image-1",
      billingSku: "gpt-image-1/payg",
      pricingUnit: "per_image",
      supportsPdfInput: true,
      supportsServiceTier: true,
      sourceSummary: {
        sourceKind: "official_registry",
        sourceName: "OpenAI Pricing Registry",
      },
    });
    expect(resolved?.pricing).toMatchObject({
      promptPerToken: null,
      completionPerToken: null,
      costPerUnit: 0.04,
      costInputBatches: 0.5,
    });
    expect(metadata.lookupPricing("gpt-image-1", "openAI")).toBeNull();
  });

  it("getProviderAttachmentSupport returns the provider-level attachment protocol config", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-04-10T10:00:00Z",
          profiles: {},
          providers: {
            siliconFlow: {
              displayName: "SiliconFlow",
              attachmentSupport: {
                image: true,
                nativeFile: false,
                textFileInline: true,
              },
              resolveMap: {},
              models: {},
            },
            miniMax: {
              displayName: "MiniMax",
              attachmentSupport: {
                image: false,
                nativeFile: false,
                textFileInline: true,
              },
              resolveMap: {},
              models: {},
            },
            deepseek: {
              displayName: "DeepSeek",
              attachmentSupport: {
                image: false,
                nativeFile: false,
                textFileInline: true,
              },
              resolveMap: {},
              models: {},
            },
            moonshot: {
              displayName: "Kimi",
              attachmentSupport: {
                image: true,
                nativeFile: false,
                textFileInline: true,
              },
              resolveMap: {},
              models: {},
            },
          },
        },
      });

    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    const sfSupport = metadata.getProviderAttachmentSupport("siliconFlow");
    expect(sfSupport).toEqual({
      image: true,
      nativeFile: false,
      textFileInline: true,
    });

    const mmSupport = metadata.getProviderAttachmentSupport("miniMax");
    expect(mmSupport).toEqual({
      image: false,
      nativeFile: false,
      textFileInline: true,
    });

    const deepSeekSupport = metadata.getProviderAttachmentSupport("deepseek");
    expect(deepSeekSupport).toEqual({
      image: false,
      nativeFile: false,
      textFileInline: true,
    });

    const kimiSupport = metadata.getProviderAttachmentSupport("moonshot");
    expect(kimiSupport).toEqual({
      image: true,
      nativeFile: false,
      textFileInline: true,
    });

    expect(metadata.getProviderAttachmentSupport("nonExistent")).toBeNull();
  });

  it("distinguishes a missing providerConfigs from an explicitly empty array", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-04-08T10:00:00Z",
          profiles: {},
          providers: {},
        },
      });

    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    expect(metadata.hasPublicProviderConfigSource()).toBe(false);
    expect(metadata.listPublicProviderConfigs()).toEqual([]);
  });

  it("getRelayRuntimeConfig falls back to the built-in defaults when the backend sends nothing", async () => {
    // No relayRuntimeConfig field, so the built-in defaults apply.
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-04-23T10:00:00Z",
          profiles: {},
          providers: {},
        },
      });
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    const runtime = metadata.getRelayRuntimeConfig();
    expect(runtime.version).toBe("fallback");
    expect(runtime.officialProviderWhitelist).toEqual(
      expect.arrayContaining([
        "openAI",
        "anthropic",
        "gemini",
        "deepseek",
        "miniMax",
        "zhipu",
        "qwen",
      ]),
    );
    expect(runtime.transportEnvelopes.openai_responses.webSearch).toBe(true);
    expect(runtime.transportEnvelopes.openai_chat_completions.webSearch).toBe(
      false,
    );
    expect(runtime.transportEnvelopes.anthropic_messages.webSearch).toBe(false);
    expect(runtime.featureGatingPolicy.showActualModelIdHint).toBe(true);
    expect(runtime.featureGatingPolicy.showSoftFailHint).toBe(true);
  });

  it("getRelayRuntimeConfig passes backend rules through and falls back field by field for missing ones", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-04-23T10:00:00Z",
          profiles: {},
          providers: {},
          relayRuntimeConfig: {
            version: "2026-04-23-1",
            officialProviderWhitelist: ["openAI", "anthropic"],
            transportEnvelopes: {
              openai_responses: {
                webSearch: false, //  
              },
            },
            transportRules: {
              openai_responses: {
                defaultAuthMode: "query_key",
                codexIdentityDefault: false,
              },
            },
            verificationPolicy: {
              hardFailedExpiryDays: 14,
              softFailedRetryAfterSeconds: 120,
              verifiedCacheDays: 60,
            },
            featureGatingPolicy: {
              showActualModelIdHint: false,
              showSoftFailHint: true,
            },
          },
        },
      });
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    const runtime = metadata.getRelayRuntimeConfig();
    expect(runtime.version).toBe("2026-04-23-1");
    expect(runtime.officialProviderWhitelist).toEqual(["openAI", "anthropic"]);
    expect(runtime.transportEnvelopes.openai_responses.webSearch).toBe(false);
    expect(runtime.transportEnvelopes.openai_responses.image).toBe(true);
    expect(runtime.transportRules.openai_responses.defaultAuthMode).toBe(
      "query_key",
    );
    expect(runtime.transportRules.openai_responses.codexIdentityDefault).toBe(
      false,
    );
    expect(runtime.transportRules.openai_responses.imageRoute).toBe(
      "inline_responses_tool",
    );
    // Transports the backend did not send fall back to the defaults.
    expect(runtime.transportEnvelopes.anthropic_messages.image).toBe(true);
    expect(runtime.transportRules.anthropic_messages.defaultAuthMode).toBe(
      "x_api_key",
    );
    expect(runtime.verificationPolicy.hardFailedExpiryDays).toBe(14);
    expect(runtime.featureGatingPolicy.showActualModelIdHint).toBe(false);
    expect(runtime.featureGatingPolicy.showSoftFailHint).toBe(true);
  });

  it("resolveCatalogModelAcrossProvidersWithProvider matches across providers and returns matchedProviderKind", async () => {
    await seedMetadataCache({
        timestamp: Date.now(),
        data: {
          version: 1,
          contractVersion: 1,
          updatedAt: "2026-04-23T10:00:00Z",
          profiles: {},
          providers: {
            openAI: {
              defaultModelId: "gpt-5.4",
              resolveMap: { "gpt-5.4": "gpt-5.4" },
              models: {
                "gpt-5.4": {
                  canonicalModelId: "gpt-5.4",
                  displayName: "GPT-5.4",
                  capabilities: ["text", "image", "web", "reasoning"],
                  profiles: {
                    reasoning: "oai_responses",
                    webSearch: "oai_web",
                  },
                },
              },
            },
            anthropic: {
              defaultModelId: "claude-sonnet-4.5",
              resolveMap: { "claude-sonnet-4.5": "claude-sonnet-4.5" },
              models: {
                "claude-sonnet-4.5": {
                  canonicalModelId: "claude-sonnet-4.5",
                  displayName: "Claude Sonnet 4.5",
                  capabilities: ["text", "image", "reasoning"],
                  profiles: { reasoning: "anthropic_reasoning" },
                },
              },
            },
          },
        },
      });
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      status: 304,
      ok: false,
      json: vi.fn(),
    } as unknown as Response);

    const metadata = await import("../metadata-client");
    await metadata.initMetadata();

    // Without transportPriority, cross_provider matching lands on OpenAI.
    const gpt =
      metadata.resolveCatalogModelAcrossProvidersWithProvider("gpt-5.4");
    expect(gpt?.matchedProviderKind).toBe("openAI");
    expect(gpt?.canonicalModelId).toBe("gpt-5.4");
    expect(gpt?.metadata.displayName).toBe("GPT-5.4");
    expect(gpt?.source).toBe("cross_provider");

    // With a transport preference, matching is transport_first.
    const claude = metadata.resolveCatalogModelAcrossProvidersWithProvider(
      "claude-sonnet-4.5",
      {
        transportPriority: "anthropic",
      },
    );
    expect(claude?.matchedProviderKind).toBe("anthropic");
    expect(claude?.source).toBe("transport_first");

    // unknown model → null
    expect(
      metadata.resolveCatalogModelAcrossProvidersWithProvider(
        "my-custom-model",
      ),
    ).toBeNull();
  });

  /**
   * The negative conclusion of library routing ("this model cannot search automatically")
   * is gated on this flag. The localStorage cache can be stuck at any moment in history, and
   * drawing that negative conclusion from it before this session has confirmed it is exactly the
   * cold-start misjudgement that only an async refresh papers over later.
   */
  describe("per-session snapshot confirmation flag", () => {
    const payload = {
      version: 1,
      updatedAt: "2026-07-28T00:00:00Z",
      profiles: {},
      providers: {},
      providerConfigs: [],
    };

    it("unconfirmed before a refresh", async () => {
      const metadata = await import("../metadata-client");
      metadata.__resetMetadataClientForTest();
      expect(metadata.isMetadataSnapshotConfirmed()).toBe(false);
    });

    it("a 200 sets the flag", async () => {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(
        new Response(JSON.stringify(payload), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
      const metadata = await import("../metadata-client");
      metadata.__resetMetadataClientForTest();

      await metadata.refreshMetadata();

      expect(metadata.isMetadataSnapshotConfirmed()).toBe(true);
    });

    it("a 304 sets it the same way: the backend confirmed the local copy is current", async () => {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(
        new Response(null, { status: 304 }),
      );
      const metadata = await import("../metadata-client");
      metadata.__resetMetadataClientForTest();

      await metadata.refreshMetadata();

      expect(metadata.isMetadataSnapshotConfirmed()).toBe(true);
    });

    it("the first 304 with a local snapshot advances the client revision once, repeated 304s do not", async () => {
      const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
        new Response(JSON.stringify(payload), {
          status: 200,
          headers: { "Content-Type": "application/json", ETag: '"cached-etag"' },
        }),
      );
      const metadata = await import("../metadata-client");
      metadata.__resetMetadataClientForTest();
      await metadata.refreshMetadata();
      await new Promise((resolve) => setTimeout(resolve, 20));

      metadata.__resetMetadataClientForTest();
      fetchSpy.mockResolvedValue(new Response(null, { status: 304 }));
      await metadata.initMetadata();
      await vi.waitFor(() => {
        expect(metadata.isMetadataSnapshotConfirmed()).toBe(true);
      });
      const confirmedRevision = metadata.getCachedMetadataVersion();
      expect(confirmedRevision).toBe(2); // cache hydrate + first-session confirmation

      await metadata.refreshMetadata();
      expect(metadata.getCachedMetadataVersion()).toBe(confirmedRevision);
    });
  });

  /**
   * The display side must use the same criteria as the injection side: injection with no profile
   * injects nothing, so showing all five tiers would mean five decorative tiers and zero injected
   * fields. The criteria match resolveSupportedReasoningModes in
   * packages/core request-builders/runtime.ts word for word.
   */
  describe("getSupportedReasoningModes display narrowing", () => {
    async function loadWithProfiles(
      reasoning: Record<string, { levels?: string[]; defaultLevel?: string }>,
    ) {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(
        new Response(
          JSON.stringify({
            version: 1,
            updatedAt: "2026-08-07T00:00:00Z",
            profiles: { reasoning, webSearch: {}, imageGen: {} },
            providers: {},
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      );
      const metadata = await import("../metadata-client");
      metadata.__resetMetadataClientForTest();
      await metadata.refreshMetadata();
      return metadata;
    }

    it("a profile name that is not in the snapshot (server withdrawal, stale snapshot) leaves only Auto", async () => {
      const metadata = await loadWithProfiles({ oai_responses: { levels: ["fast", "max"] } });
      expect(metadata.getSupportedReasoningModes("withdrawn_profile")).toEqual(["automatic"]);
    });

    it("a profile that declares no levels also leaves only Auto", async () => {
      const metadata = await loadWithProfiles({ empty_profile: {} });
      expect(metadata.getSupportedReasoningModes("empty_profile")).toEqual(["automatic"]);
    });

    it("shows only the tiers the levels list actually contains", async () => {
      const metadata = await loadWithProfiles({
        deepseek_thinking: { levels: ["fast", "balanced", "deep", "max"] },
        kimi_thinking: { levels: ["fast", "max"] },
      });
      expect(metadata.getSupportedReasoningModes("deepseek_thinking")).toEqual([
        "automatic", "fast", "balanced", "deep", "max",
      ]);
      expect(metadata.getSupportedReasoningModes("kimi_thinking")).toEqual([
        "automatic", "fast", "max",
      ]);
    });

    it("stays fail-open when there is no profile name, the documented relay exception", async () => {
      // A relay custom endpoint has no matching provider in the official catalog, so
      // reasoningProfile is always empty. Narrowing this branch too would make clampReasoningMode
      // clamp the user's chosen tier to automatic and drop relay's reasoning_effort entirely.
      const metadata = await loadWithProfiles({ oai_responses: { levels: ["fast"] } });
      expect(metadata.getSupportedReasoningModes(null)).toEqual([
        "automatic", "fast", "balanced", "deep", "max",
      ]);
      expect(metadata.getSupportedReasoningModes("  ")).toEqual([
        "automatic", "fast", "balanced", "deep", "max",
      ]);
    });

    it("stays fail-open while the snapshot has not arrived", async () => {
      const metadata = await import("../metadata-client");
      metadata.__resetMetadataClientForTest();
      expect(metadata.getSupportedReasoningModes("oai_responses")).toEqual([
        "automatic", "fast", "balanced", "deep", "max",
      ]);
    });

    it("tiers declared by the evidence adapter do not inherit the relay or cold-start fail-open of the display side", async () => {
      const metadata = await loadWithProfiles({
        oai_responses: { levels: ["fast", "deep", "unknown_future_level"] },
      });
      expect(metadata.getDeclaredReasoningLevels("oai_responses")).toEqual([
        "fast", "deep",
      ]);
      expect(metadata.getDeclaredReasoningLevels("withdrawn_profile")).toEqual([]);
      expect(metadata.getDeclaredReasoningLevels(null)).toEqual([]);

      metadata.__resetMetadataClientForTest();
      expect(metadata.getDeclaredReasoningLevels("oai_responses")).toEqual([]);
    });

    it("returns the production reasoning defaultLevel strictly and never guesses a tier when it is missing or undeclared", async () => {
      const metadata = await loadWithProfiles({
        valid: { levels: ["fast", "deep"], defaultLevel: "deep" },
        absent: { levels: ["fast"] },
        notDeclared: { levels: ["fast"], defaultLevel: "deep" },
        unknown: { levels: ["fast", "turbo"], defaultLevel: "turbo" },
      });

      expect(metadata.getDeclaredReasoningDefaultLevel("valid")).toBe("deep");
      expect(metadata.getDeclaredReasoningDefaultLevel("absent")).toBeUndefined();
      expect(metadata.getDeclaredReasoningDefaultLevel("notDeclared")).toBeUndefined();
      expect(metadata.getDeclaredReasoningDefaultLevel("unknown")).toBeUndefined();
      expect(metadata.getDeclaredReasoningDefaultLevel("withdrawn")).toBeUndefined();
      expect(metadata.getDeclaredReasoningDefaultLevel(null)).toBeUndefined();
    });
  });

  it("resolveCatalogModel passes production profiles.generation.revision through exactly, keeping no stale value when it changes or goes missing", async () => {
    // Without pass-through, profiles.generation would always be undefined and
    // catalog-model.enrichStoredModel could not authoritatively withdraw a generationProfile.
    const buildPayload = (
      withGeneration: boolean,
      generationRevision?: unknown,
    ) => ({
      version: 1,
      updatedAt: "2026-08-07T00:00:00Z",
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        openAI: {
          resolveMap: { "gpt-5-pro": "gpt-5-pro" },
          models: {
            "gpt-5-pro": {
              canonicalModelId: "gpt-5-pro",
              capabilities: ["text"],
              profiles: withGeneration
                ? {
                  generation: {
                    template: "openai_responses",
                    ...(generationRevision !== undefined
                      ? { revision: generationRevision }
                      : {}),
                    parameters: [
                      { id: "max_output_tokens", support: "supported", source: "authoritative_metadata" },
                    ],
                  },
                }
                : {},
            },
          },
        },
      },
    });

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify(buildPayload(true, "sha256:profile-r1")), {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          ETag: '"metadata-r1"',
        },
      }),
    );
    const metadata = await import("../metadata-client");
    metadata.__resetMetadataClientForTest();
    await metadata.refreshMetadata();

    expect(metadata.resolveCatalogModel("gpt-5-pro", "openAI")?.profiles.generation).toEqual({
      template: "openai_responses",
      revision: "sha256:profile-r1",
      parameters: [
        { id: "max_output_tokens", support: "supported", source: "authoritative_metadata" },
      ],
    });
    expect(metadata.resolveCatalogModel("gpt-5-pro", "openAI")?.metadataRevision)
      .toBe('"metadata-r1"');
    expect(metadata.getMetadataSnapshot()?.providers.openAI.models["gpt-5-pro"]
      .profiles?.generation?.revision).toBe("sha256:profile-r1");

    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify(buildPayload(true, "sha256:profile-r2")), {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          ETag: '"metadata-r2"',
        },
      }),
    );
    await metadata.refreshMetadata();
    expect(metadata.resolveCatalogModel("gpt-5-pro", "openAI")?.profiles.generation)
      .toMatchObject({ revision: "sha256:profile-r2" });
    expect(metadata.resolveCatalogModel("gpt-5-pro", "openAI")?.metadataRevision)
      .toBe('"metadata-r2"');

    // The older protocol still carries a generation profile but no separate semantic revision:
    // r2 must not be retained, and the consumer must fall back explicitly to the current metadata ETag.
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify(buildPayload(true)), {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          ETag: '"metadata-r3"',
        },
      }),
    );
    await metadata.refreshMetadata();
    expect(metadata.resolveCatalogModel("gpt-5-pro", "openAI")?.profiles.generation)
      .not.toHaveProperty("revision");
    expect(metadata.resolveCatalogModel("gpt-5-pro", "openAI")?.metadataRevision)
      .toBe('"metadata-r3"');

    // The newer payload omits the profile entirely rather than sending an empty object, so the
    // consumer must drop the previously cached one instead of keeping it.
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify(buildPayload(false)), {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          ETag: '"metadata-r4"',
        },
      }),
    );
    await metadata.refreshMetadata();

    expect(metadata.resolveCatalogModel("gpt-5-pro", "openAI")?.profiles.generation).toBeUndefined();
  });
});
