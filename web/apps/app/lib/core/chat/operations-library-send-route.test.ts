import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AIModel, Conversation, Provider } from "@oriveo/shared";
import { createAppStore } from "../store/app-store";
import { DEFAULT_LIBRARY_RUNTIME_CONFIG } from "../library/types";

const mocks = vi.hoisted(() => ({
  runLoop: vi.fn(),
  sendMessage: vi.fn(),
  trackEvent: vi.fn(),
  runResearch: vi.fn(),
  sendLibraryLeg: vi.fn(),
  prepareGrokSubscription: vi.fn(),
  prepareOpenAISubscription: vi.fn(),
  persistGrokSubscription: vi.fn(),
  persistOpenAISubscription: vi.fn(),
  // A hoisted block cannot reference an imported constant (it is not initialized yet after hoisting), so
  // beforeEach fills this in.
  libraryConfig: {} as Record<string, unknown>,
}));

vi.mock("../../utils/chat-stream-utils", () => ({
  buildChatHistory: vi.fn(async () => []),
  sanitizeOutboundMessages: (messages: unknown[]) => messages,
}));
vi.mock("./prompt-injection", () => ({
  buildPromptInjectionContext: vi.fn(async () => ({
    systemContent: "",
    memoryInjected: false,
    retrievalCost: 0,
  })),
}));
vi.mock("./library-agent-loop", () => ({
  LibraryResearchCancelledError: class LibraryResearchCancelledError extends Error {},
  runLibraryAgentLoop: (...args: unknown[]) => mocks.runLoop(...args),
}));
vi.mock("./stream-options", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./stream-options")>()),
  buildStreamOptionsFromIntent: vi.fn(() => ({})),
  buildProviderStreamOptions: vi.fn(() => ({})),
  resolveGenerationProfileForModel: vi.fn(() => undefined),
}));
vi.mock("../metadata/metadata-client", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../metadata/metadata-client")>()),
  // The send path goes through activeGenerationParameterIds to resolveGenerationProfileForModel,
  // which always calls this one export; leaving it out of the mock makes the whole send path throw (these fixtures have no metadata profile anyway).
  resolveGenerationProfileRef: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => undefined),
  getModelTransport: vi.fn(() => "openai_chat"),
  getLibraryRuntimeConfig: vi.fn(() => mocks.libraryConfig),
  //   library/routing.test.ts  
  hasCatalogModel: vi.fn(() => true),
  resolveCatalogModel: vi.fn(() => ({ contextLength: 128_000 })),
  //   library/routing.test.ts  
  isMetadataSnapshotConfirmed: vi.fn(() => true),
}));
vi.mock("../providers/proxy-client", () => ({
  sendLibraryAgentLeg: (...args: unknown[]) => mocks.sendLibraryLeg(...args),
}));
vi.mock("../providers/grok-subscription", () => ({
  prepareGrokSubscriptionRequest: (...args: unknown[]) => mocks.prepareGrokSubscription(...args),
  grokSubscriptionErrorKindToProviderErrorKind: (kind: string) => `grok-${kind}`,
  refreshMetadataOnClientVersionRejected: vi.fn(),
}));
vi.mock("../providers/openai-subscription", () => ({
  prepareOpenAISubscriptionRequest: (...args: unknown[]) => mocks.prepareOpenAISubscription(...args),
  openAISubscriptionErrorKindToProviderErrorKind: (kind: string) => `openai-${kind}`,
  refreshMetadataOnCodexClientVersionRejected: vi.fn(),
}));
vi.mock("../provider-ops", () => ({
  persistGrokSubscriptionCredential: (...args: unknown[]) => mocks.persistGrokSubscription(...args),
  persistOpenAISubscriptionCredential: (...args: unknown[]) => mocks.persistOpenAISubscription(...args),
}));
vi.mock("../library/api", () => ({
  executeLibraryTool: vi.fn(),
  executeLibraryResearch: vi.fn(),
}));
vi.mock("../library/confirmation", () => ({
  requestLibraryConfirmation: vi.fn(),
  clearOwnLibraryConfirmation: vi.fn(),
}));
vi.mock("./library-server-research", () => ({
  runLibraryServerResearch: (...args: unknown[]) => mocks.runResearch(...args),
}));
vi.mock("./cost-fields", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./cost-fields")>()),
  deriveCostFields: vi.fn(() => ({ cost: 0, costSource: "localEstimate" })),
  mergeCitationsWithExisting: vi.fn((existing, incoming) =>
    incoming?.length ? incoming : existing,
  ),
}));
vi.mock("./send-completion", () => ({
  reportSendCompletion: vi.fn(),
}));
vi.mock("../sync-port", () => ({ getSyncAdapter: vi.fn(() => null) }));
vi.mock("../telemetry", async () => ({
  trackEvent: (...args: unknown[]) => mocks.trackEvent(...args),
  telemetryProviderKind: (kind: string) => kind,
  // Relay reduction uses the real implementation; do not reimplement the rule inside the mock, which
  // would only test the mock.
  telemetryModelID: (await vi.importActual<typeof import('../telemetry')>('../telemetry')).telemetryModelID,
}));
// The internals of sendMessage are out of scope here; this file only verifies which arguments the
// server-side retrieval path hands to it.
vi.mock("./operations-send", async () => {
  const actual = await vi.importActual<typeof import("./operations-send")>(
    "./operations-send",
  );
  return {
    ...actual,
    sendMessage: (...args: unknown[]) => mocks.sendMessage(...args),
  };
});

