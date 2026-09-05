import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AIModel, Provider } from "@oriveo/shared";

const getLibraryRuntimeConfig = vi.hoisted(() => vi.fn());
const getModelFacts = vi.hoisted(() => vi.fn());
const getModelFactsRevision = vi.hoisted(() => vi.fn());
const getModelTransport = vi.hoisted(() => vi.fn());
const getRelayRuntimeConfig = vi.hoisted(() => vi.fn());
const resolveCatalogModel = vi.hoisted(() => vi.fn());
const isMetadataSnapshotConfirmed = vi.hoisted(() => vi.fn());
const isLibraryFeatureEnabled = vi.hoisted(() => vi.fn());
const isLibraryBuildEnabled = vi.hoisted(() => vi.fn());

vi.mock("../metadata/metadata-client", () => ({
  getLibraryRuntimeConfig,
  getModelFacts,
  getModelFactsRevision,
  getModelTransport,
  getRelayRuntimeConfig,
  isMetadataSnapshotConfirmed,
  resolveCatalogModel,
}));
vi.mock("./feature-flag", () => ({
  isLibraryBuildEnabled,
  isLibraryFeatureEnabled,
}));

import {
  isLibraryAgentSupported,
  metadataCanDecideRoute,
  resolveLibraryResearchRoute,
  resolveLibraryResearchUnavailableReason,
} from "./routing";
import {
  DEFAULT_LIBRARY_RUNTIME_CONFIG,
  isServerResearchAvailable,
  resolveServerResearchMaxDocuments,
  type LibraryRuntimeConfig,
} from "./types";

// serverResearchEnabled defaults to false on the client (an older server has no /research
// endpoint). The cases below all describe routing after a newer server has served true, so it is
// enabled explicitly here; the "missing field" case deletes it again.
const config: LibraryRuntimeConfig = {
  ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
  serverResearchEnabled: true,
};
const relayIdentity = {
  partitionId: 'uid-1',
  connectionInstanceId: 'p1',
  connectionGeneration: 'g1',
  credentialEpoch: 'e1',
  endpointFingerprint: 'endpoint-1',
};

function provider(overrides: Partial<Provider> = {}): Provider {
  return { id: "p1", kind: "openAI", apiKey: "k", ...overrides } as Provider;
}

function model(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: "gpt-x",
    name: "gpt-x",
    capabilities: ["text"],
    toolCall: true,
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: "standard",
    ...overrides,
  } as AIModel;
}

beforeEach(() => {
  vi.clearAllMocks();
  isLibraryFeatureEnabled.mockReturnValue(true);
  isLibraryBuildEnabled.mockReturnValue(true);
  getModelTransport.mockReturnValue("openai_chat");
  getModelFacts.mockReturnValue(undefined);
  getModelFactsRevision.mockReturnValue("facts-r1");
  resolveCatalogModel.mockReturnValue(null);
  // Likewise, the bar for a negative conclusion defaults to "confirmed in this session"; the unconfirmed case is tested separately.
  isMetadataSnapshotConfirmed.mockReturnValue(true);
});

