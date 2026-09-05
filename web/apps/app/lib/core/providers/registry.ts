/**
 * Provider registry - one table of provider adapters.
 *
 * Replaces repeated switch-case blocks in provider-service.ts with a
 * Record<ProviderKind, ProviderAdapter> for static type safety.
 */

import type { ProviderKind } from "@oriveo/shared";
import type {
  ContentPart,
  SyncResult,
  StreamHandle,
  StreamOptions,
} from "./types";
import * as openRouterService from "./adapters/openrouter";
import * as openAIService from "./adapters/openai";
import * as deepSeekService from "./adapters/deepseek";
import * as grokService from "./adapters/grok";
import * as anthropicService from "./adapters/anthropic";
import * as geminiService from "./adapters/gemini";
import * as togetherService from "./adapters/together";
import * as fireworksService from "./adapters/fireworks";
import * as groqService from "./adapters/groq";
import * as mistralService from "./adapters/mistral";
import * as miniMaxService from "./adapters/minimax";
import * as zhipuService from "./adapters/zhipu";
import * as qwenService from "./adapters/qwen";
import * as moonshotService from "./adapters/moonshot";
import * as siliconFlowService from "./adapters/siliconflow";
import * as relayService from "./adapters/relay";

/* ── Adapter Interface ──────────────────────────────── */

export interface ProviderAdapter {
  validateKey(apiKey: string, baseURL?: string): Promise<void>;
  syncModels(apiKey: string, baseURL?: string): Promise<SyncResult>;
  /**
   * Sixth parameter: webSearchProfileName.
   *
   * service.ts resolves it from model.webSearchProfile or metadata and passes it in; the adapter
   * forwards that profile's mergeParams and streamShape to the underlying strategy. No
   * hard-coded branching on model id.
   */
  sendStream(
    apiKey: string,
    modelID: string,
    messages: {
      role: "user" | "assistant" | "system";
      content: string | ContentPart[];
    }[],
    baseURL?: string,
    options?: StreamOptions,
    webSearchProfileName?: string,
  ): StreamHandle;
}

/* ── Helpers ─────────────────────────────────────────── */

