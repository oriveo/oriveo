import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AIModel,
  ChatMessage,
  Conversation,
  Provider,
} from "@oriveo/shared";
import { createAppStore } from "../store/app-store";
import {
  continueLibraryAnswering,
  resolveActiveSources,
  retryLibraryMessage,
  sendLibraryMessage,
} from "./operations-library-send";
import { DEFAULT_LIBRARY_RUNTIME_CONFIG } from "../library/types";
import { buildStreamOptionsFromIntent } from "./stream-options";
import { valueOverride } from "./generation-parameter-settings";
import type { Mock } from "vitest";

const mocks = vi.hoisted(() => ({
  runLoop: vi.fn(),
  reportSendCompletion: vi.fn(),
  toolRememberedFalse: vi.fn((_identity: unknown) => false),
  recordToolFalse: vi.fn((_identity: unknown) => undefined),
}));

vi.mock("../../utils/chat-stream-utils", () => ({
  buildChatHistory: vi.fn(async () => []),
  mapErrorKindKey: () => 'network',
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
  // relay  
  telemetryModelID: (await vi.importActual<typeof import('../telemetry')>('../telemetry')).telemetryModelID,
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
  const conv = conversation();
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
});

describe("sendLibraryMessage", () => {
  it('records a successful explicit fallback and keeps the static notice visible', async () => {
    mocks.runLoop.mockResolvedValue({
      text: 'Plain answer', citations: [], steps: [], toolFallbackApplied: true,
    });
    const { store, handle } = start();
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

  it('uses remembered false on the next send and retains the static notice', async () => {
    mocks.toolRememberedFalse.mockReturnValue(true);
    mocks.runLoop.mockResolvedValue({ text: 'Next plain answer', citations: [], steps: [] });
    const { store, handle } = start();
    await handle.done;

    expect(mocks.runLoop).toHaveBeenCalledWith(expect.objectContaining({ toolsEnabled: false }));
    expect(mocks.recordToolFalse).not.toHaveBeenCalled();
    const assistant = store.getState().conversations[0].messages.find((message) => message.id === handle.msgId);
    expect(assistant).toMatchObject({ toolFallbackNotice: 'library_not_searched' });
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
    expect(loopMessages[0]).toMatchObject({ role: "system" });
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

  it("continues a Library response on the same assistant message", async () => {
    mocks.runLoop.mockResolvedValue({
      text: "Additional evidence",
      citations: [],
      steps: [
        {
          id: "step-2",
          tool: "library_read",
          label: "Read roadmap",
          status: "completed",
          step: 1,
        },
      ],
    });
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

    const messages = store.getState().conversations[0].messages;
    expect(messages).toHaveLength(2);
    expect(messages[1]).toMatchObject({
      id: "assistant-1",
      text: "Partial answer\n\nAdditional evidence",
      state: "delivered",
      libraryResearchEnabled: true,
      estimatedCost: 1.42,
    });
    expect(messages[1].researchSteps).toEqual([
      expect.objectContaining({ id: "step-1", step: 1 }),
      expect.objectContaining({ id: "step-2", step: 2 }),
    ]);
  });
});