describe("isLibraryAgentSupported", () => {
  it("treats a v2 catalog null as unknown and fails open instead of letting a legacy libraryAgentic decide tool routing", () => {
    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "gpt-x",
      capabilityContractVersion: 2,
      toolCall: null,
      libraryAgentic: null,
      transport: "openai_chat",
    });
    const stale = model({ toolCall: true, libraryAgentic: true });

    expect(isLibraryAgentSupported(provider(), stale, config)).toBe(true);
    expect(metadataCanDecideRoute(provider(), stale)).toBe(true);
    expect(resolveLibraryResearchRoute(
      provider(),
      stale,
      { ...config, serverResearchEnabled: false },
      true,
      undefined,
      true,
    )).toBe("agent");
  });

  it("does not let libraryAgentic=null on v2+ veto a structured tool_call fact", () => {
    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "gpt-x",
      capabilityContractVersion: 3,
      toolCall: true,
      libraryAgentic: null,
      transport: "openai_chat",
    });
    const stale = model({
      toolCall: true,
      libraryAgentic: true,
      capabilityEvidenceCandidates: [{
        key: 'tool_call', support: 'supported', source: 'server_typed', grade: 'machine_verified',
        scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'gpt-x', transport: 'openai_chat',
      }],
    });

    expect(isLibraryAgentSupported(provider(), stale, config)).toBe(true);
    expect(metadataCanDecideRoute(provider(), stale)).toBe(true);
    expect(resolveLibraryResearchRoute(
      provider(),
      stale,
      { ...config, serverResearchEnabled: false },
      true,
      undefined,
      true,
    )).toBe("agent");
  });

  it("keeps v2 true / false definitive while transport and denylist can still veto true", () => {
    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "gpt-x",
      capabilityContractVersion: 2,
      toolCall: true,
      libraryAgentic: true,
      transport: "openai_chat",
    });
    expect(isLibraryAgentSupported(provider(), model(), config)).toBe(true);

    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "gpt-x",
      capabilityContractVersion: 2,
      toolCall: false,
      libraryAgentic: false,
      transport: "openai_chat",
    });
    expect(isLibraryAgentSupported(provider(), model(), config)).toBe(false);

    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "gpt-x",
      capabilityContractVersion: 2,
      toolCall: true,
      transport: "llamacpp_native",
    });
    expect(isLibraryAgentSupported(provider(), model(), config)).toBe(false);
    expect(metadataCanDecideRoute(provider(), model())).toBe(true);

    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "gpt-x",
      capabilityContractVersion: 2,
      toolCall: true,
      libraryAgentic: true,
      transport: "anthropic_messages",
    });
    expect(isLibraryAgentSupported(provider(), model(), config)).toBe(true);

    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "canonical-x",
      capabilityContractVersion: 2,
      toolCall: true,
      libraryAgentic: true,
      transport: "openai_chat",
    });
    expect(isLibraryAgentSupported(
      provider(),
      model(),
      { ...config, weakModelDenylist: ["canonical-x"] },
    )).toBe(false);
  });

  it("keeps local inference when a v1 catalog hit has no capability flag", () => {
    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "gpt-x",
      transport: "openai_chat",
    });
    expect(isLibraryAgentSupported(
      provider(),
      model({ toolCall: true }),
      config,
    )).toBe(true);
    expect(metadataCanDecideRoute(provider(), model({ toolCall: true }))).toBe(true);
  });

  it("lets the central policy decide on a catalog miss when the production transport is known", () => {
    resolveCatalogModel.mockReturnValue(null);
    const stale = model({ toolCall: true, libraryAgentic: true });
    expect(isLibraryAgentSupported(provider(), stale, config)).toBe(true);
    expect(metadataCanDecideRoute(provider(), stale)).toBe(true);
    expect(resolveLibraryResearchRoute(provider(), stale, config, true)).toBe("agent");
  });

  it("does not let a legacy derived libraryAgentic flag override the central tool_call decision", () => {
    expect(
      isLibraryAgentSupported(
        provider(),
        model({ toolCall: true, transport: "openai_chat", libraryAgentic: false }),
        config,
      ),
    ).toBe(true);
  });

  it("allows it when the backend says so, without requiring the client to assemble toolCall / transport itself", () => {
    expect(
      isLibraryAgentSupported(
        provider(),
        model({ libraryAgentic: true }),
        config,
      ),
    ).toBe(true);
  });

  it("falls back to the authoritative flag in the catalog when the model object does not carry it", () => {
    resolveCatalogModel.mockReturnValue({ libraryAgentic: true });
    expect(isLibraryAgentSupported(provider(), model(), config)).toBe(true);
    expect(resolveCatalogModel).toHaveBeenCalledWith("gpt-x", "openAI");
  });

  /**
   * The model flag is persisted and synced across devices (the observed
   * payloads carry neither toolCall nor libraryAgentic). If any device enriched it from an old
   * snapshot, reading the model flag first short-circuits on a stale value and buries the real
   * value from the current catalog snapshot, which is one source of a wrong first decision on a
   * cold start.
   */
  it("does not let a catalog libraryAgentic bypass missing tool evidence", () => {
    resolveCatalogModel.mockReturnValue({ libraryAgentic: true });
    expect(
      isLibraryAgentSupported(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        config,
      ),
    ).toBe(false);
  });

  it("stays unknown and fails open on tools when there is no tool candidate", () => {
    resolveCatalogModel.mockReturnValue({
      capabilityContractVersion: 2,
      libraryAgentic: true,
      toolCall: true,
      transport: 'openai_chat',
      capabilityEvidenceCandidates: [],
    });
    expect(isLibraryAgentSupported(
      provider(),
      model({ libraryAgentic: true, toolCall: true, capabilityEvidenceCandidates: [] }),
      config,
    )).toBe(true);
  });

  it("does not let a legacy catalog libraryAgentic=false override the tool_call decision", () => {
    resolveCatalogModel.mockReturnValue({ libraryAgentic: false });
    expect(
      isLibraryAgentSupported(
        provider(),
        model({ libraryAgentic: true }),
        config,
      ),
    ).toBe(true);
  });

  it("prefers the catalog adapter tool candidate over a synced legacy model flag", () => {
    // The synced model flag says false, but the production metadata adapter already provides a safe typed fact.
    resolveCatalogModel.mockReturnValue({
      toolCall: true,
      transport: "openai_chat",
    });
    expect(
      isLibraryAgentSupported(provider(), model({
        toolCall: false,
        capabilityEvidenceCandidates: [{
          key: 'tool_call', support: 'supported', source: 'server_typed', grade: 'machine_verified',
          scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'gpt-x', transport: 'openai_chat',
        }],
      }), config),
    ).toBe(true);
  });

  it("decides locally from the exact relay transport and connection-level tool evidence", () => {
    resolveCatalogModel.mockReturnValue({ libraryAgentic: false });
    expect(
      isLibraryAgentSupported(
        provider({ kind: "relay", relayResolvedTransport: "openai_chat_completions" }),
        model({ libraryAgentic: true }),
        config,
        relayIdentity,
      ),
    ).toBe(true);
  });

  // An older server does not serve this field: deciding false would make the library entry point vanish for every model during the upgrade window.
  it("falls back to local inference for a missing field instead of deciding false", () => {
    expect(
      isLibraryAgentSupported(
        provider(),
        model({ toolCall: true, transport: "openai_chat" }),
        config,
      ),
    ).toBe(true);
    expect(
      isLibraryAgentSupported(
        provider(),
        model({ toolCall: true, transport: "anthropic_messages" }),
        config,
      ),
    ).toBe(true);
    expect(
      isLibraryAgentSupported(provider(), model({ toolCall: false }), config),
    ).toBe(false);
    expect(
      isLibraryAgentSupported(
        provider(),
        model({ toolCall: true, transport: "openai_chat" }),
        { ...config, weakModelDenylist: ["gpt-x"] },
      ),
    ).toBe(false);
  });

  it("still requires the negotiated relay transport to agree even when the authoritative flag allows it", () => {
    expect(
      isLibraryAgentSupported(
        provider({ kind: "relay", relayResolvedTransport: "anthropic_messages" }),
        model({ libraryAgentic: true }),
        config,
      ),
    ).toBe(true);
    expect(
      isLibraryAgentSupported(
        provider({
          kind: "relay",
          relayResolvedTransport: "openai_chat_completions",
        }),
        model({ libraryAgentic: true }),
        config,
        relayIdentity,
      ),
    ).toBe(true);
  });

  it("does not guess when relay auto has no final transport, but uses an exact requested transport", () => {
    expect(
      isLibraryAgentSupported(
        provider({ kind: "relay" }),
        model({ libraryAgentic: true }),
        config,
        relayIdentity,
      ),
    ).toBe(false);
    expect(
      isLibraryAgentSupported(
        provider({
          kind: "relay",
          relayRequested: { transport: "openai_chat_completions", authMode: "auto" },
        }),
        model({ libraryAgentic: true }),
        config,
        relayIdentity,
      ),
    ).toBe(true);
  });

  it("keeps resolved authoritative so the requested intent cannot override the measured result", () => {
    expect(
      isLibraryAgentSupported(
        provider({
          kind: "relay",
          relayResolvedTransport: "anthropic_messages",
          relayRequested: { transport: "auto", authMode: "auto" },
        }),
        model({ libraryAgentic: true }),
        config,
      ),
    ).toBe(true);
  });

  it("resolves a catalog miss in the order first-party > modelFacts > persisted model", () => {
    resolveCatalogModel.mockReturnValue(null);
    getModelFacts.mockReturnValue({ toolCall: false });
    expect(isLibraryAgentSupported(
      provider(),
      model({ toolCall: true, transport: "openai_chat" }),
      config,
    )).toBe(false);

    getModelFacts.mockReturnValue({ toolCall: true });
    expect(isLibraryAgentSupported(
      provider(),
      model({ toolCall: false, transport: "openai_chat" }),
      config,
    )).toBe(true);

    expect(isLibraryAgentSupported(
      provider({ authMode: "subscription" }),
      model({ toolCall: false, transport: undefined }),
      config,
    )).toBe(false);
  });

  it("uses the real final transport for subscriptions, and consumes modelFacts for a Relay with a recognizable upstream", () => {
    resolveCatalogModel.mockReturnValue(null);
    getModelFacts.mockReturnValue({ toolCall: true });

    expect(isLibraryAgentSupported(
      provider({ kind: "openAI", authMode: "subscription" }),
      model({ id: "gpt-subscription", toolCall: undefined, transport: undefined }),
      config,
    )).toBe(true);

    expect(isLibraryAgentSupported(
      provider({
        kind: "relay",
        relayResolvedTransport: "anthropic_messages",
      }),
      model({
        id: "claude-external",
        toolCall: false,
        transport: undefined,
        relayMatchedProviderKind: "anthropic",
      } as Partial<AIModel>),
      config,
      relayIdentity,
    )).toBe(true);
    expect(getModelFacts).toHaveBeenCalledWith("anthropic", "claude-external");
  });

  it("always prefers a catalog hit over modelFacts", () => {
    resolveCatalogModel.mockReturnValue({
      canonicalModelId: "gpt-x",
      toolCall: false,
      transport: "openai_chat",
    });
    getModelFacts.mockReturnValue({ toolCall: true });

    expect(isLibraryAgentSupported(provider(), model({ toolCall: true }), config)).toBe(false);
    expect(getModelFacts).not.toHaveBeenCalled();
  });
});