import { sendLibraryMessage } from "./operations-library-send";

function model(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: "gpt-4o",
    name: "GPT-4o",
    capabilities: ["text"],
    toolCall: true,
    transport: "openai_chat",
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: "$",
    promptPrice: 0,
    completionPrice: 0,
    ...overrides,
  } as AIModel;
}

function provider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: "provider-1",
    kind: "openAI",
    status: { kind: "connected" },
    models: [model()],
    catalogModels: [model()],
    apiKey: "sk-test",
    apiKeyPreview: "sk-...test",
    ...overrides,
  } as Provider;
}

function conversation(): Conversation {
  return {
    id: "conv-1",
    title: "Research",
    hasCustomTitle: false,
    providerID: "provider-1",
    providerKind: "openAI",
    modelID: "gpt-4o",
    previewText: "",
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: "",
    createdAt: "2026-07-24T00:00:00.000Z",
    updatedAt: "2026-07-24T00:00:00.000Z",
  } as Conversation;
}

function send(options: {
  provider?: Provider;
  model?: AIModel;
  connected?: boolean;
}) {
  const conv = conversation();
  const store = createAppStore({
    conversations: [conv],
    ...(options.connected === false
      ? {}
      : {
          libraryConnections: [
            {
              id: "notion-1",
              provider: "notion" as const,
              displayName: "Notion",
              scopes: [],
              status: "active" as const,
            },
          ],
        }),
  });
  const handle = sendLibraryMessage(
    { store, appendChunk: vi.fn(), te: (key) => key },
    {
      text: "Find the roadmap",
      prevMessages: [],
      conversation: conv,
      provider: options.provider ?? provider(),
      model: options.model ?? model(),
      reasoningMode: "automatic",
      cancelledText: "Cancelled",
      errorTitle: "Failed",
      errorDetail: "Try again",
    },
  );
  return { store, handle };
}

beforeEach(() => {
  mocks.runLoop.mockReset();
  mocks.sendMessage.mockReset();
  mocks.trackEvent.mockReset();
  mocks.runResearch.mockReset();
  mocks.sendLibraryLeg.mockReset();
  mocks.prepareGrokSubscription.mockReset().mockResolvedValue({
    ok: true,
    value: { accessToken: "grok-access-token", config: {} },
  });
  mocks.prepareOpenAISubscription.mockReset().mockResolvedValue({
    ok: true,
    value: { accessToken: "codex-access-token", accountID: "account-1", config: {} },
  });
  mocks.persistGrokSubscription.mockReset().mockResolvedValue(true);
  mocks.persistOpenAISubscription.mockReset().mockResolvedValue(true);
  // serverResearchEnabled defaults to false on the client because older servers have no such endpoint.
  // These cases are about routing once a server publishes true, so enable it explicitly.
  mocks.libraryConfig = {
    ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
    serverResearchEnabled: true,
  };
  mocks.runLoop.mockResolvedValue({ text: "answer", citations: [], steps: [] });
  mocks.sendMessage.mockReturnValue({
    convId: "conv-1",
    msgId: "assistant-1",
    abort: vi.fn(),
    done: Promise.resolve(),
  });
});

