import { type AttachmentLine, nativeFileModeOf } from '@oriveo/core/providers/attachment-transport';
import type { InputCapabilityDisabledReason } from '@oriveo/core/providers/capability-evidence-facade';
import type { ChatTemplateThinkingState } from './chat-template-thinking';
import { generationParameterSummary, type GenerationParameterRow } from './generation-parameter-rows';
import { modelControlFooterEntries, type ModelControlFooterEntry } from './model-control-capability-layout';
import {
  resolveModelOptionCapabilityCard,
  type ModelOptionCapability,
  type ModelOptionCapabilityInput,
  type ModelOptionCapabilityShape,
  type ModelOptionConnection,
  type ModelOptionLinkAction,
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
  vision: ModelOptionsVisionFacts;
  file: ModelOptionsFileFacts;
};

/** Facts of the image recognition card: visibility uses only the same entry function as the input box, and "unknown" uses only the same predicate as the negative-cache record decision. */
export type ModelOptionsVisionFacts = {
  /** The input box photo library entry is visible (`resolveAttachmentCapabilities(...).supportsImage`). */
  entryVisible: boolean;
  isRelayForm: boolean;
  /** The image recognition projection is not visible (unknown, same criterion for official and Relay); false when there is no projection (subscription). */
  noPositiveEvidence: boolean;
  /** The image recognition projection as is; absent when there is no projection (subscription / missing provider). */
  projection?: {
    visible: boolean;
    editable: boolean;
    disabledReason: InputCapabilityDisabledReason | null;
  };
};

/** Facts of the file card: the line comes from production `resolveAttachmentLine` (the Relay `file` negative cache is already folded into `nativeFilesSuppressed`). */
export type ModelOptionsFileFacts = {
  /** Missing = not resolved yet; `exact: false` = cannot be determined. Both are shown as "convert to text". */
  line?: AttachmentLine & { exact: boolean };
  nativeFileMimes: readonly string[];
  pdfNativeDefault: boolean;
};

export type ModelOptionsVisionState = 'hidden' | 'unknown' | 'available';
export type ModelOptionsFileState = 'text' | 'pdfNative' | 'nativeWhenSupported';

/** One card of the 2x2 capability area; `corner` is what to draw in the top-right corner, and `action` is where to go when the whole card is clickable. */
export type ModelOptionsTile =
  | {
    kind: 'capability';
    capability: ModelOptionCapability;
    row: ModelOptionsPanelRow;
    corner: 'switch' | 'levels' | 'chevron' | 'none';
    action?: ModelOptionLinkAction;
  }
  | {
    kind: 'vision';
    state: ModelOptionsVisionState;
    corner: 'check' | 'question' | 'x';
    /** Projection disable reason of the "unsupported" state (a disabled control must state its reason); absent for unknown / available / no reason. */
    disabledReason?: InputCapabilityDisabledReason;
  }
  | { kind: 'file'; state: ModelOptionsFileState; corner: 'check' };

/** "Actually sent this turn" lists only the choices that rewrite the request right now, with pinned web search first. */
export type ModelOptionsSummaryItem =
  | { kind: 'webOn' }
  | { kind: 'thinkingLevel'; intent: string }
  | { kind: 'thinkingOn' };

export type ModelOptionsTiles = {
  tiles: ModelOptionsTile[];
  summary: ModelOptionsSummaryItem[];
  /** First row of the parameters card; absent when the model has no temperature item. */
  temperature?: GenerationParameterRow;
  /** Chips of the parameters entry row (excluding temperature, which already has its own row). */
  parameters: ReturnType<typeof generationParameterSummary>;
};

export type ModelOptionsPanelModel = {
  mark?: ModelOptionsStatusMark;
  header: { connection: ModelOptionsHeaderConnection; transport?: ModelOptionsHeaderTransport };
  card: ModelOptionsPanelCard;
  showsReadOnlyBanner: boolean;
  tiles: ModelOptionsTile[];
  summary: ModelOptionsSummaryItem[];
  temperature?: GenerationParameterRow;
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
const TEMPERATURE = 'temperature';

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
  const { tiles, summary, temperature, parameters } = modelOptionsTiles({
    card: panelCard, vision: facts.vision, file: facts.file, generationRows: facts.generationRows,
  });
  return {
    ...(mark ? { mark } : {}),
    header: { connection: headerConnection(facts), ...(transport ? { transport } : {}) },
    card: panelCard,
    showsReadOnlyBanner: facts.hasReadOnlyReason && !hasControl,
    tiles,
    summary,
    ...(temperature ? { temperature } : {}),
    parameters,
    notes: { web: capabilityNotes(facts.notes.web), reasoning: capabilityNotes(facts.notes.reasoning) },
  };
}