describe("isServerResearchAvailable", () => {
  it("treats a missing field as unavailable, since that endpoint does not exist there", () => {
    const legacy = { ...config };
    delete legacy.serverResearchEnabled;
    expect(isServerResearchAvailable(legacy, "openAI", true)).toBe(false);
  });

  it("honors an explicit provider denylist", () => {
    expect(isServerResearchAvailable({
      ...config,
      serverResearchProviderDenylist: ["relay"],
    }, "relay", true)).toBe(false);
    expect(isServerResearchAvailable(config, "openAI", true)).toBe(true);
  });

  it("is unavailable when the feature is switched off by the backend or no source is connected", () => {
    expect(
      isServerResearchAvailable({ ...config, enabled: false }, "openAI", true),
    ).toBe(false);
    expect(isServerResearchAvailable(config, "openAI", false)).toBe(false);
  });

  it("takes the suggested article count from the backend and falls back to 5", () => {
    expect(resolveServerResearchMaxDocuments(config)).toBe(5);
    expect(
      resolveServerResearchMaxDocuments({
        ...config,
        serverResearchMaxDocuments: 8,
      }),
    ).toBe(8);
    const legacy = { ...config };
    delete legacy.serverResearchMaxDocuments;
    expect(resolveServerResearchMaxDocuments(legacy)).toBe(5);
  });
});

