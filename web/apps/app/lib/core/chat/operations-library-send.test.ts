import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AIModel,
  ChatMessage,
  Conversation,
  Provider,
} from "@oriveo/shared";
import { createAppStore } from "../store/app-store";
import { ContextAssembler } from "@oriveo/core/context/assemble";
import {
  LIBRARY_TOOL_SAFETY_PROMPT,
  continueLibraryAnswering,
  resolveActiveSources,
  retryLibraryMessage,
  sendLibraryMessage,
} from "./operations-library-send";
import { DEFAULT_LIBRARY_RUNTIME_CONFIG } from "../library/types";
import { buildStreamOptionsFromIntent } from "./stream-options";
import { valueOverride } from "./generation-parameter-settings";
import type { Mock } from "vitest";
import type { StreamEvent } from "@oriveo/core/providers/types";
import { sendLibraryAgentLeg } from "../providers/proxy-client";
import { trackEvent } from "../telemetry";
import { INPUT_NEGATIVE_CACHE_STORAGE_KEY } from "../capability/input-negative-cache";

const mocks = vi.hoisted(() => ({
  runLoop: vi.fn(),
  reportSendCompletion: vi.fn(),
  toolRememberedFalse: vi.fn((_identity: unknown) => false),
  recordToolFalse: vi.fn((_identity: unknown) => undefined),
  searchContext: vi.fn(async (_input: unknown): Promise<unknown> => null),
  forwardSearch: vi.fn(),
  searchKey: vi.fn(async (_uid: string, _id: string): Promise<string | null> => "tv-key-0000"),
}));
// External web search: local sources and forwarding are supplied by each case (no service by default = behavior unchanged).
vi.mock("./external-search-send", () => ({
  loadExternalSearchSendContext: (input: unknown) => mocks.searchContext(input),
}));
vi.mock("../../search/search-settings-data", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../search/search-settings-data")>()),
  forwardSearch: (...args: unknown[]) => mocks.forwardSearch(...args),
}));

vi.mock("../../search/search-service-store", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../search/search-service-store")>()),
  readSearchServiceKey: (uid: string, id: string) => mocks.searchKey(uid, id),
}));

vi.mock("../../utils/chat-stream-utils", () => ({
  buildChatHistory: vi.fn(async () => []),
  mapErrorKindKey: () => 'network',
}));
// The tool loop's system is composed by the assembler (buildChatContextSources uses the real implementation); this fixture group has no memory / skills.
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
  // The send path reaches this export through activeGenerationParameterIds →
  // resolveGenerationProfileForModel, so leaving it out of the mock makes the whole path throw.
  // These fixtures carry no metadata profile anyway.
  resolveGenerationProfileRef: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => undefined),
  getModelTransport: vi.fn(() => "openai_chat"),
  getLibraryRuntimeConfig: vi.fn(() => ({
    version: 2,
    toolDescriptions: {},
    maxSteps: 4,
    toolTimeoutMs: 1000,
    maxEmptyHits: 2,
    maxSelfCorrections: 2,
    tokenBudget: 0,
    estimatedTokensPerStep: 2_000,
    highCostConfirmationUSD: 0.25,
    weakModelDenylist: [],
    sensitiveGateEnabled: true,
  })),
  // Routing itself is covered by library/routing.test.ts; here it only has to answer yes.
  hasCatalogModel: vi.fn(() => true),
  resolveCatalogModel: vi.fn(() => ({ contextLength: 128_000 })),
  // Routing itself is covered by library/routing.test.ts; here it only has to answer yes.
  isMetadataSnapshotConfirmed: vi.fn(() => true),
  getProviderCatalogStatus: vi.fn(() => "loaded"),
}));
vi.mock("../providers/proxy-client", () => ({ sendLibraryAgentLeg: vi.fn() }));
vi.mock('./capability-recovery-runtime', () => ({
  toolCallSupportIsRememberedFalse: (identity: unknown) => mocks.toolRememberedFalse(identity),
  recordToolCallSupportFalse: (identity: unknown) => mocks.recordToolFalse(identity),
}));
vi.mock("../library/api", () => ({ executeLibraryTool: vi.fn() }));
vi.mock("../library/confirmation", () => ({
  requestLibraryConfirmation: vi.fn(),
  clearOwnLibraryConfirmation: vi.fn(),
}));
vi.mock("./cost-fields", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./cost-fields")>();
  return {
    ...actual,
    deriveCostFields: vi.fn(() => ({ cost: 0.42, costSource: "localEstimate" })),
    mergeCitationsWithExisting: vi.fn((existing, incoming) =>
      incoming?.length ? incoming : existing,
    ),
  };
});
vi.mock("./send-completion", () => ({
  reportSendCompletion: (...args: unknown[]) =>
    mocks.reportSendCompletion(...args),
}));
vi.mock("../sync-port", () => ({ getSyncAdapter: vi.fn(() => null) }));
vi.mock("../telemetry", async () => ({
  trackEvent: vi.fn(),
  telemetryProviderKind: (kind: string) => kind,
  // The model_id helper uses the real implementation; don't re-implement its rule in the stub (re-implementing means testing your own stub)
  telemetryModelID: (await vi.importActual<typeof import('../telemetry')>('../telemetry')).telemetryModelID,
  // Needed by the relay telemetry properties on a relay send (same: use the real implementation)
  sanitizeTelemetryURL: (await vi.importActual<typeof import('../telemetry')>('../telemetry')).sanitizeTelemetryURL,
}));

