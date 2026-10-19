/**
 * propose_memory per-send runtime.
 * - The in-process degraded set: "connection id\nmodel id" pairs whose first tool leg was rejected as
 *   tool-unsupported; they stay on the fallback route until the page reloads.
 * - resolveProposeMemoryMode: reads conversation memory, the auto-suggest preference and the connection's tool
 *   capability, then defers to the shared proposeMemoryMode.
 * - Ordinary sends carry propose_memory only through the chat proxy (sendStreamProxy clientTools); a connection
 *   whose ordinary send bypasses it (relay, Moonshot China direct) stays on the fallback route.
 * - Gemini generateContent rejects a search tool and function tools in one request, so a Gemini transport
 *   (official or relay) with web search on stays on the fallback route.
 * - A request that will send structured output (json_schema) stays on the fallback route, so the shared conflict
 *   rule never drops the schema for the memory tools.
 * - A request carrying native file parts on a line whose tool loop takes no native files stays on the fallback
 *   route, so the file goes out as declared instead of the request being refused.
 */
import type { StoreApi } from 'zustand';
import type { AIModel, Provider } from '@oriveo/shared';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import {
  proposeMemoryDegradedKey,
  proposeMemoryMode,
  type ProposeMemoryMode,
} from '@oriveo/core/context/memory-propose';
import { sameNormalizedID } from '../../utils/id-utils';
import { getActiveUIDSync } from '../../infra/storage/partition';
import type { AppStore } from '../store/app-store';
import { getSkillById } from '../skills/query';
import { connectionSupportsMcpTools } from '../mcp/mcp-chat';
import { memoryAutoSuggestEnabled } from '../memory/memory-candidate-repository';
import { resolvePromptUseMemory } from './prompt-injection';
import { requestBaseURLText } from '../providers/endpoint-source';
import { isMoonshotChinaBaseURL } from '../providers/adapters/moonshot';
import { effectiveCapabilityTransport } from './capability-evidence';

const degraded = new Set<string>();
const GEMINI_GENERATE_CONTENT_TRANSPORTS = new Set(['gemini_generate_content', 'gemini_interactions']);

export function markProposeMemoryDegraded(connectionId: string, modelId: string): void {
  degraded.add(proposeMemoryDegradedKey(connectionId, modelId));
}

export function isProposeMemoryDegraded(connectionId: string, modelId: string): boolean {
  return degraded.has(proposeMemoryDegradedKey(connectionId, modelId));
}

export function __resetProposeMemoryDegradedForTest(): void {
  degraded.clear();
}

export interface ResolveProposeMemoryModeInput {
  store: StoreApi<AppStore>;
  conversationId: string;
  provider: Provider | undefined;
  model: AIModel | undefined;
  /** A fresh user send (not retry, regenerate, edit, continue or recovery). */
  freshSend: boolean;
  /**
   * Effective web search of this send: Moonshot then runs its built-in $web_search loop and Gemini generateContent
   * carries its search tool, so neither attaches client tools.
   */
  webSearchEnabled?: boolean;
  /** Generation parameters this request will send (after resolution and the request-side filter). */
  generationParameters?: GenerationParameterOverrides;
  /** This request carries native file parts that its line would not take once client tools are attached. */
  nativeFilesBlockToolLoop?: boolean;
}

/** The request will send structured output: json_schema survives resolution and the request-side filter. */
export function structuredOutputActive(generationParameters: GenerationParameterOverrides | undefined): boolean {
  return generationParameters?.json_schema?.state === 'value';
}

/**
 * The request can carry client tools: the one predicate shared by propose_memory and search_memory.
 */
export function memoryToolsConnectionSupported(
  provider: Provider | undefined,
  model: AIModel | undefined,
  webSearchEnabled: boolean | undefined,
  generationParameters?: GenerationParameterOverrides,
  nativeFilesBlockToolLoop = false,
): boolean {
  const moonshotWebLoop = provider?.kind === 'moonshot' && webSearchEnabled === true;
  // Gemini's interactions route still falls back to generateContent when video is attached; both are judged by the generateContent rules.
  const geminiWebSearch = webSearchEnabled === true && provider !== undefined && model !== undefined
    && GEMINI_GENERATE_CONTENT_TRANSPORTS.has(effectiveCapabilityTransport(provider, model));
  const bypassesChatProxy = provider?.kind === 'relay'
    || (provider?.kind === 'moonshot' && isMoonshotChinaBaseURL(requestBaseURLText(provider)));
  // When structured output is in effect, no memory tool is attached this turn, so json_schema goes out as usual.
  const structuredOutput = structuredOutputActive(generationParameters);
  // When this turn carries native files and the route's tool loop does not accept native files, no memory tool is attached and the files go out unchanged.
  return !moonshotWebLoop && !geminiWebSearch && !structuredOutput && !nativeFilesBlockToolLoop && !bypassesChatProxy
    && connectionSupportsMcpTools(provider, model);
}

/** Effective useMemory of the conversation (conversation switch, then its skill). */
export function conversationMemoryEnabled(store: StoreApi<AppStore>, conversationId: string): boolean {
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, conversationId));
  const skill = conv?.skillId ? getSkillById(store, conv.skillId) : undefined;
  return resolvePromptUseMemory(conv?.useMemory, skill?.useMemory);
}

export function resolveProposeMemoryMode(input: ResolveProposeMemoryModeInput): ProposeMemoryMode {
  const { store, conversationId, provider, model } = input;
  return proposeMemoryMode({
    purpose: 'chat',
    freshSend: input.freshSend,
    memoryEnabled: conversationMemoryEnabled(store, conversationId),
    autoSuggest: memoryAutoSuggestEnabled(getActiveUIDSync()),
    connectionSupportsTools: memoryToolsConnectionSupported(
      provider, model, input.webSearchEnabled, input.generationParameters, input.nativeFilesBlockToolLoop,
    ),
    degraded: provider !== undefined && model !== undefined && isProposeMemoryDegraded(provider.id, model.id),
  });
}