describe("resolveLibraryResearchRoute", () => {
  beforeEach(() => getLibraryRuntimeConfig.mockReturnValue(config));

  it("keeps BYOK with agentic support on the agent loop", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: true }),
        config,
        true,
        true,
      ),
    ).toBe("agent");
  });

  it("routes BYOK to server-side retrieval when the model does not support agentic", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        config,
        true,
        true,
      ),
    ).toBe("server");
  });

  it("gives neither path when no source is connected or the kill switch is off", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: true }),
        config,
        false,
      ),
    ).toBe("none");
    isLibraryFeatureEnabled.mockReturnValue(false);
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: true }),
        config,
        true,
      ),
    ).toBe("none");
  });

  it("returns none for a weak model when serverResearchEnabled is missing, and never calls /research", () => {
    const legacy = { ...config };
    delete legacy.serverResearchEnabled;
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        legacy,
        true,
        true,
      ),
    ).toBe("none");
  });

  /**
   * A snapshot that cannot answer is not the same as a model that does not support this.
   *
   * Every input to the decision (libraryAgentic / transport) comes from the metadata snapshot.
   * Counting "cannot answer" as none makes the panel say the current model does not support
   * automatic retrieval, and the ChatView effect then clears the retrieval switch the user had
   * turned on.
   *
   * Production showed two layers of this (DeepSeek V4 Flash was served libraryAgentic=true and
   * still judged unsupported):
   * 1. the snapshot never arrived, which is all the first version checked;
   * 2. **the snapshot arrived but was stale** (initMetadata returns on a cache hit and only
   *    refreshes in the background) and did not contain the newly synced model, so
   *    `snapshot != null` is not enough and the test has to be "is this model in it".
   */
  it("routes a manually entered model with a catalog miss through the production fallback transport to agent", () => {
    // The transport of an official provider comes from the catalog; the stale snapshot does not have this new model.
    resolveCatalogModel.mockReturnValue(null);
    getModelTransport.mockReturnValue(undefined);
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ id: "deepseek-v4-flash", toolCall: true }),
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        true,
      ),
    ).toBe("agent");
  });

  it("does not let a legacy libraryAgentic=false override the tool capability facts", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: false, toolCall: true }),
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        true,
        true,
      ),
    ).toBe("agent");
  });

  it("keeps relay auto pending until the final transport is resolved", () => {
    expect(
      resolveLibraryResearchRoute(
        provider({ kind: "relay", relayRequested: { transport: "auto", authMode: "auto" } }),
        model({ toolCall: true }),
        config,
        true,
        undefined,
        undefined,
        relayIdentity,
      ),
    ).toBe("pending");
  });

  it("keeps none when no source is connected, even if the snapshot cannot answer", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ toolCall: true }),
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        false,
      ),
    ).toBe("none");
  });

  /**
   * "provider / model did not resolve" is **not** a definitive fact: right after a cold start the
   * providers and the conversation record are still loading and a historical fallback provider
   * always has an empty models list, so currentModel resolves to undefined and will be ready on
   * the next tick. Judging that as none is the hidden branch behind "it says unsupported the
   * moment you open it". ChatView recomputes on every render, so pending heals itself on the tick
   * where the context becomes ready.
   */
  it("reports pending rather than none while the context is still resolving", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        undefined,
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        true,
      ),
    ).toBe("pending");
    expect(
      resolveLibraryResearchRoute(
        undefined,
        model({ toolCall: true }),
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        true,
      ),
    ).toBe("pending");
  });
});