/** Make sure the URL carries a scheme so the browser does not treat it as a relative path */
function normalizeURL(url: string | undefined): string | undefined {
  if (!url) return undefined;
  const trimmed = url.trim().replace(/\/+$/, "");
  if (!trimmed) return undefined;
  if (!/^https?:\/\//i.test(trimmed)) return `https://${trimmed}`;
  return trimmed;
}

/** Require baseURL to be present, replacing a non-null assertion */
function requireURL(url: string | undefined, providerName: string): string {
  const safe = normalizeURL(url);
  if (!safe) throw new Error(`Base URL is required for ${providerName}`);
  return safe;
}

function createNoopStream(): StreamHandle {
  return {
    stream: new ReadableStream<never>({
      start(controller) {
        controller.close();
      },
    }) as ReadableStream,
    abort: () => {},
  };
}

/* ── Registry ───────────────────────────────────────── */

const registry: Record<ProviderKind, ProviderAdapter> = {
  openRouter: {
    validateKey: (apiKey) => openRouterService.validateKey(apiKey),
    syncModels: (apiKey) => openRouterService.syncModels(apiKey),
    sendStream: (apiKey, modelID, messages, _baseURL, options, webSearchProfileName) =>
      openRouterService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        options,
        options?.supportsImageGen,
        webSearchProfileName,
      ),
  },

  openAI: {
    validateKey: (apiKey) =>
      openAIService.validateKey(apiKey),
    syncModels: (apiKey, baseURL) =>
      openAIService.syncModels(apiKey, normalizeURL(baseURL)),
    sendStream: (apiKey, modelID, messages, baseURL, options, webSearchProfileName) =>
      openAIService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
        webSearchProfileName,
      ),
  },

  deepseek: {
    validateKey: (apiKey, baseURL) =>
      deepSeekService.validateKey(apiKey, requireURL(baseURL, "DeepSeek")),
    syncModels: (apiKey, baseURL) =>
      deepSeekService.syncModels(apiKey, requireURL(baseURL, "DeepSeek")),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      deepSeekService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        requireURL(baseURL, "DeepSeek"),
        options,
      ),
  },

  grok: {
    validateKey: (apiKey, baseURL) =>
      grokService.validateKey(apiKey, requireURL(baseURL, "Grok")),
    syncModels: (apiKey, baseURL) =>
      grokService.syncModels(apiKey, requireURL(baseURL, "Grok")),
    sendStream: (apiKey, modelID, messages, baseURL, options, webSearchProfileName) =>
      grokService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        requireURL(baseURL, "Grok"),
        options,
        webSearchProfileName,
      ),
  },

  mistral: {
    validateKey: (apiKey, baseURL) =>
      mistralService.validateKey(apiKey, requireURL(baseURL, "Mistral")),
    syncModels: (apiKey, baseURL) =>
      mistralService.syncModels(apiKey, requireURL(baseURL, "Mistral")),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      mistralService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
      ),
  },

  // Relay uses the OpenAI-compatible API directly and does not go through metadata
  relay: {
    validateKey: (apiKey, baseURL) =>
      openAIService.validateKeyDirect(apiKey, normalizeURL(baseURL)),
    syncModels: (apiKey, baseURL) =>
      openAIService.syncModelsDirect(apiKey, normalizeURL(baseURL)),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      relayService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
      ),
  },

  anthropic: {
    validateKey: (apiKey, baseURL) =>
      anthropicService.validateKey(apiKey, normalizeURL(baseURL)),
    syncModels: (apiKey, baseURL) =>
      anthropicService.syncModels(apiKey, normalizeURL(baseURL)),
    sendStream: (apiKey, modelID, messages, baseURL, options, webSearchProfileName) =>
      anthropicService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
        webSearchProfileName,
      ),
  },

  gemini: {
    validateKey: (apiKey, baseURL) =>
      geminiService.validateKey(apiKey, normalizeURL(baseURL)),
    syncModels: (apiKey, baseURL) =>
      geminiService.syncModels(apiKey, normalizeURL(baseURL)),
    sendStream: (apiKey, modelID, messages, baseURL, options, webSearchProfileName) =>
      geminiService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
        webSearchProfileName,
      ),
  },

  groq: {
    validateKey: (apiKey, baseURL) =>
      groqService.validateKey(apiKey, requireURL(baseURL, "Groq")),
    syncModels: (apiKey, baseURL) =>
      groqService.syncModels(apiKey, requireURL(baseURL, "Groq")),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      groqService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
      ),
  },

  togetherAI: {
    validateKey: (apiKey, baseURL) =>
      togetherService.validateKey(apiKey, requireURL(baseURL, "Together AI")),
    syncModels: (apiKey, baseURL) =>
      togetherService.syncModels(apiKey, requireURL(baseURL, "Together AI")),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      togetherService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
      ),
  },

  fireworksAI: {
    validateKey: (apiKey, baseURL) =>
      fireworksService.validateKey(apiKey, requireURL(baseURL, "Fireworks AI")),
    syncModels: (apiKey, baseURL) =>
      fireworksService.syncModels(apiKey, requireURL(baseURL, "Fireworks AI")),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      fireworksService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
      ),
  },

  miniMax: {
    validateKey: (apiKey, baseURL) =>
      miniMaxService.validateKey(apiKey, requireURL(baseURL, "MiniMax")),
    syncModels: (apiKey, baseURL) =>
      miniMaxService.syncModels(apiKey, requireURL(baseURL, "MiniMax")),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      miniMaxService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
      ),
  },

  zhipu: {
    validateKey: (apiKey, baseURL) =>
      zhipuService.validateKey(apiKey, requireURL(baseURL, "Z.ai")),
    syncModels: (apiKey, baseURL) =>
      zhipuService.syncModels(apiKey, requireURL(baseURL, "Z.ai")),
    sendStream: (apiKey, modelID, messages, baseURL, options, webSearchProfileName) =>
      zhipuService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
        webSearchProfileName,
      ),
  },

  qwen: {
    validateKey: (apiKey, baseURL) =>
      qwenService.validateKey(apiKey, requireURL(baseURL, "Qwen")),
    syncModels: (apiKey, baseURL) =>
      qwenService.syncModels(apiKey, requireURL(baseURL, "Qwen")),
    // Qwen switches to the native DashScope mode
    sendStream: (apiKey, modelID, messages, baseURL, options, webSearchProfileName) =>
      qwenService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
        webSearchProfileName,
      ),
  },

  moonshot: {
    validateKey: (apiKey, baseURL) =>
      moonshotService.validateKey(apiKey, requireURL(baseURL, "Kimi")),
    syncModels: (apiKey, baseURL) =>
      moonshotService.syncModels(apiKey, requireURL(baseURL, "Kimi")),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      moonshotService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        requireURL(baseURL, "Kimi"),
        options,
      ),
  },

  siliconFlow: {
    validateKey: (apiKey, baseURL) =>
      siliconFlowService.validateKey(
        apiKey,
        requireURL(baseURL, "SiliconFlow"),
      ),
    syncModels: (apiKey, baseURL) =>
      siliconFlowService.syncModels(apiKey, requireURL(baseURL, "SiliconFlow")),
    sendStream: (apiKey, modelID, messages, baseURL, options) =>
      siliconFlowService.sendMessageStream(
        apiKey,
        modelID,
        messages,
        normalizeURL(baseURL),
        options,
      ),
  },
};

/** Get the adapter for a given provider */
export function getAdapter(kind: ProviderKind): ProviderAdapter {
  return registry[kind];
}
