import type { LocalEngineKind, RelayModelTransport } from '@oriveo/shared';
import { modelControlTransportLabel } from '../../../../lib/core/chat/model-control-capability-layout';
import type { LocalBrowserConnectionResult } from '../../../../lib/core/providers/local-browser-probe';

/**
 * View state of the two add-page boards (Setup / LocalSetup). Components render only from what is produced here;
 * the structure tests (BOARD-SETUP-01 to 08) assert against this too: copy keys, slot order, detection card, button states.
 * Relay step 1 / step 2 state lives in relay-setup-two-step; manual setup lives in manual-setup-board.
 */

export type SetupCardState = 'hidden' | 'detecting' | 'succeeded' | 'failed';
export type SetupPrimaryButton = 'detectConnectionSettings' | 'connectAndSave';
/** The protocol chip name of each model in step 2 is a protocol proper noun and is not translated. */
export type SetupProtocol = 'Chat' | 'Responses' | 'Messages' | 'Gemini';

export function setupProtocolForTransport(transport: RelayModelTransport | string): SetupProtocol {
  if (transport === 'openai_responses') return 'Responses';
  if (transport === 'anthropic_messages') return 'Messages';
  if (transport === 'gemini_generate_content') return 'Gemini';
  return 'Chat';
}

// MARK: - Relay

/** The subtitle is the two-step copy (fill in address and key first, then pick models on the next step). */
export const RELAY_SETUP_HERO_KEYS = ['heroLabel', 'heroTitle', 'twoStep.heroSubtitle'] as const;
/** Step 1 slot order: no default model slot; the name appears only with two or more keys. */
export const RELAY_SETUP_SLOTS = ['endpoint', 'apiKey', 'keyName', 'addKey'] as const;
export const RELAY_SETUP_SECONDARY_KEY = 'manualProtocol';

// MARK: - Local

export type LocalChannel = 'chat' | 'native';
export type LocalThinkingValueKey = 'localThinkingTemplate' | 'localThinkingModel' | 'localValueUnsupported';

export const LOCAL_SETUP_HERO_KEYS = ['localHeroLabel', 'localHeroTitle', 'localHeroSubtitle'] as const;
export const LOCAL_SETUP_SECONDARY_KEY = 'localManualEngine';
export const LOCAL_SETUP_ENGINES: readonly LocalEngineKind[] = ['ollama', 'llamacpp', 'lmstudio', 'vllm', 'openwebui'];

/** Engine proper nouns are not localized. */
export function localEngineDisplayName(engine: LocalEngineKind): string {
  if (engine === 'llamacpp') return 'llama.cpp';
  if (engine === 'lmstudio') return 'LM Studio';
  if (engine === 'vllm') return 'vLLM';
  if (engine === 'openwebui') return 'Open WebUI';
  return 'Ollama';
}

export function localChannelTransport(channel: LocalChannel): 'openai_chat_completions' | 'llamacpp_native' {
  return channel === 'native' ? 'llamacpp_native' : 'openai_chat_completions';
}

/**
 * Protocol names inside the relay family (channel name / networking section title): the two OpenAI entries carry a vendor prefix, and protocol proper nouns are not translated (same as iOS);
 * the rest follow the same table as the model options panel. The modelControlTransportLabel shared by the chat page is unchanged.
 */
export function relayFamilyTransportLabel(transport: string): string | undefined {
  if (transport === 'openai_chat_completions') return 'OpenAI Chat Completions';
  if (transport === 'openai_responses') return 'OpenAI Responses';
  return modelControlTransportLabel(transport);
}

/** Channel display names for the channel cell and the channel menu. */
export function localChannelDisplayName(channel: LocalChannel): string {
  return relayFamilyTransportLabel(localChannelTransport(channel)) ?? '';
}

/**
 * Write-path table (engine-expectations.v1.json thinking.writePaths): writable -> per chat template;
 * not writable -> decided by the model; Ollama declaring thinking=false -> unsupported. The llama.cpp native channel is also not writable.
 */