// "The catalog knows this model" is not the same as "its capability flags have been observed"; the two must not be conflated.
describe("metadataCanDecideRoute", () => {
  it("can still decide from the production fallback transport when the model is not in the catalog", () => {
    resolveCatalogModel.mockReturnValue(null);
    expect(metadataCanDecideRoute(provider(), model({ toolCall: undefined }))).toBe(true);
  });

  it("can decide from a known final transport even when tool capability is unknown", () => {
    resolveCatalogModel.mockReturnValue({});
    expect(metadataCanDecideRoute(provider(), model({ toolCall: undefined }))).toBe(true);
  });

  it("can decide as soon as any capability candidate from the catalog adapter appears", () => {
    resolveCatalogModel.mockReturnValue({ toolCall: true });
    expect(metadataCanDecideRoute(provider(), model({
      capabilityEvidenceCandidates: [{
        key: 'tool_call', support: 'supported', source: 'server_typed', grade: 'machine_verified',
        scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'gpt-x', transport: 'openai_chat',
      }],
    }))).toBe(true);
    resolveCatalogModel.mockReturnValue({ libraryAgentic: false });
    expect(metadataCanDecideRoute(provider(), model())).toBe(true);
  });

  it("lets the final transport decide routability on an official catalog miss", () => {
    resolveCatalogModel.mockReturnValue(null);
    expect(
      metadataCanDecideRoute(provider(), model({ libraryAgentic: true })),
    ).toBe(true);
  });
});