describe("sendLibraryMessage route selection", () => {
  it("an agentic-capable BYOK provider still uses the agent loop and reports agent telemetry", async () => {
    const { handle } = send({});
    await handle.done;

    expect(mocks.runLoop).toHaveBeenCalledOnce();
    expect(mocks.sendMessage).not.toHaveBeenCalled();
    expect(mocks.trackEvent).toHaveBeenCalledWith(
      "library_research_route",
      expect.objectContaining({ route: "agent", provider_kind: "openAI" }),
    );
  });

  it.each([
    {
      name: "Grok",
      provider: provider({
        kind: "grok",
        authMode: "subscription",
        apiKey: "",
        grokSubscription: { accessToken: "stored-grok-token", obtainedAt: 1 },
      }),
      model: model({ id: "grok-4.6", transport: "openai_responses", capabilities: ["text", "web"] }),
      expectedToken: "grok-access-token",
      expectedOptions: { grokSubscriptionAuth: true },
    },
    {
      name: "Codex",
      provider: provider({
        authMode: "subscription",
        apiKey: "",
        openAISubscription: {
          accessToken: "stored-codex-token",
          accountID: "account-1",
          obtainedAt: 1,
        },
      }),
      model: model({ id: "gpt-5.6-sol", transport: "openai_responses" }),
      expectedToken: "codex-access-token",
      expectedOptions: { openAISubscriptionAuth: true, openAISubscriptionAccountID: "account-1" },
    },
  ])("$name refreshes the subscription credential before the library leg goes out and passes the subscription identity along", async ({
    provider: subscriptionProvider,
    model: subscriptionModel,
    expectedToken,
    expectedOptions,
  }) => {
    mocks.runLoop.mockImplementation(async (options: {
      runLeg: (leg: { messages: []; tools: []; toolChoice: "none" }) => unknown;
    }) => {
      options.runLeg({ messages: [], tools: [], toolChoice: "none" });
      return { text: "answer", citations: [], steps: [] };
    });

    const { handle } = send({ provider: subscriptionProvider, model: subscriptionModel });
    await handle.done;

    expect(mocks.sendLibraryLeg).toHaveBeenCalledWith(
      subscriptionProvider.kind,
      expectedToken,
      subscriptionModel.id,
      [],
      [],
      subscriptionProvider.baseURLText,
      expect.objectContaining(expectedOptions),
      "none",
    );
  });

  it("a BYOK provider the server explicitly declares has no tool_call support uses server-side retrieval", async () => {
    const { handle } = send({
      model: model({
        capabilityEvidenceCandidates: [{
          key: "tool_call",
          support: "unsupported",
          source: "server_profile",
          grade: "declared",
          scope: "provider_model_transport",
          providerKind: "openAI",
          modelId: "gpt-4o",
          transport: "openai_chat",
        }],
      }),
    });
    await handle.done;

    expect(mocks.runLoop).not.toHaveBeenCalled();
    expect(mocks.sendMessage).toHaveBeenCalledOnce();
  });
});

describe("fallback when the first leg makes zero tool calls", () => {
  /** Make the mocked agent loop actually run the zero-tool-call hook for the first leg, then return the re-answer result. */
  async function runFallback() {
    let fallback: unknown;
    mocks.runLoop.mockImplementation(
      async (loopOptions: {
        onFirstLegWithoutToolCalls?: (text: string) => Promise<unknown>;
      }) => {
        fallback = await loopOptions.onFirstLegWithoutToolCalls?.(
          "Made-up answer.",
        );
        return { text: "Grounded answer.", citations: [], steps: [] };
      },
    );
    const { handle } = send({});
    await handle.done;
    return fallback;
  }

  it("returns evidence when server-side retrieval is available and reports agent_no_toolcall_fallback telemetry", async () => {
    mocks.runResearch.mockResolvedValue({
      systemInstruction: "Untrusted evidence.",
      userContext: "<library_context/>",
      citations: [{ index: 1, url: "u", title: "t" }],
      steps: [],
      warnings: [],
      documentCount: 2,
    });

    const fallback = await runFallback();

    expect(fallback).toMatchObject({ userContext: "<library_context/>" });
    expect(mocks.trackEvent).toHaveBeenCalledWith(
      "library_research_route",
      expect.objectContaining({
        route: "agent_no_toolcall_fallback",
        documents: 2,
      }),
    );
    //   agent
    expect(
      mocks.trackEvent.mock.calls.filter(
        (call) => (call[1] as { route: string }).route === "agent",
      ),
    ).toHaveLength(0);
  });

  it("keeps the current behavior when server-side retrieval is unavailable but still reports telemetry", async () => {
    const legacy = { ...DEFAULT_LIBRARY_RUNTIME_CONFIG };
    delete legacy.serverResearchEnabled;
    mocks.libraryConfig = legacy;

    const fallback = await runFallback();

    expect(fallback).toBeNull();
    expect(mocks.runResearch).not.toHaveBeenCalled();
    expect(mocks.trackEvent).toHaveBeenCalledWith(
      "library_research_route",
      expect.objectContaining({ route: "agent_no_toolcall_kept" }),
    );
  });
});