function model(): AIModel {
  return {
    id: "gpt-4o",
    name: "GPT-4o",
    capabilities: ["text"],
    toolCall: true,
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: "$",
	promptPrice: 0,
	completionPrice: 0,
  };
}

function provider(): Provider {
  return {
    id: "provider-1",
    kind: "openAI",
    status: { kind: "connected" },
    models: [model()],
    catalogModels: [model()],
    apiKey: "sk-test",
    apiKeyPreview: "sk-...test",
  };
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
  };
}

/**
 * These cases exercise agent loop behavior, so the store must hold one active connection:
 * routing requires at least one active source, and with none the library is judged
 * unavailable and the whole path falls back to a plain chat, which other cases cover.
 */
const ACTIVE_NOTION_CONNECTION = {
  id: "notion-1",
  provider: "notion" as const,
  displayName: "Notion",
  scopes: [],
  status: "active" as const,
};

function start(paramsOverride: Record<string, unknown> = {}) {
  const conv = (paramsOverride.conversation as Conversation | undefined) ?? conversation();
  const store = createAppStore({
    conversations: [conv],
    libraryConnections: [ACTIVE_NOTION_CONNECTION],
  });
  const appendChunk = vi.fn();
  const handle = sendLibraryMessage(
    { store, appendChunk, te: (key) => key },
    {
      text: "Find the roadmap",
      prevMessages: [],
      conversation: conv,
      provider: provider(),
      model: model(),
      reasoningMode: "automatic",
      cancelledText: "Cancelled",
      errorTitle: "Failed",
      errorDetail: "Try again",
	  errorDetails: {
		library_needs_reauth: "Reconnect your Library source.",
		library_quota_exceeded: "Monthly Library quota exhausted.",
		library_rate_limited: "Library source is busy.",
		library_unavailable: "Library is unavailable.",
	  },
      ...paramsOverride,
    },
  );
  return { store, appendChunk, handle };
}

beforeEach(() => {
  mocks.runLoop.mockReset();
  mocks.reportSendCompletion.mockReset();
  mocks.toolRememberedFalse.mockReset();
  mocks.toolRememberedFalse.mockReturnValue(false);
  mocks.recordToolFalse.mockReset();
  mocks.searchContext.mockReset();
  mocks.searchContext.mockResolvedValue(null);
  mocks.forwardSearch.mockReset();
});

