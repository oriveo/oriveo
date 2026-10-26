import type { AIModel, Provider, ReasoningMode, RelayModelTransport } from '@oriveo/shared';
import { localEngineChannelCandidates } from '@oriveo/shared';
import { decidedTransport, effectiveAPIRoot, effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { relayFirstSendTransport } from '../../../lib/core/providers/relay-first-send-transport';
import { isRelayNegativeCached } from '../../../lib/core/chat/relay-negative-cache';
import { relayNegativeCacheModelKey } from '../../../lib/core/chat/relay-rejection-loop';
import {
  RELAY_REASONING_LEVELS,
  relayAutomaticReasoningLevels,
} from '../../../lib/core/chat/capability-control-presentation';
import { canTestRelayModelCapabilities } from '../../../lib/core/relay-capability-test-ops';
import {
  relayWebModelOptionFacts,
  resolveRelayWebPresentation,
  type RelayWebStatusId,
} from '../../../lib/core/chat/relay-web-probe-records';
import { RELAY_WEB_STATUS_KEYS } from '../../../lib/core/chat/model-options-copy';
import { canRestoreAllRelayAutomatic, type RelayAdvancedCapabilityKey } from '../../../lib/core/relay-model-advanced-ops';
import { localChannelDisplayName, setupProtocolForTransport, type SetupProtocol } from '../relay/new/setup-board';
import { catalogCaps, enabledStatus, relayInputNegativeCached, type RelayCatalogCapState } from './relay-catalog-board';
import { relayInputOverrideValue } from '../../../lib/core/capability/capability-overrides';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../../lib/core/chat/stream-options';
import { bindRelayKey, relayEffectiveKeyID, relayKeyIDs, relayKeyRows, relayShowsKeyUI } from '@oriveo/shared/relay/relay-keys';
import { relayBindingFamily } from '../../../lib/core/provider-model-ops';
import { relayKeyTitle } from './relay-keys-board';

/**
 * "Model > Advanced" view state. The component renders only from what is produced here; the structure tests
 * (BOARD-ADVANCED-01 to 07) assert against this too. The automatic tri-state of vision / file / tools reuses the same judgments as the model library board.
 * Copy keys always carry a namespace and are resolved by the root translator.
 */

export const RELAY_ADVANCED_TEXT = {
  title: 'pages.relayDetail.advanced.title',
  restoreAll: 'pages.relayDetail.advanced.restoreAll',
  autoEquals: 'pages.relayDetail.advanced.autoEquals',
  autoEqualsConnectionDefault: 'pages.relayDetail.advanced.autoEqualsConnectionDefault',
  apiRoot: 'pages.relayDetail.advanced.apiRoot',
  capabilities: 'pages.relayDetail.advanced.capabilities',
  thinkingLevels: 'pages.relayDetail.advanced.thinkingLevels',
  channelHint: 'pages.relayDetail.advanced.channelHint',
  localOnly: 'pages.relayDetail.advanced.localOnly',
  appliesNow: 'pages.relayDetail.advanced.appliesNow',
  imageGenerationUnknown: 'pages.relayDetail.advanced.unknown',
  protocol: 'pages.relayDetail.sectionProtocol',
  channel: 'pages.relaySetup.localTileChannel',
  segmentAuto: 'pages.relayDetail.protocolAuto',
  capTitle: {
    image: 'common.modelOptionsVisionTitle',
    file: 'common.modelOptionsFilesTitle',
    imageGeneration: 'pages.relayDetail.advanced.imageGeneration',
    toolCall: 'pages.relayDetail.advanced.toolCalls',
    web: 'pages.relayDetail.capabilityTest.panel.itemWeb',
  },
  state: {
    supported: 'pages.relayDetail.capabilityTest.supported',
    unsupported: 'pages.relayDetail.capabilityTest.unsupported',
    unknown: 'common.modelOptionsVisionUnknown',
  },
  control: {
    auto: 'pages.relayDetail.protocolAuto',
    on: 'common.advancedStateOn',
    off: 'pages.chat.reasoning.off',
  },
  source: {
    catalog: 'pages.relayDetail.advanced.sourceCatalog',
    detected: 'pages.relayDetail.advanced.sourceDetected',
    tested: 'pages.relayDetail.advanced.sourceTested',
    engine: 'pages.relayDetail.advanced.sourceEngine',
    user: 'pages.relayDetail.catalogStatusSetByYou',
  },
  protocolStatus: {
    verified: 'pages.relayDetail.catalogStatusVerified',
    reachable: 'pages.relayDetail.catalogStatusReachable',
    setByYou: 'pages.relayDetail.catalogStatusSetByYou',
    unknownUntilSent: 'common.modelOptionsVisionUnknown',
    notReachable: 'pages.relayDetail.advanced.notReachable',
    testing: 'pages.relayDetail.testingRelay',
  },
  level: {
    automatic: 'pages.chat.reasoning.supplierDefault',
    fast: 'pages.chat.reasoning.fast',
    balanced: 'pages.chat.reasoning.balanced',
    deep: 'pages.chat.reasoning.deep',
    max: 'pages.chat.reasoning.max',
  },
} as const;

export const RELAY_ADVANCED_SEGMENTS = [
  'auto',
  'openai_chat_completions',
  'openai_responses',
  'anthropic_messages',
  'gemini_generate_content',
] as const;
export type RelayAdvancedSegment = typeof RELAY_ADVANCED_SEGMENTS[number];

/** Web search is listed after tool calling. */
export const RELAY_ADVANCED_CAPS: readonly RelayAdvancedCapabilityKey[] = ['image', 'file', 'imageGeneration', 'toolCall', 'web'];

export type RelayAdvancedSource = keyof typeof RELAY_ADVANCED_TEXT.source;
export type RelayAdvancedControl = keyof typeof RELAY_ADVANCED_TEXT.control;
export type RelayAdvancedProtocolStatus = keyof typeof RELAY_ADVANCED_TEXT.protocolStatus;

/** Single-protocol probe result held in this page's memory (belongs only to the protocol it was started for). */
export interface RelayAdvancedProbe {
  transport: RelayModelTransport;
  result: 'running' | 'reachable' | 'notReachable';
}

export type RelayAdvancedProtocolRow =
  | {
    kind: 'relay';
    selected: RelayAdvancedSegment;
    /** Note line 1: gives the protocol name only when Auto is selected (reads the first-launch protocol, ADVANCED-14b). */
    autoEquals: SetupProtocol | null;
    /** The connection protocol was chosen by the user and the model has none of its own: line 1 says "this connection's default protocol (X)", not read as a detection result. */
    autoEqualsConnectionDefault: boolean;
    status: RelayAdvancedProtocolStatus;
    /** Path of effectiveAPIRoot; empty is "/". */
    apiRoot: string;
  }
  | { kind: 'local'; channel: string; channelHint: boolean };

export interface RelayAdvancedCapabilityRow {
  cap: RelayAdvancedCapabilityKey;
  state: RelayCatalogCapState;
  stateKey: string;
  /** Only the web row has this: status id (web-probe.v1.json presentationCases advanced.statusId); absent for local engines / undecided protocols (shown as Unknown). */
  webStatusId?: RelayWebStatusId;
  source: RelayAdvancedSource | null;
  control: RelayAdvancedControl;
}

export interface RelayAdvancedThinkingCell {
  level: ReasoningMode;
  available: boolean;
  selected: boolean;
  /** Not tappable when outside the automatic set, or when it is the last selected cell. */
  canToggle: boolean;
}

export type RelayAdvancedThinking = { kind: 'levels'; cells: RelayAdvancedThinkingCell[] };

export interface RelayAdvancedKeyOption {
  id: string;
  /** Name or mask. */
  title: string;
  preview: string;
}

/** The "Key" section under the protocol section when there are >=2 keys. */
export interface RelayAdvancedKeySection {
  current: RelayAdvancedKeyOption;
  /** 'auto' when the current binding equals the rule result. */
  selected: 'auto' | string;
  /** Auto = the key recomputed by the section 4 rules after removing this model from the enabled ones. */
  autoKeyID: string;
  options: RelayAdvancedKeyOption[];
}

export interface RelayModelAdvancedBoard {
  header: { modelName: string; host: string };
  restoreAllEnabled: boolean;
  protocolRow: RelayAdvancedProtocolRow;
  capabilityRows: RelayAdvancedCapabilityRow[];
  /** null = no card (local engine connection, or the automatic set is empty, ADVANCED-15). */
  thinking: RelayAdvancedThinking | null;
  legend: RelayAdvancedSource[];
  testEntry: boolean;
  /** "Changes apply immediately" appears only in the writable state; read-only (entered from a catalog row) does not show it (ADVANCED-16). */
  footer: 'appliesNow' | null;
  /** Read-only Advanced opened from a catalog row: controls all disabled, no test capabilities, zero requests. */
  readOnly: boolean;
  /** null = no section (only 1 key). */
  keySection: RelayAdvancedKeySection | null;
}

export function relayModelAdvancedBoard(input: {
  provider: Provider;
  model: AIModel;
  /** Negative cache expiry is computed from this time. */
  now: number;
  probe?: RelayAdvancedProbe | null;
  readOnly?: boolean;
}): RelayModelAdvancedBoard {
  const { provider, model, now } = input;
  const readOnly = input.readOnly ?? false;
  const isLocal = Boolean(provider.relayRequested?.engineProfile);
  return {
    header: { modelName: model.name, host: hostOf(provider.baseURLText) },
    restoreAllEnabled: canRestoreAllRelayAutomatic(model),
    protocolRow: isLocal ? localChannelRow(provider, model) : relayProtocolRow(provider, model, input.probe ?? null),
    capabilityRows: capabilityRows(provider, model, now, isLocal),
    thinking: isLocal ? null : thinkingOf(provider, model),
    legend: isLocal ? ['engine', 'user'] : ['catalog', 'detected', 'tested', 'user'],
    testEntry: !readOnly && canTestRelayModelCapabilities(provider, model),
    footer: readOnly ? null : 'appliesNow',
    readOnly,
    keySection: keySectionOf(provider, model, readOnly),
  };
}

function keySectionOf(provider: Provider, model: AIModel, readOnly: boolean): RelayAdvancedKeySection | null {
  if (!relayShowsKeyUI(provider)) return null;
  const options = relayKeyRows(provider).map((row) => ({ id: row.id, title: relayKeyTitle(row), preview: row.preview }));
  const enabledWithoutSelf = provider.models.filter((item) => item.id !== model.id);
  const autoKeyID = bindRelayKey({
    keys: relayKeyIDs(provider),
    catalog: provider.catalogModels,
    enabled: enabledWithoutSelf,
    targetModelID: model.id,
    family: relayBindingFamily,
  }) ?? options[0]!.id;
  // Read-only (not enabled yet): shows the rule result, the menu rests on Auto.
  const boundKeyID = readOnly && !provider.models.some((item) => item.id === model.id)
    ? autoKeyID
    : relayEffectiveKeyID(provider, model.id);
  const current = options.find((option) => option.id === boundKeyID) ?? options[0]!;
  return {
    current,
    selected: current.id === autoKeyID ? 'auto' : current.id,
    autoKeyID,
    options,
  };
}

function hostOf(baseURL: string | undefined): string {
  try {
    return new URL(baseURL ?? '').hostname;
  } catch {
    return baseURL ?? '';
  }
}

function pathOf(root: string | undefined): string {
  if (!root) return '/';
  try {
    return new URL(root).pathname || '/';
  } catch {
    return '/';
  }
}

/** The model-level protocol source selects that segment only when it is user; values landed by reachable / observed count as automatic results. */
function relayProtocolRow(provider: Provider, model: AIModel, probe: RelayAdvancedProbe | null): RelayAdvancedProtocolRow {
  const userTransport = model.relayTransportSource === 'user' && isSegment(model.relayTransport) ? model.relayTransport : null;
  const selected: RelayAdvancedSegment = userTransport ?? 'auto';
  // A probe result is shown only when it belongs to the currently manually chosen protocol; switching protocol invalidates it.
  const probeStatus: RelayAdvancedProtocolStatus | null = probe && userTransport === probe.transport
    ? (probe.result === 'running' ? 'testing' : probe.result)
    : null;
  const own = model.relayTransport as string | undefined;
  const followsConnection = selected === 'auto' && (!own || own === 'auto') && decidedTransport(provider, null) !== undefined;
  return {
    kind: 'relay',
    selected,
    autoEquals: selected === 'auto' ? setupProtocolForTransport(relayFirstSendTransport(provider, model)) : null,
    autoEqualsConnectionDefault: followsConnection,
    status: probeStatus ?? transportStatus(provider, model),
    apiRoot: pathOf(effectiveAPIRoot(provider, model)),
  };
}

function isSegment(value: string | undefined): value is Exclude<RelayAdvancedSegment, 'auto'> {
  return value !== undefined && value !== 'auto' && (RELAY_ADVANCED_SEGMENTS as readonly string[]).includes(value);
}

/** Same judgment as the enabled rows of the model library (following the selected connection also counts as "user-set"); it can only yield these four. */
function transportStatus(provider: Provider, model: AIModel): RelayAdvancedProtocolStatus {
  const status = enabledStatus(model, provider);
  return status === 'verified' || status === 'reachable' || status === 'setByYou' ? status : 'unknownUntilSent';
}

/** Local engine: the channel is connection-level and read-only; the footnote appears only when the engine has more than one channel. */
function localChannelRow(provider: Provider, model: AIModel): RelayAdvancedProtocolRow {
  const transport = effectiveTransport(provider, model);
  return {
    kind: 'local',
    channel: localChannelDisplayName(transport === 'llamacpp_native' ? 'native' : 'chat'),
    channelHint: localEngineChannelCandidates(provider.relayRequested?.engineProfile).showsSelector,
  };
}

function capabilityRows(provider: Provider, model: AIModel, now: number, isLocal: boolean): RelayAdvancedCapabilityRow[] {
  const auto = Object.fromEntries(catalogCaps(provider, model, now).map((cap) => [cap.cap, cap.state]));
  const overrides = model.relayCapabilityOverrides;
  const generationOverride = overrides?.imageGeneration?.value;
  // The existing judgments for vision and tools already read the override; file and image generation look at the override value first, then fall back to automatic.
  const states: Record<RelayAdvancedCapabilityKey, RelayCatalogCapState> = {
    image: auto.image as RelayCatalogCapState,
    file: auto.file as RelayCatalogCapState,
    imageGeneration: typeof generationOverride === 'boolean'
      ? (generationOverride ? 'supported' : 'unsupported')
      : ((model.capabilities ?? []).includes('imageGeneration') ? 'supported' : 'unknown'),
    toolCall: auto.tool as RelayCatalogCapState,
    web: 'unknown',
  };
  return RELAY_ADVANCED_CAPS.map((cap) => {
    if (cap === 'web') return webRow(provider, model, isLocal);
    const state = states[cap];
    const value = overrideOf(model, cap)?.value;
    return {
      cap,
      state,
      // Image generation has no remember-after-sending mechanism; unknown does not use "remembered after sending".
      stateKey: cap === 'imageGeneration' && state === 'unknown'
        ? RELAY_ADVANCED_TEXT.imageGenerationUnknown
        : RELAY_ADVANCED_TEXT.state[state],
      source: sourceOf(provider, model, cap, state, now, isLocal),
      control: typeof value === 'boolean' ? (value ? 'on' : 'off') : 'auto',
    };
  });
}

/**
 * Web row (fixture web-probe.v1.json presentationCases advanced): the status only looks at records valid for the effective fragment,
 * source user (override) > tested (current record searched / rejected) > none; local engine / undecided protocol -> Unknown (the source only accepts user).
 */
function webRow(provider: Provider, model: AIModel, isLocal: boolean): RelayAdvancedCapabilityRow {
  const value = model.relayCapabilityOverrides?.web?.value;
  const userSet = model.relayCapabilityOverrides?.web?.source === 'user' && typeof value === 'boolean';
  // Same convention as the other capability rows on the card: override true -> On, false -> Off (tested and user both count), no value -> Auto; choosing Auto clears the override.
  const control: RelayAdvancedControl = typeof value === 'boolean' ? (value ? 'on' : 'off') : 'auto';
  if (isLocal || decidedTransport(provider, model) === undefined) {
    return {
      cap: 'web', state: 'unknown', stateKey: RELAY_ADVANCED_TEXT.imageGenerationUnknown,
      source: userSet ? 'user' : null, control,
    };
  }
  const presentation = resolveRelayWebPresentation(relayWebModelOptionFacts(provider, model), null);
  const { statusId, source } = presentation.advanced;
  return {
    cap: 'web',
    state: statusId === 'web_probe_searched' ? 'supported' : statusId === 'web_probe_rejected' ? 'unsupported' : 'unknown',
    stateKey: RELAY_WEB_STATUS_KEYS[statusId],
    webStatusId: statusId,
    source,
    control,
  };
}

/**
 * The source takes the first hit in a fixed order: user > tested > engine declaration (only with engineProfile) >
 * unexpired negative cache -> Detected > model capability (official catalog inheritance) -> Official catalog > none.
 * A local connection can only show engine declaration and manual setting (the legend is consistent); it does not push down to the catalog / negative cache.
 */
function sourceOf(
  provider: Provider,
  model: AIModel,
  cap: Exclude<RelayAdvancedCapabilityKey, 'web'>,
  state: RelayCatalogCapState,
  now: number,
  isLocal: boolean,
): RelayAdvancedSource | null {
  const override = overrideOf(model, cap);
  // Source and status share the same evidence: if the override did not land on the status (e.g. vision / tools without an evidence identity do not read overrides) it cannot carry an override source.
  const overrideState = typeof override?.value === 'boolean' ? (override.value ? 'supported' : 'unsupported') : null;
  if (override && (overrideState === null || overrideState === state)) return override.source === 'user' ? 'user' : 'tested';
  if (cap === 'image' || cap === 'file') {
    // Vision / file read the input negative cache v2 (same key as the projection and send side); local connections follow the same order, and the negative cache beats tested and the engine declaration.
    const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    if (relayInputNegativeCached(provider, model, streamOptions, cap === 'image' ? 'vision_input' : 'file_input', now)) return 'detected';
  }
  if (isLocal) {
    const declared = cap === 'image' || cap === 'toolCall' ? model.engineDeclaration?.[cap] : undefined;
    return typeof declared === 'boolean' ? 'engine' : null;
  }
  // Tool reads v1 (vision / file only honor the v2 above).
  if (cap === 'toolCall') {
    const key = relayNegativeCacheModelKey(provider, model);
    if (key && isRelayNegativeCached({ ...key, kind: cap }, now)) return 'detected';
  }
  return state === 'supported' ? 'catalog' : null;
}

/** Overrides after normalizing vision / file reads (user delta > legacy tested field); other keys read the legacy field. */
function overrideOf(
  model: AIModel,
  cap: Exclude<RelayAdvancedCapabilityKey, 'web'>,
): { value: unknown; source: 'user' | 'tested' } | undefined {
  if (cap === 'image') return relayInputOverrideValue(model, 'vision_input');
  if (cap === 'file') return relayInputOverrideValue(model, 'file_input');
  return model.relayCapabilityOverrides?.[cap];
}

/** The automatic set is resolved the same way as the thinking card in the model options panel; the override only narrows; if the set is empty the whole card is hidden. */
function thinkingOf(provider: Provider, model: AIModel): RelayAdvancedThinking | null {
  const automatic = relayAutomaticReasoningLevels(provider, model);
  if (automatic.length === 0) return null;
  const override = model.relayCapabilityOverrides?.reasoningLevels?.value;
  const narrowed = override ? automatic.filter((level) => override.includes(level)) : automatic;
  const selected = new Set(narrowed.length > 0 ? narrowed : automatic);
  return {
    kind: 'levels',
    cells: RELAY_REASONING_LEVELS.map((level) => {
      const available = automatic.includes(level);
      const isSelected = selected.has(level);
      return { level, available, selected: isSelected, canToggle: available && !(isSelected && selected.size === 1) };
    }),
  };
}