/**
 * Regression: the catalog knows this model (as opposed to the snapshot not having it at all), but
 * neither capability flag has been observed yet. The existence check in `hasCatalogModel` used to
 * count that as "answerable" and render "not yet known" as the definitive "model not supported"
 * copy. It must stay pending.
 */
describe("resolveLibraryResearchRoute: unknown capability is not a definitive lack of support", () => {
  beforeEach(() => getLibraryRuntimeConfig.mockReturnValue(config));

  it("fails open to agent on unknown catalog capability instead of reporting unsupported", () => {
    resolveCatalogModel.mockReturnValue({});
    getModelTransport.mockReturnValue(undefined);
    const legacy = { ...config };
    delete legacy.serverResearchEnabled;
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ id: "brand-new-model" }),
        legacy,
        true,
      ),
    ).toBe("agent");
  });
});

/**
 * The bar for a negative conclusion.
 *
 * `getLibraryRuntimeConfig()` on web falls back to the **explicit false** in DEFAULT for a
 * missing field and never yields undefined, so "false from a stale or default config" and
 * "the backend really said false" look identical here and cannot be told apart from the config
 * alone. Only "has this session confirmed with the backend (200/304)" separates them.
 */
describe("resolveLibraryResearchRoute: the bar for a negative conclusion", () => {
  beforeEach(() => {
    getLibraryRuntimeConfig.mockReturnValue(config);
    isMetadataSnapshotConfirmed.mockReturnValue(false);
  });

  it("reports pending instead of unsupported until the snapshot is confirmed", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        // The classic stale-cache shape: serverResearchEnabled stuck at its default false.
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        true,
        true,
      ),
    ).toBe("pending");
  });

  it("lands on none for the same input once confirmed", () => {
    isMetadataSnapshotConfirmed.mockReturnValue(true);
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        true,
        true,
      ),
    ).toBe("none");
  });

  it("sets no bar for positive conclusions and routes to agent / server even when unconfirmed", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: true }),
        config,
        true,
        true,
      ),
    ).toBe("agent");
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        config,
        true,
        true,
      ),
    ).toBe("server");
  });

  it("treats no connected source as a local fact that is not subject to the confirmation bar", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: true }),
        config,
        false,
      ),
    ).toBe("none");
  });

  it("reports pending when the backend switch is off but unconfirmed, and none when the build-time kill switch is off", () => {
    isLibraryFeatureEnabled.mockReturnValue(false);
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: true }),
        { ...config, enabled: false },
        true,
      ),
    ).toBe("pending");
    isLibraryBuildEnabled.mockReturnValue(false);
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: true }),
        { ...config, enabled: false },
        true,
      ),
    ).toBe("none");
  });

  it("lets an explicitly passed snapshotConfirmed override the value computed for the session", () => {
    expect(
      resolveLibraryResearchRoute(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        true,
        true,
        true,
      ),
    ).toBe("none");
  });
});