describe("sendLibraryMessage", () => {
  it('records a successful explicit fallback for a manual model id (D5 eligible) and keeps the static notice visible', async () => {
    mocks.runLoop.mockResolvedValue({
      text: 'Plain answer', citations: [], steps: [], toolFallbackApplied: true,
    });
    const { store, handle } = start({ model: { ...model(), isManual: true } });
    await handle.done;

    expect(mocks.recordToolFalse).toHaveBeenCalledWith(expect.objectContaining({
      connectionId: 'provider-1',
      authMode: 'apiKey',
      canonicalModelId: 'gpt-4o',
      finalTransport: 'openai_chat',
    }));
    const assistant = store.getState().conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant).toMatchObject({ state: 'delivered', toolFallbackNotice: 'library_not_searched' });
  });

  it('does not record false for a catalog model after a successful explicit fallback (D5)', async () => {
    mocks.runLoop.mockResolvedValue({
      text: 'Plain answer', citations: [], steps: [], toolFallbackApplied: true,
    });
    const { store, handle } = start();
    await handle.done;

    expect(mocks.recordToolFalse).not.toHaveBeenCalled();
    const assistant = store.getState().conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant).toMatchObject({ state: 'delivered', toolFallbackNotice: 'library_not_searched' });
  });

  it('remembered false keeps the next send out of the agent loop (the route gate reads the same verdict)', async () => {
    mocks.toolRememberedFalse.mockReturnValue(true);
    mocks.runLoop.mockResolvedValue({ text: 'Next plain answer', citations: [], steps: [] });
    const { handle } = start();
    await handle.done;

    expect(mocks.runLoop).not.toHaveBeenCalled();
    expect(mocks.recordToolFalse).not.toHaveBeenCalled();
  });

  it('does not record false when the explicit resend fails', async () => {
    mocks.runLoop.mockRejectedValue(Object.assign(new Error('fallback failed'), {
      code: 'unknown', source: 'provider',
    }));
    const { handle } = start();
    await handle.done;
    expect(mocks.recordToolFalse).not.toHaveBeenCalled();
  });

  it("commits the final answer directly and clears streaming without a stale queued chunk", async () => {
    mocks.runLoop.mockResolvedValue({
      text: "Grounded answer [1].",
      citations: [],
      steps: [],
    });
    const { store, appendChunk, handle } = start();

    await handle.done;

    expect(appendChunk).not.toHaveBeenCalled();
    expect(mocks.runLoop).toHaveBeenCalledWith(
      expect.objectContaining({ modelContextLength: 128_000 }),
    );
    const loopMessages = mocks.runLoop.mock.calls[0][0].messages as Array<{ role: string; content: string }>;
    // The only system message = the assembler's plan.system (purpose toolLoopLeg), with the library tool description at the end.
    const planSystem = ContextAssembler.assemble({
      purpose: "toolLoopLeg",
      window: { W: null, windowKind: "total", maxOutput: {} },
      conversation: { id: "conv-1", useMemory: true },
      history: [],
      toolSafety: LIBRARY_TOOL_SAFETY_PROMPT,
    }).system;
    expect(loopMessages[0]).toEqual({ role: "system", content: planSystem });
    expect(loopMessages.filter((message) => message.role === "system")).toHaveLength(1);
    expect(loopMessages[0].content).toContain("process the current user input");
    expect(loopMessages[0].content).not.toContain("user question");
    const assistant = store
      .getState()
      .conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant).toMatchObject({
      text: "Grounded answer [1].",
      state: "delivered",
      libraryResearchEnabled: true,
    });
    expect(store.getState().streamingConversationIds).not.toContain("conv-1");
  });

  // The highest priority of the five scope layers is the one-off transient value.
  // The resolve() call must be threaded all the way through, so transient is not a dead parameter.
  it("threads transientGenerationParameters into buildStreamOptionsFromIntent", async () => {
    mocks.runLoop.mockResolvedValue({
      text: "Grounded answer [1].",
      citations: [],
      steps: [],
    });
    (buildStreamOptionsFromIntent as Mock).mockClear();
    const { handle } = start({
      transientGenerationParameters: { temperature: valueOverride(0.9) },
    });

    await handle.done;

    expect((buildStreamOptionsFromIntent as Mock).mock.calls.some((args: unknown[]) =>
      (args[3] as Record<string, unknown> | undefined)?.temperature != null,
    )).toBe(true);
  });

  it("does not overwrite an interrupted message when active-stream aborts first", async () => {
    mocks.runLoop.mockImplementation(
      ({ signal }: { signal: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          signal.addEventListener(
            "abort",
            () => reject(new DOMException("Aborted", "AbortError")),
            { once: true },
          );
        }),
    );
    const { store, handle } = start();
    await vi.waitFor(() => expect(mocks.runLoop).toHaveBeenCalledOnce());
    store.getState().updateConversation("conv-1", {
      messages: store.getState().conversations[0].messages.map((message) =>
        message.id === handle.msgId
          ? {
              ...message,
              text: "Existing partial",
              state: "interrupted" as const,
            }
          : message,
      ),
    });

    handle.abort();
    await handle.done;

    const assistant = store
      .getState()
      .conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant).toMatchObject({
      text: "Existing partial",
      state: "interrupted",
      libraryResearchEnabled: true,
    });
    expect(store.getState().streamingConversationIds).not.toContain("conv-1");
  });

  it("reports aggregate multi-leg usage through the existing Usage and Budget pipeline", async () => {
    const usage = {
      prompt_tokens: 120,
      completion_tokens: 30,
      total_tokens: 150,
    };
    mocks.runLoop.mockResolvedValue({
      text: "Answer.",
      citations: [],
      steps: [],
      usage,
    });
    const { handle } = start();

    await handle.done;

    expect(mocks.reportSendCompletion).toHaveBeenCalledWith(
      expect.objectContaining({
        conversationId: "conv-1",
        usage,
      }),
    );
  });

  it("records partial model usage and cost when a later Library tool fails", async () => {
    const usage = {
      prompt_tokens: 80,
      completion_tokens: 20,
      total_tokens: 100,
    };
    mocks.runLoop.mockImplementation(
      ({ onUsage }: { onUsage: (value: typeof usage) => void }) => {
        onUsage(usage);
        throw Object.assign(new Error("source failed"), {
          code: "library_source_error",
        });
      },
    );
    const { store, handle } = start();

    await handle.done;

    const assistant = store
      .getState()
      .conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant).toMatchObject({
      state: "failed",
      estimatedCost: 0.42,
      costSource: "localEstimate",
      libraryResearchEnabled: true,
    });
  });

  it("records partial model usage when the user aborts a later leg", async () => {
    const usage = {
      prompt_tokens: 40,
      completion_tokens: 10,
      total_tokens: 50,
    };
    mocks.runLoop.mockImplementation(
      ({
        signal,
        onUsage,
      }: {
        signal: AbortSignal;
        onUsage: (value: typeof usage) => void;
      }) => {
        onUsage(usage);
        return new Promise((_resolve, reject) => {
          signal.addEventListener(
            "abort",
            () => reject(new DOMException("Aborted", "AbortError")),
            { once: true },
          );
        });
      },
    );
    const { store, handle } = start();
    await vi.waitFor(() => expect(mocks.runLoop).toHaveBeenCalledOnce());
    handle.abort();
    await handle.done;

    const assistant = store
      .getState()
      .conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant).toMatchObject({
      state: "interrupted",
      estimatedCost: 0.42,
    });
  });

  it.each([
	["library_needs_reauth", "Reconnect your Library source."],
	["library_quota_exceeded", "Monthly Library quota exhausted."],
	["library_rate_limited", "Library source is busy."],
	["library_source_error", "Library is unavailable."],
  ])("stores localized recovery detail for %s", async (code, detail) => {
	mocks.runLoop.mockRejectedValue(Object.assign(new Error("raw upstream error"), { code }));
	const { store, handle } = start();

	await handle.done;

	const assistant = store
	  .getState()
	  .conversations[0].messages.find((message) => message.id === handle.msgId);
	expect(assistant).toMatchObject({
	  state: "failed",
	  errorKind: code,
	  errorDetail: detail,
	});
	expect(assistant?.errorDetail).not.toContain("raw upstream error");
  });

  it("keeps provider response text in Library model legs", async () => {
	mocks.runLoop.mockRejectedValue(Object.assign(new Error("The engine is currently overloaded"), {
	  code: "rateLimited",
	  source: "provider",
	}));
	const { store, handle } = start();

	await handle.done;

	const assistant = store
	  .getState()
	  .conversations[0].messages.find((message) => message.id === handle.msgId);
	expect(assistant).toMatchObject({
	  state: "failed",
	  errorKind: "rateLimited",
	  errorSource: "provider",
	  errorDetail: "The engine is currently overloaded",
	});
  });
});

