import type { ChatTemplateThinkingState } from './chat-template-thinking';
import { generationParameterSummary, type GenerationParameterRow } from './generation-parameter-rows';
import { modelControlFooterEntries, type ModelControlFooterEntry } from './model-control-capability-layout';
import {
  resolveModelOptionCapabilityCard,
  type ModelOptionCapability,
  type ModelOptionCapabilityInput,
  type ModelOptionCapabilityShape,
  type ModelOptionConnection,
} from './model-option-capability-shape';

/**
 * Panel model of the main "Model options" pane: the two header rows, capability card row order and exceptions, parameter card pills, and the note strip under a card.
 *
 * The UI only draws what this module returns; the caller gathers every fact from the production store / presentation functions and passes it in, so nothing here reads storage.
 */

export type ModelOptionsStatusMark = 'official' | 'unverified';

export type ModelOptionsHeaderConnection = { kind: 'engine'; name: string } | { kind: 'connection'; name: string };
export type ModelOptionsHeaderTransport = { kind: 'local' } | { kind: 'protocol'; label: string };

/** The note card the thinking row turns into when the chat template switch is blocked by the additional request body. */
export type ModelOptionsChatTemplateBlockedRow = {
  kind: 'chatTemplateBlocked';
  capability: 'reasoning';
  state: 'blocked' | 'notSending';
  link: 'openAdditionalRequestBody';
};

export type ModelOptionsPanelRow = ModelOptionCapabilityShape | ModelOptionsChatTemplateBlockedRow;

export type ModelOptionsPanelCard =
  | { kind: 'protocolUndecided'; link: 'openConnectionProtocol' }
  | { kind: 'rows'; rows: ModelOptionsPanelRow[] };

export type ModelOptionsCapabilityNoteFacts = {
  /** This capability's custom fields are really rewriting the request right now. */
  overridden: boolean;
  riskTiers: readonly string[];
  upstreamRejected: boolean;
};

export type ModelOptionsPanelFacts = {
  connection: ModelOptionConnection;
  connectionName: string;
  engineProfile?: string;
  apiBaseURL?: string;
  /** Protocol name (the result of `modelControlTransportLabel`); the second segment is omitted when unavailable. */
  transportLabel?: string;
  web: ModelOptionCapabilityInput;
  reasoning: ModelOptionCapabilityInput;
  chatTemplateState: ChatTemplateThinkingState;
  /** Another model on this connection can adjust this item (the "see which models can adjust this" destination is not an empty list). */
  hasAlternativeModels: Readonly<Record<ModelOptionCapability, boolean>>;
  /** The whole panel is read-only for some reason (sending / identity not ready). */
  hasReadOnlyReason: boolean;
  generationRows: readonly GenerationParameterRow[];
  notes: Readonly<Record<ModelOptionCapability, ModelOptionsCapabilityNoteFacts>>;
};

export type ModelOptionsPanelModel = {
  mark?: ModelOptionsStatusMark;
  header: { connection: ModelOptionsHeaderConnection; transport?: ModelOptionsHeaderTransport };
  card: ModelOptionsPanelCard;
  showsReadOnlyBanner: boolean;
  parameters: ReturnType<typeof generationParameterSummary>;
  notes: Record<ModelOptionCapability, ModelControlFooterEntry[]>;
};

/** Product names of local engines; proper nouns are not translated. */
const ENGINE_NAMES: Readonly<Record<string, string>> = {
  llamacpp: 'llama.cpp', ollama: 'Ollama', lmstudio: 'LM Studio', vllm: 'vLLM', openwebui: 'Open WebUI',
};
const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);
const UNCATALOGUED = new Set(['pending', 'unknown']);
const SUPPORTED_MODELS: 'openSupportedModels' = 'openSupportedModels';
const AUTOMATIC = 'automatic';