export function localThinkingValueKey(
  engine: LocalEngineKind,
  channel: LocalChannel,
  declaredThinking: boolean | undefined,
): LocalThinkingValueKey {
  if (engine === 'llamacpp' && channel === 'chat') return 'localThinkingTemplate';
  if (engine === 'ollama' && declaredThinking === false) return 'localValueUnsupported';
  return 'localThinkingModel';
}

/** 2048 -> 2K; returns null when it cannot be measured, and the caller shows "not available" (never 0). */
export function formatLocalContextLength(value: number | undefined): string | null {
  if (!value || !Number.isFinite(value) || value <= 0) return null;
  if (value >= 1_048_576 && value % 1_048_576 === 0) return `${value / 1_048_576}M`;
  if (value >= 1024) return `${Math.round(value / 1024)}K`;
  return String(value);
}

export type LocalSetupSlot = 'endpoint' | 'apiKey';

/** Result of one detection on this page: connection result + which engine / channel was used; unrecognized when the fingerprint was not recognized. */
export type LocalSetupConnectionValue = LocalBrowserConnectionResult & {
  engine?: LocalEngineKind;
  channel?: LocalChannel;
  unrecognized?: boolean;
};

export interface LocalSetupSummary {
  engine: string;
  modelCount: number;
  channel: string;
  /** null = show "not available". */
  contextLength: string | null;
  thinking: LocalThinkingValueKey;
}

export interface LocalSetupBoard {
  slots: LocalSetupSlot[];
  card: SetupCardState;
  summary: LocalSetupSummary | null;
  failure: 'unrecognized' | 'connection' | null;
  showsManualPicker: boolean;
  showsChannelPicker: boolean;
  primaryButton: SetupPrimaryButton;
  isPrimaryEnabled: boolean;
  /** LAN http -> W1 note row, primary button disabled. */
  lanHttpBlocked: boolean;
}

export function localSetupBoard(input: {
  result: LocalSetupConnectionValue | null;
  isDetecting: boolean;
  endpointAccess: 'empty' | 'invalid' | 'lan_http_blocked' | 'allowed';
  manualExpanded: boolean;
  manualEngine: LocalEngineKind;
  hasApiKey: boolean;
}): LocalSetupBoard {
  const { result, isDetecting } = input;
  const card: SetupCardState = isDetecting
    ? 'detecting'
    : !result
      ? 'hidden'
      : result.generationVerified ? 'succeeded' : 'failed';
  const unrecognized = card === 'failed' && result?.unrecognized === true;
  const showsManualPicker = input.manualExpanded || unrecognized;
  // When manual selection is expanded the chosen engine wins; otherwise the engine recognized by this detection wins (used only to show or hide the key slot).
  const engine = showsManualPicker ? input.manualEngine : result?.engine;
  let summary: LocalSetupSummary | null = null;
  if (card === 'succeeded' && result?.engine) {
    const channel = result.channel ?? 'chat';
    // No default model slot: the sample = the first catalog item.
    const sample = result.modelIDs[0];
    const declared = result.models.find((model) => model.id === sample)?.engineDeclaration?.thinking;
    summary = {
      engine: localEngineDisplayName(result.engine),
      modelCount: result.modelIDs.length,
      channel: localChannelDisplayName(channel),
      contextLength: formatLocalContextLength(result.contextLength),
      thinking: localThinkingValueKey(result.engine, channel, declared),
    };
  }
  const slots: LocalSetupSlot[] = engine === 'openwebui' ? ['endpoint', 'apiKey'] : ['endpoint'];
  return {
    slots,
    card,
    summary,
    failure: card === 'failed' ? (unrecognized ? 'unrecognized' : 'connection') : null,
    showsManualPicker,
    showsChannelPicker: showsManualPicker && input.manualEngine === 'llamacpp',
    primaryButton: card === 'succeeded' ? 'connectAndSave' : 'detectConnectionSettings',
    isPrimaryEnabled: !isDetecting
      && input.endpointAccess === 'allowed'
      && !(engine === 'openwebui' && !input.hasApiKey),
    lanHttpBlocked: input.endpointAccess === 'lan_http_blocked',
  };
}