describe("official connection first leg rejected by signature", () => {
  // The library agent's first leg carries an image and the upstream rejects it with a DashScope signature: official and relay connections share this one script.
  // laterLeg: after the first leg is rejected the loop sends another leg (e.g. resendWithoutTools); failsAfterOutput fails after emitting text, rejectedBeforeOutput is rejected with the same signature before any text.
  async function runImageRejectedFirstLeg(
    kind: string, connectionId: string, extra: Partial<Provider> = {},
    laterLeg: false | "failsAfterOutput" | "rejectedBeforeOutput" = false,
  ) {
    localStorage.removeItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY);
    vi.mocked(trackEvent).mockClear();
    vi.mocked(sendLibraryAgentLeg).mockClear();
    const qwenModel = {
      ...model(), id: "ZHIPU/GLM-5.3", name: "GLM-5.3", transport: "openai_chat_completions",
      capabilityControls: { vision_input: { state: "unknown", reasonCode: "catalog_silent", wireFamily: "openai_chat.image_url" } },
    } as unknown as AIModel;
    const qwen = {
      ...provider(), id: connectionId, kind, models: [qwenModel], catalogModels: [qwenModel], authMode: "apiKey", ...extra,
    } as Provider;
    const body = "{\"error\":{\"code\":\"invalid_parameter_error\",\"message\":\"The provided messages input is invalid. The error info is [Unexpected item type in content]\"}}";
    vi.mocked(sendLibraryAgentLeg).mockReturnValueOnce({
      stream: new ReadableStream<StreamEvent>({
        start(controller) {
          controller.enqueue({ type: "error", error: "Bad request", errorDetail: body, status: 400, source: "provider" });
          controller.close();
        },
      }),
      abort: vi.fn(),
    } as unknown as ReturnType<typeof sendLibraryAgentLeg>);
    if (laterLeg) {
      vi.mocked(sendLibraryAgentLeg).mockReturnValueOnce({
        stream: new ReadableStream<StreamEvent>({
          start(controller) {
            if (laterLeg === "rejectedBeforeOutput") {
              controller.enqueue({ type: "error", error: "Bad request", errorDetail: body, status: 400, source: "provider" });
            } else {
              controller.enqueue({ type: "delta", content: "The picture shows" });
              controller.enqueue({ type: "error", error: "Connection reset", status: 502, source: "provider" });
            }
            controller.close();
          },
        }),
        abort: vi.fn(),
      } as unknown as ReturnType<typeof sendLibraryAgentLeg>);
    }
    mocks.runLoop.mockImplementationOnce(async (args: {
      runLeg: (leg: { messages: unknown[]; tools: unknown[] }) => { stream: ReadableStream<StreamEvent> };
    }) => {
      const handle = args.runLeg({
        messages: [{
          role: "user",
          content: [
            { type: "text", text: "What is in this picture?" },
            { type: "image_url", image_url: { url: "data:image/png;base64,iVBORw0KGgoREJECTEDIMAGE" } },
          ],
        }],
        tools: [],
      });
      const reader = handle.stream.getReader();
      while (!(await reader.read()).done) { /* drain */ }
      if (laterLeg) {
        const second = args.runLeg({ messages: [{ role: "user", content: "What is in this picture?" }], tools: [] });
        const secondReader = second.stream.getReader();
        while (!(await secondReader.read()).done) { /* drain */ }
        throw Object.assign(new Error("Connection reset"), { code: "upstream", source: "provider" });
      }
      throw Object.assign(new Error("Bad request"), { code: "badRequest", source: "provider" });
    });
    // The conversation is bound to the connection actually used for sending (a conversation bound to a connection not in the list refuses to send).
    const conv = { ...conversation(), providerID: connectionId, providerKind: kind } as Conversation;
    const { store, handle } = start({ provider: qwen, model: qwenModel, conversation: conv });
    await handle.done;
    const assistant = store.getState().conversations[0].messages.find((message) => message.id === handle.msgId);
    const entries = (JSON.parse(localStorage.getItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY) ?? "{\"entries\":[]}") as {
      entries: Array<Record<string, unknown>>;
    }).entries;
    const rejectedEvents = vi.mocked(trackEvent).mock.calls.filter(([name]) => name === "input_capability_rejected");
    return { assistant, entries, rejectedEvents };
  }

  it("WEB-REJECTION-RECOVERY-library_send_records_rejection", async () => {
    const { assistant, entries, rejectedEvents } = await runImageRejectedFirstLeg("qwen", "official-qwen");

    expect(sendLibraryAgentLeg).toHaveBeenCalledTimes(1);
    // Assert on the failed message actually landed in the store: an image-rejection record with the signature source, from which the failure card offers a one-tap action + model switch.
    expect(assistant).toMatchObject({ state: "failed" });
    expect(assistant!.inputRejection).toEqual({
      capabilityKey: "vision_input", signatureId: "dashscope.unexpected_item_type",
    });
    expect(entries).toEqual([expect.objectContaining({
      connectionId: "official-qwen", modelId: "ZHIPU/GLM-5.3", capabilityKey: "vision_input",
      wireFamily: "openai_chat.image_url", signatureId: "dashscope.unexpected_item_type",
    })]);
    expect(rejectedEvents).toEqual([[
      "input_capability_rejected",
      {
        provider_kind: "qwen", model_id: expect.any(String), capability_key: "vision_input",
        signature_id: "dashscope.unexpected_item_type", wire_family: "openai_chat.image_url",
      },
    ]]);
  });

  it("WEB-REJECTION-RECOVERY-library_send_relay_no_record", async () => {
    // The telemetry on a relay send reads the runtime config; this file mocks it to undefined by default.
    const metadata = await import("../metadata/metadata-client");
    vi.mocked(metadata.getRelayRuntimeConfig).mockReturnValue(metadata.DEFAULT_RELAY_RUNTIME_CONFIG);
    let run: Awaited<ReturnType<typeof runImageRejectedFirstLeg>>;
    try {
      run = await runImageRejectedFirstLeg("relay", "relay-1", {
        baseURLText: "https://relay.example.com/v1", relayKind: "openai_compatible",
        relayRequested: { transport: "openai_chat_completions", authMode: "bearer" },
        relayKeys: [{ id: "initial", apiKey: "sk-relay" }],
      } as Partial<Provider>);
    } finally {
      vi.mocked(metadata.getRelayRuntimeConfig).mockReset();
    }
    const { assistant, entries, rejectedEvents } = run;

    expect(sendLibraryAgentLeg).toHaveBeenCalledTimes(1);
    // A relay runs its own loop: no negative cache, no report, and the failed message carries no official rejection record.
    expect(assistant).toMatchObject({ state: "failed" });
    expect(assistant!.inputRejection).toBeUndefined();
    expect(assistant!.generationParameterRejection).toBeUndefined();
    expect(entries).toEqual([]);
    expect(rejectedEvents).toEqual([]);
  });

  it("WEB-REJECTION-RECOVERY-library_later_leg_failure_drops_first_leg_record", async () => {
    const { assistant, entries, rejectedEvents } = await runImageRejectedFirstLeg("qwen", "official-qwen", {}, "failsAfterOutput");

    expect(sendLibraryAgentLeg).toHaveBeenCalledTimes(2);
    // What failed this time is the second leg, which had emitted text: the failed message does not carry the first leg's rejection record.
    expect(assistant).toMatchObject({ state: "failed" });
    expect(assistant!.inputRejection).toBeUndefined();
    expect(assistant!.generationParameterRejection).toBeUndefined();
    // The first leg really was rejected: the negative cache and the report stay, not withdrawn.
    expect(entries).toEqual([expect.objectContaining({
      connectionId: "official-qwen", modelId: "ZHIPU/GLM-5.3", capabilityKey: "vision_input",
      signatureId: "dashscope.unexpected_item_type",
    })]);
    expect(rejectedEvents).toHaveLength(1);
  });

  it("WEB-REJECTION-RECOVERY-library_later_leg_rejected_before_output_keeps_record", async () => {
    const { assistant, entries, rejectedEvents } = await runImageRejectedFirstLeg(
      "qwen", "official-qwen", {}, "rejectedBeforeOutput",
    );

    expect(sendLibraryAgentLeg).toHaveBeenCalledTimes(2);
    // A later leg fails before emitting text: the rejection still stands, the failed message carries the first leg's rejection record, and the failure card offers a one-tap action.
    expect(assistant).toMatchObject({ state: "failed" });
    expect(assistant!.inputRejection).toEqual({
      capabilityKey: "vision_input", signatureId: "dashscope.unexpected_item_type",
    });
    expect(entries).toEqual([expect.objectContaining({
      connectionId: "official-qwen", modelId: "ZHIPU/GLM-5.3", capabilityKey: "vision_input",
      signatureId: "dashscope.unexpected_item_type",
    })]);
    expect(rejectedEvents).toHaveLength(1);
  });
});