export function modelOptionsPanelModel(facts: ModelOptionsPanelFacts): ModelOptionsPanelModel {
  const card = resolveModelOptionCapabilityCard({ web: facts.web, reasoning: facts.reasoning });
  const panelCard: ModelOptionsPanelCard = card.kind === 'protocolUndecided'
    ? card
    : {
      kind: 'rows',
      rows: orderedRows(
        withoutEmptyOutlet(card.web, facts.hasAlternativeModels.web),
        withoutEmptyOutlet(chatTemplateRow(card.reasoning, facts.chatTemplateState), facts.hasAlternativeModels.reasoning),
      ),
    };
  const hasControl = panelCard.kind === 'rows'
    && panelCard.rows.some((row) => row.kind === 'toggle' || row.kind === 'tiers' || row.kind === 'toggleWithTiming');
  const mark = statusMark(facts);
  const transport = headerTransport(facts);
  return {
    ...(mark ? { mark } : {}),
    header: { connection: headerConnection(facts), ...(transport ? { transport } : {}) },
    card: panelCard,
    showsReadOnlyBanner: facts.hasReadOnlyReason && !hasControl,
    parameters: generationParameterSummary(facts.generationRows),
    notes: { web: capabilityNotes(facts.notes.web), reasoning: capabilityNotes(facts.notes.reasoning) },
  };
}

/**
 * New selection after tapping a segment; `undefined` = back to never selected.
 * With an "automatic" slot, automatic is the "never selected" state; without one, tapping the already selected tier again returns to never selected.
 */
export function reasoningTierAfterTap(options: readonly string[], current: string | undefined, tapped: string): string | undefined {
  if (tapped === AUTOMATIC) return undefined;
  if (!options.includes(AUTOMATIC) && tapped === current) return undefined;
  return tapped;
}

function statusMark(facts: ModelOptionsPanelFacts): ModelOptionsStatusMark | undefined {
  if (!UNCATALOGUED.has(facts.web.status) || !UNCATALOGUED.has(facts.reasoning.status)) return 'official';
  return facts.connection === 'custom' ? 'unverified' : undefined;
}

function headerConnection(facts: ModelOptionsPanelFacts): ModelOptionsHeaderConnection {
  const engine = facts.engineProfile ? ENGINE_NAMES[facts.engineProfile] : undefined;
  return engine ? { kind: 'engine', name: engine } : { kind: 'connection', name: facts.connectionName };
}

function headerTransport(facts: ModelOptionsPanelFacts): ModelOptionsHeaderTransport | undefined {
  if (isLoopback(facts.apiBaseURL)) return { kind: 'local' };
  return facts.transportLabel ? { kind: 'protocol', label: facts.transportLabel } : undefined;
}

function isLoopback(raw: string | undefined): boolean {
  const text = raw?.trim();
  if (!text) return false;
  try {
    const url = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(text) ? text : `http://${text}`);
    return LOOPBACK_HOSTS.has(url.hostname.toLowerCase());
  } catch {
    return false;
  }
}

/** When the chat template switch is blocked by the additional request body the switch cannot be toggled and is replaced by a note card. */
function chatTemplateRow(row: ModelOptionCapabilityShape, state: ChatTemplateThinkingState): ModelOptionsPanelRow {
  if (row.kind !== 'toggle' || row.target.kind !== 'chatTemplateThinking') return row;
  if (state !== 'blocked' && state !== 'notSending') return row;
  return { kind: 'chatTemplateBlocked', capability: 'reasoning', state, link: 'openAdditionalRequestBody' };
}

/** When the destination would be an empty list the exit is not offered: the note card drops its link and the read-only row becomes non-tappable. */
function withoutEmptyOutlet(row: ModelOptionsPanelRow, hasAlternatives: boolean): ModelOptionsPanelRow {
  if (hasAlternatives || !('link' in row) || row.link !== SUPPORTED_MODELS) return row;
  const { link: _link, ...rest } = row;
  return rest as ModelOptionsPanelRow;
}

/** Web search goes first; the one exception: when the thinking row is the chat template switch (or its blocked note card) it goes first. */
function orderedRows(web: ModelOptionsPanelRow, reasoning: ModelOptionsPanelRow): ModelOptionsPanelRow[] {
  const templateFirst = reasoning.kind === 'chatTemplateBlocked'
    || (reasoning.kind === 'toggle' && reasoning.target.kind === 'chatTemplateThinking');
  return templateFirst ? [reasoning, web] : [web, reasoning];
}

/** Note strip under a card: keeps the criterion of the original panel card (`modelControlFooterEntries`); the exit is already given by the row itself. */
function capabilityNotes(notes: ModelOptionsCapabilityNoteFacts): ModelControlFooterEntry[] {
  return modelControlFooterEntries({
    context: 'panelCard',
    overridden: notes.overridden,
    upstreamRejected: notes.upstreamRejected,
    riskTiers: notes.riskTiers,
    showsAdvancedSettingsAction: notes.overridden,
  });
}