/**
 * The 2x2 capability cards, summary bar and the temperature row of the parameters card. A whole card with an undecided protocol shows only a callout, without the four cards or the summary.
 */
export function modelOptionsTiles(input: {
  card: ModelOptionsPanelCard;
  vision: ModelOptionsVisionFacts;
  file: ModelOptionsFileFacts;
  generationRows: readonly GenerationParameterRow[];
}): ModelOptionsTiles {
  const temperature = input.generationRows.find((row) => row.id === TEMPERATURE);
  const parameters = generationParameterSummary(input.generationRows.filter((row) => row.id !== TEMPERATURE));
  const tail = { ...(temperature ? { temperature } : {}), parameters };
  if (input.card.kind === 'protocolUndecided') return { tiles: [], summary: [], ...tail };
  const vision = visionState(input.vision);
  const visionDisabledReason = vision === 'hidden' ? input.vision.projection?.disabledReason : null;
  return {
    tiles: [
      ...input.card.rows.map(capabilityTile),
      {
        kind: 'vision',
        state: vision,
        corner: vision === 'hidden' ? 'x' : vision === 'unknown' ? 'question' : 'check',
        ...(visionDisabledReason ? { disabledReason: visionDisabledReason } : {}),
      },
      // Files are always deliverable: in all three states the top right is a check mark.
      { kind: 'file', state: fileState(input.file), corner: 'check' },
    ],
    summary: summaryItems(input.card.rows),
    ...tail,
  };
}

function capabilityTile(row: ModelOptionsPanelRow): ModelOptionsTile {
  const base = { kind: 'capability' as const, capability: row.capability, row };
  switch (row.kind) {
    case 'toggle':
    case 'toggleWithTiming':
      return { ...base, corner: 'switch' };
    case 'tiers':
      return { ...base, corner: 'levels' };
    case 'notice':
    case 'disclosure':
    case 'chatTemplateBlocked':
    case 'protocolUndecided':
      // The whole card is clickable when the explanatory card has a way out.
      return row.link ? { ...base, corner: 'chevron', action: row.link } : { ...base, corner: 'none' };
  }
}

/** Three states of image recognition; model library rows and the model options image card share this one mapping. */
export function visionState(facts: ModelOptionsVisionFacts): ModelOptionsVisionState {
  if (!facts.entryVisible) return 'hidden';
  // unknown is not supported: official and Relay share one criterion, a projection that is not visible means "unconfirmed".
  return facts.noPositiveEvidence ? 'unknown' : 'available';
}

function fileState(facts: ModelOptionsFileFacts): ModelOptionsFileState {
  // When the line cannot be determined, no native block is sent either, so show it as "convert to text".
  if (!facts.line?.exact || nativeFileModeOf(facts.line) === 'off' || facts.nativeFileMimes.length === 0) return 'text';
  return facts.pdfNativeDefault ? 'pdfNative' : 'nativeWhenSupported';
}

function summaryItems(rows: readonly ModelOptionsPanelRow[]): ModelOptionsSummaryItem[] {
  const items: ModelOptionsSummaryItem[] = [];
  const web = rows.find((row) => row.capability === 'web');
  if (web && (web.kind === 'toggleWithTiming' || (web.kind === 'toggle' && web.isOn))) items.push({ kind: 'webOn' });
  const reasoning = rows.find((row) => row.capability === 'reasoning');
  if (reasoning?.kind === 'tiers' && reasoning.selection && reasoning.selection !== AUTOMATIC) {
    items.push({ kind: 'thinkingLevel', intent: reasoning.selection });
  } else if (reasoning?.kind === 'toggle' && reasoning.isOn) {
    items.push({ kind: 'thinkingOn' });
  }
  return items;
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
  // The relay web row only looks at the fragment and the local record; its control state (greyed out = unavailable) is not an official catalog entry, so it does not count as an official configuration.
  const webCatalogued = !facts.web.relayWeb && !UNCATALOGUED.has(facts.web.status);
  if (webCatalogued || !UNCATALOGUED.has(facts.reasoning.status)) return 'official';
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