describe("resolveActiveSources", () => {
  it("restricts research to explicitly mentioned connected sources", () => {
    expect(resolveActiveSources("Compare @Google Docs with the plan", ["notion", "google"]))
      .toEqual(["google"]);
  });

  it("uses every connected source when the question has no source mention", () => {
    expect(resolveActiveSources("Compare the plan", ["notion", "google"]))
      .toEqual(["notion", "google"]);
  });

  it("does not silently widen an unavailable explicit source", () => {
    expect(resolveActiveSources("Read @Notion", ["google"])).toEqual([]);
  });
});

describe("Library message recovery", () => {
  function recoveryMessages(state: ChatMessage["state"]): ChatMessage[] {
    return [
      {
        id: "user-1",
        role: "user",
        text: "Find the roadmap",
        state: "delivered",
        createdAt: "2026-07-24T00:00:00.000Z",
        providerKind: "openAI",
        providerName: "OpenAI",
        modelName: "GPT-4o",
        estimatedCost: 0,
      },
      {
        id: "assistant-1",
        role: "assistant",
        text: state === "failed" ? "" : "Partial answer",
        state,
        createdAt: "2026-07-24T00:00:00.001Z",
        providerID: "provider-1",
        providerKind: "openAI",
        providerName: "OpenAI",
        modelID: "gpt-4o",
        modelName: "GPT-4o",
        libraryResearchEnabled: true,
        estimatedCost: 1,
        researchSteps: [
          {
            id: "step-1",
            tool: "library_search",
            label: "Search roadmap",
            status: "completed",
            step: 1,
          },
        ],
      },
    ];
  }

  function recoveryStart(state: ChatMessage["state"]) {
    const conv = { ...conversation(), messages: recoveryMessages(state) };
    const store = createAppStore({
      conversations: [conv],
      libraryConnections: [ACTIVE_NOTION_CONNECTION],
    });
    const ctx = { store, appendChunk: vi.fn(), te: (key: string) => key };
    const presentation = {
      cancelledText: "Cancelled",
      errorTitle: "Failed",
      errorDetail: "Try again",
    };
    return { conv, store, ctx, presentation };
  }

  it("retries a failed Library response in place and keeps its mode marker", async () => {
    mocks.runLoop.mockResolvedValue({
      text: "Recovered answer",
      citations: [],
      steps: [],
    });
    const { conv, store, ctx, presentation } = recoveryStart("failed");

    const handle = retryLibraryMessage(ctx, {
      messageId: "assistant-1",
      conversation: conv,
      messages: conv.messages,
      provider: provider(),
      model: model(),
      reasoningMode: "automatic",
      ...presentation,
    });
    expect(handle).not.toBeNull();
    await handle?.done;

    const messages = store.getState().conversations[0].messages;
    expect(messages).toHaveLength(2);
    expect(messages[1]).toMatchObject({
      id: "assistant-1",
      text: "Recovered answer",
      state: "delivered",
      libraryResearchEnabled: true,
      researchSteps: [],
    });
  });

  it("continues a Library response as plain text continuation without the agent loop", async () => {
    // Continue only does text continuation: even if routing decides agent, it no longer enters the tool loop; request body shape: see
    // context-pipeline/continue.test.ts continue_library_agent_no_tool_loop.
    const { conv, store, ctx, presentation } = recoveryStart("interrupted");

    const handle = continueLibraryAnswering(ctx, {
      messageId: "assistant-1",
      conversation: conv,
      messages: conv.messages,
      provider: provider(),
      model: model(),
      reasoningMode: "automatic",
      ...presentation,
    });
    await handle.done;

    expect(mocks.runLoop).not.toHaveBeenCalled();
    const messages = store.getState().conversations[0].messages;
    expect(messages).toHaveLength(2);
    expect(messages[1]).toMatchObject({
      id: "assistant-1",
      libraryResearchEnabled: true,
    });
    expect(messages[1].researchSteps).toEqual([
      expect.objectContaining({ id: "step-1", step: 1 }),
    ]);
  });
});