// The specific reason behind `none` is one of three (the backend switch is off, the provider is
// on the retrieval denylist, or the model itself does not support it), and the UI picks its copy
// from that. Same source of truth as resolveLibraryResearchRoute.
describe("resolveLibraryResearchUnavailableReason", () => {
  beforeEach(() => getLibraryRuntimeConfig.mockReturnValue(config));

  it("gives no reason when the route is agent / server / pending", () => {
    expect(
      resolveLibraryResearchUnavailableReason(
        provider(),
        model({ libraryAgentic: true }),
        config,
        true,
      ),
    ).toBeUndefined();
    expect(
      resolveLibraryResearchUnavailableReason(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        config,
        true,
      ),
    ).toBeUndefined();
    expect(
      resolveLibraryResearchUnavailableReason(
        provider(),
        undefined,
        { ...DEFAULT_LIBRARY_RUNTIME_CONFIG },
        true,
      ),
    ).toBeUndefined();
  });

  it("does not break down the reason when no source is connected, reusing the existing connectRequired copy", () => {
    expect(
      resolveLibraryResearchUnavailableReason(
        provider(),
        model({ libraryAgentic: true }),
        config,
        false,
      ),
    ).toBeUndefined();
  });

  it("reports serverDisabled when the backend switch is off and confirmed, and draws no conclusion while unconfirmed", () => {
    isLibraryFeatureEnabled.mockReturnValue(false);
    expect(
      resolveLibraryResearchUnavailableReason(
        provider(),
        model({ libraryAgentic: true }),
        config,
        true,
      ),
    ).toBe("serverDisabled");

    isMetadataSnapshotConfirmed.mockReturnValue(false);
    expect(
      resolveLibraryResearchUnavailableReason(
        provider(),
        model({ libraryAgentic: true }),
        config,
        true,
      ),
    ).toBeUndefined();
  });

  it("reports providerDenied on a denylist hit", () => {
    expect(
      resolveLibraryResearchUnavailableReason(
        provider({ kind: "relay" }),
        model({ toolCall: true }),
        { ...config, serverResearchProviderDenylist: ["relay"] },
        true,
        true,
      ),
    ).toBe("providerDenied");
  });

  it("reports modelUnsupported when the model supports neither path", () => {
    const legacy = { ...config };
    delete legacy.serverResearchEnabled;
    expect(
      resolveLibraryResearchUnavailableReason(
        provider(),
        model({ libraryAgentic: false, toolCall: false }),
        legacy,
        true,
        true,
      ),
    ).toBe("modelUnsupported");
  });

  it("withholds the specific modelUnsupported reason while unconfirmed", () => {
    isMetadataSnapshotConfirmed.mockReturnValue(false);
    const legacy = { ...config };
    delete legacy.serverResearchEnabled;
    expect(
      resolveLibraryResearchUnavailableReason(
        provider(),
        model({ libraryAgentic: false }),
        legacy,
        true,
      ),
    ).toBeUndefined();
  });

  // The denylist is a static fact about the provider, so unlike modelUnsupported the verdict does
  // not wait for this session to have confirmed a snapshot.
  it("reports providerDenied without waiting for snapshot confirmation", () => {
    isMetadataSnapshotConfirmed.mockReturnValue(false);
    expect(
      resolveLibraryResearchUnavailableReason(
        provider({ kind: "relay" }),
        model({ toolCall: true }),
        { ...config, serverResearchProviderDenylist: ["relay"] },
        true,
        true,
      ),
    ).toBe("providerDenied");
  });
});