describe("library + external web search (shared tool loop)", () => {
  const view = {
    record: { id: "svc-tv", kind: "preset", serviceId: "tavily", name: "Tavily", regionId: "global", boundHost: "api.tavily.com", connectionRef: null, createdAt: 1, updatedAt: 1 },
    name: "Tavily",
    keySource: "own",
    hasKey: true,
    keyTail: "0000",
    row: { status: "ready", label: "preset", keySource: "own", connectionName: null },
    resultCount: 5,
  };
  const searchContext = {
    state: { route: { path: "external_tool" }, source: { method: "external", serviceId: "svc-tv", notice: null, nextStored: null, changed: false } },
    data: { uid: "guest", catalog: { available: true, entries: [], withdrawn: [] }, connections: [], snapshot: { services: [view], defaultId: "svc-tv" } },
  };

  it("registry includes web_search, web numbering follows library numbering, sources and facts are persisted", async () => {
    mocks.searchContext.mockResolvedValue(searchContext);
    mocks.forwardSearch.mockResolvedValue({
      ok: true,
      latencyMs: 400,
      results: [
        { title: "Web A", url: "https://a.example/", snippet: "a" },
        { title: "Web B", url: "https://b.example/", snippet: "b" },
      ],
    });
    let webContent = "";
    let laterLibraryIndex = 0;
    mocks.runLoop.mockImplementation(async (options: {
      additionalEntries?: Array<{ name: string; execute: (call: unknown, ctx: unknown) => Promise<{ content: string }> }>;
      allocateCitationIndex?: (key: string, fallback: number) => number;
    }) => {
      const web = options.additionalEntries?.find((entry) => entry.name === "web_search");
      expect(web).toBeDefined();
      // The library reads one document first (search state not open yet → uses this loop's number 1, then enters the allocator via priorBatches)
      expect(options.allocateCitationIndex?.("notion:doc-1", 1)).toBe(1);
      webContent = (await web!.execute(
        { id: "c1", type: "function", function: { name: "web_search", arguments: JSON.stringify({ query: "roadmap" }) } },
        { callID: "c1", stepNumber: 2, legIndex: 1, signal: new AbortController().signal },
      )).content;
      // The library reads another document after the search: shares the allocator with web results, numbered after the web results
      laterLibraryIndex = options.allocateCitationIndex!("notion:doc-2", 2);
      return {
        text: "Answer [1] [2]",
        citations: [{ url: "https://www.notion.so/doc-1", title: "Doc 1", source: "notion", docId: "doc-1", index: 1 }],
        steps: [],
      };
    });
    const { store, handle } = start({ reasoningMode: "fast" });
    await handle.done;

    expect([...webContent.matchAll(/<result id="(\d+)"/g)].map((m) => Number(m[1]))).toEqual([2, 3]);
    expect(laterLibraryIndex).toBe(4);
    const assistant = store.getState().conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant?.citations?.map((c) => [c.source, c.index])).toEqual([["notion", 1], ["external_search", 2], ["external_search", 3]]);
    expect(assistant?.citations?.[1]).toMatchObject({ serviceId: "svc-tv", serviceName: "Tavily", query: "roadmap" });
    expect(assistant?.capabilityResults).toEqual([expect.objectContaining({ source: "external_search", state: "observed", sourceCount: 2 })]);
    expect(vi.mocked(trackEvent)).toHaveBeenCalledWith("search_executed", expect.objectContaining({ service: "tavily", path: "tool" }));
  });

  it("first leg with web_search rejected (400): switch to pre-search, query = original text, re-answer without tools, persist the tools_rejected notice", async () => {
    mocks.searchContext.mockResolvedValue(searchContext);
    mocks.forwardSearch.mockResolvedValue({
      ok: true,
      latencyMs: 300,
      results: [{ title: "Web A", url: "https://a.example/", snippet: "a" }],
    });
    mocks.runLoop.mockImplementation(async (options: {
      additionalEntries?: Array<{ name: string }>;
      onWebSearchToolsRejected?: (status: number) => Promise<unknown[] | null>;
    }) => {
      expect(options.additionalEntries?.some((entry) => entry.name === "web_search")).toBe(true);
      const replanned = await options.onWebSearchToolsRejected!(400);
      expect(replanned).not.toBeNull();
      return { text: "Answer [1]", citations: [], steps: [], webSearchReplanned: true };
    });
    const { store, handle } = start({ reasoningMode: "fast", conversation: { ...conversation(), id: "conv-rejected" } });
    await handle.done;

    expect(mocks.forwardSearch).toHaveBeenCalledTimes(1);
    expect(mocks.forwardSearch.mock.calls[0][0]).toMatchObject({ query: "Find the roadmap", key: "tv-key-0000" });
    const assistant = store.getState().conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant?.searchNotice).toBe("tools_rejected");
    expect(assistant?.citations?.filter((c) => c.source === "external_search").map((c) => c.index)).toEqual([1]);
    expect(vi.mocked(trackEvent)).toHaveBeenCalledWith("search_executed", expect.objectContaining({ service: "tavily", path: "presearch" }));
  });
});
