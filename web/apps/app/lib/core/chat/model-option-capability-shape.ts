import type { AIModel, Provider, RelayRequestedConfig } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { resolveModelCapabilityEvidence } from './capability-evidence';
import { providerFormOf } from '../capability/truth/provider-form';
import { capabilityRejectionIsDormant, nearestAcceptedReasoningTier, type CapabilityRecoveryIdentity } from './capability-recovery-runtime';
import type { CapabilityControlPresentation } from './capability-control-presentation';
import { resolveModelControlStatus, type ModelControlStatus } from './model-control-capability-layout';
import { resolveRelayWebPresentation, type RelayWebFacts, type RelayWebStatusId } from './relay-web-probe-records';
import {
  resolveWebSearchState,
  type OneTapTarget,
  type RecipeWebState,
  type RelayWebStatus,
  type ToolCallSupport,
  type WebRouteAction,
  type WebRouteForm,
  type WebSearchCardActionText,
  type WebSearchCardText,
  type WebSearchFacts,
  type WebSearchPath,
  type WebSearchState,
} from '@oriveo/core/search/search-route';
import type { SearchServiceStatus } from '@oriveo/core/search/search-settings';

/**
 * What shape each row of the "Model options" capability card (web search / thinking) takes.
 *
 * Looks only at the control state, the declared tiers, writability, and the connection class; it never
 * reads the store and never branches on provider or model name. Copy slots are always semantic enums
 * that the copy layer maps to message keys later, so what is decided here is which sentence is chosen.
 */

export type ModelOptionCapability = 'web' | 'reasoning';
export type ModelOptionConnection = 'official' | 'custom';
export type ModelOptionLinkAction =
  | 'openSupportedModels'
  | 'openAdditionalRequestBody'
  | 'openConnectionProtocol'
  | 'switchConnection'
  /** Web search settings page of a Relay connection. */
  | 'openConnectionWebSearch'
  /** The relay model's "Advanced" page (where capability tests live): the retest exit after the template is rejected. */
  | 'testCapabilities'
  /** Web card "Search method" sheet. */
  | 'pickSearchSource'
  /** One-tap enable: the connect page prefills with the reused connection. */
  | 'oneTapEnableSearch'
  /** Settings add-search-service flow. */
  | 'addSearchService';

export type ModelOptionCapabilityInput = {
  capability: ModelOptionCapability;
  status: ModelControlStatus;
  availableIntents: readonly string[];
  selectedIntent?: string;
  connection: ModelOptionConnection;
  isWritable: boolean;
  protocolUndecided: boolean;
  rejectedIntents: readonly string[];
  chatTemplateThinkingIsOn: boolean;
  supportsChatTemplate: boolean;
  /** Facts of a local-engine connection (one with an engineProfile); when present, the thinking row follows the write-path table, not the protocol. */
  localEngine?: ModelOptionLocalEngine;
  /**
   * The model shows its thinking process when answering (facade truth, see `modelOptionShowsThinking`); read by the fixed read-only
   * row for a model that thinks but has nothing selectable.
   */
  showsThinking?: boolean;
  /**
   * Relay-form web search facts: when present, the web row is a chat switch (selectedIntent = the chat web
   * preference already resolved through the default layer), shaped by the fixture presentationCases, not by the verdict state.
   */
  relayWeb?: ModelOptionRelayWeb;
  /**
   * Local external search service context: only meaningful for the web row. Omitted = no external search; the shape is the same as before.
   */
  externalSearch?: ModelOptionExternalSearch;
};

export type ModelOptionRelayWeb = RelayWebFacts;

/** Local facts the web card needs for external search services (handed as-is to `resolveWebSearchState`; no decisions are made here). */
export type ModelOptionExternalSearch = {
  /** Connection form (`webSearchRouteForm(provider)`). */
  form: WebRouteForm;
  /** `<connection id>:<model id>`. */
  modelKey: string;
  currentProviderKind: string | null;
  /** Local services (storage order); names already passed through searchServiceDisplayName, status is searchServiceRowState.status. */
  services: ReadonlyArray<{ id: string; name: string; status: SearchServiceStatus }>;
  defaultServiceId: string | null;
  /** Value of conversationSource (new conversation = the in-memory value). */
  stored: unknown;
  /** "One-tap enable" target (`oneTapReuseTarget`) and that service's display name. */
  oneTap: { target: OneTapTarget; serviceName: string } | null;
  /** Tri-state of catalog tool calls (`tool_call` evidence). */
  toolCall: ToolCallSupport;
  /** Native web search was rejected (`webSearchNativeRejected`). */
  nativeRejected?: boolean;
  /** Whether a session-level preference can be written for this conversation (`composerWebPreferenceWritable`, defined identically on all three clients). */
  panelWritable: boolean;
};

/** Semantic copy for the external-search part of the web card (non-existing output of `webSearchCardPresentation`, excluding the toggle). */
export type ModelOptionSearchCard = {
  status: WebSearchCardText | null;
  /** Explanations under the status row, all shown in order (they replace the previous body text, not stacked). */
  notes: WebSearchCardText[];
  link: WebSearchCardActionText | null;
  cta: WebSearchCardActionText | null;
  secondary: WebSearchCardActionText | null;
};

/** Connection-level channel + model-level thinking declaration. */
export type ModelOptionLocalEngine = {
  engineProfile: NonNullable<RelayRequestedConfig['engineProfile']>;
  channel: 'chat' | 'native';
  declaredThinking?: boolean;
};

/** Where a toggle writes: the capability preference (one intent each for on and off), or the chat-template thinking switch in the additional request body. */
export type ModelOptionToggleTarget =
  | { kind: 'capabilityPreference'; on: string; off: 'off' }
  | { kind: 'chatTemplateThinking' };

export type ModelOptionCaption = 'searchesTheWeb' | 'thinksFirst' | 'chatTemplateThinking';

export type ModelOptionTierTrailing =
  | { kind: 'rejected'; intent: string }
  | { kind: 'tierNote'; intent: string }
  | { kind: 'modelDefault' }
  | { kind: 'alwaysThinks' };

export type ModelOptionTierFootnote =
  | { kind: 'rejectedFallback'; rejected: string; fallback: string }
  | { kind: 'tierNote'; intent: string }
  | { kind: 'costNote' };

export type ModelOptionNoticeStatus =
  | 'alwaysThinks' | 'needsOwnConfiguration' | 'modelDefault' | 'temporarilyUnavailable' | 'alwaysOn';

export type ModelOptionNoticeBody =
  | { kind: 'fixedTier'; intent?: string }
  | { kind: 'customOnly'; capability: ModelOptionCapability }
  | { kind: 'notCatalogued'; capability: ModelOptionCapability }
  /** Web search the subscription upstream keeps always on: the user cannot turn it off. */
  | { kind: 'subscriptionAlwaysSearches' };

export type ModelOptionReadOnlyValue =
  | { kind: 'webPreference'; preference: 'off' | 'automatic' | 'force' }
  | { kind: 'reasoningTier'; intent: string }
  | { kind: 'modelDefault' }
  | { kind: 'chatTemplateThinking'; isOn: boolean };

export type ModelOptionDisclosureStatus =
  | { kind: 'cannotDoOnThisConnection' }
  /** The catalog reports the capability as fixed for this model, so the client sends nothing for it. */
  | { kind: 'fixedByConnection' }
  /** Web search: "this model cannot search the web"; thinking: "this model has no thinking mode". */
  | { kind: 'modelLacksCapability' }
  /** The model shows its thinking but exposes no adjustable level. */
  | { kind: 'showsThinkingFixed' }
  | { kind: 'currentValue'; value: ModelOptionReadOnlyValue };

export type ModelOptionCapabilityShape =
  | {
    kind: 'toggle';
    capability: ModelOptionCapability;
    isOn: boolean;
    target: ModelOptionToggleTarget;
    caption?: ModelOptionCaption;
    link?: ModelOptionLinkAction;
    /** Greyed out (relay web search overridden off by the user). */
    disabled?: boolean;
    /** Status row of relay web search (replaces the caption). */
    relayStatus?: RelayWebStatusId;
    /** Action added to the web row when there is no external service (see `ModelOptionSearchCard`). */
    searchCard?: ModelOptionSearchCard;
  }
  | {
    kind: 'toggleWithTiming';
    capability: 'web';
    isOn: true;
    target: ModelOptionToggleTarget;
    timing: { options: readonly ['automatic', 'force']; selection: 'automatic' | 'force' };
    searchCard?: ModelOptionSearchCard;
  }
  | {
    /** Web toggle + source sub-row (`toggle_with_source_picker` / `toggle_external` / `toggle_external_presearch_notice`). */
    kind: 'toggleWithSource';
    capability: 'web';
    isOn: boolean;
    target: ModelOptionToggleTarget;
    /** Native row kept when the model can search natively (status copy and timing segments follow it); omitted when it cannot. */
    native?: Extract<ModelOptionCapabilityShape, { kind: 'toggle' | 'toggleWithTiming' }>;
    card: ModelOptionSearchCard;
    /** This turn's web path (`resolveWebSearchState().route.path`). */
    path: WebSearchPath;
    /** This turn goes external: native / relay web fields are stripped from the request. */
    nativeFieldsSuppressed: boolean;
    /** external: on = pick_service (serviceId), off = disarm, neither writes session web search; conversation_web: writes session web search. */
    controls: 'external' | 'conversation_web';
    /** Current service (`resolveWebSearchState().source.serviceId`). */
    serviceId: string | null;
  }
  | {
    kind: 'tiers';
    capability: 'reasoning';
    includesOff: boolean;
    options: string[];
    selection?: string;
    trailing: ModelOptionTierTrailing;
    footnotes: ModelOptionTierFootnote[];
    rejected: string[];
  }
  | {
    kind: 'notice';
    capability: ModelOptionCapability;
    status: ModelOptionNoticeStatus;
    body: ModelOptionNoticeBody;
    link?: ModelOptionLinkAction;
    searchCard?: ModelOptionSearchCard;
  }
  | {
    kind: 'disclosure';
    capability: ModelOptionCapability;
    status: ModelOptionDisclosureStatus;
    link?: ModelOptionLinkAction;
    searchCard?: ModelOptionSearchCard;
  }
  | { kind: 'protocolUndecided'; capability: ModelOptionCapability; link: 'openConnectionProtocol' };

export type ModelOptionCapabilityCard =
  | { kind: 'protocolUndecided'; link: 'openConnectionProtocol' }
  | {
    kind: 'rows';
    web: ModelOptionCapabilityShape;
    reasoning: ModelOptionCapabilityShape;
  };

const AUTOMATIC = 'automatic';
const REASONING_TIER_ORDER = ['off', 'low', 'balanced', 'deep', 'max'] as const;

export function resolveModelOptionCapabilityShape(input: ModelOptionCapabilityInput): ModelOptionCapabilityShape {
  const base = resolveBaseCapabilityShape(input);
  if (input.capability !== 'web' || !input.externalSearch) return base;
  return withExternalSearch(input, base);
}

function resolveBaseCapabilityShape(input: ModelOptionCapabilityInput): ModelOptionCapabilityShape {
  const { capability, status } = input;
  if (status === 'fixedByConnection') {
    return { kind: 'disclosure', capability, status: { kind: 'fixedByConnection' } };
  }
  if (capability === 'web' && input.relayWeb) return relayWebShape(input, input.relayWeb);
  if (input.protocolUndecided) return { kind: 'protocolUndecided', capability, link: 'openConnectionProtocol' };
  if (capability === 'reasoning' && input.localEngine) {
    const engineShape = localEngineReasoningShape(input, input.localEngine);
    if (engineShape) return engineShape;
  }
  switch (status) {
    case 'automaticAvailable':
    case 'forceUnsupported':
      if (!input.isWritable) return { kind: 'disclosure', capability, status: { kind: 'currentValue', value: readOnlyValue(input) } };
      return capability === 'web' ? webShape(input) : reasoningShape(input);
    case 'alwaysOn':
      // Read-only and not clickable (no link). The presentation class comes only from the web reasonCode; thinking that receives it draws the current value, as for read-only.
      if (capability !== 'web') return { kind: 'disclosure', capability, status: { kind: 'currentValue', value: readOnlyValue(input) } };
      return { kind: 'notice', capability: 'web', status: 'alwaysOn', body: { kind: 'subscriptionAlwaysSearches' } };
    case 'customOnly':
      return customOnlyNotice(capability);
    case 'unsupported':
    case 'externalConnectorOnly':
      if (capability === 'web' && input.connection === 'custom') return connectionCannot();
      return { kind: 'disclosure', capability, status: { kind: 'modelLacksCapability' }, link: 'openSupportedModels' };
    case 'pending':
    case 'unknown':
      if (input.connection === 'custom') {
        if (capability === 'web') return connectionCannot();
        if (input.supportsChatTemplate) return chatTemplateShape(input);
        return input.showsThinking ? showsThinkingFixed() : customOnlyNotice('reasoning');
      }
      // The model thinks but has no selectable level: a fixed read-only row, not "not catalogued".
      if (capability === 'reasoning' && input.showsThinking) return showsThinkingFixed();
      return {
        kind: 'notice', capability,
        status: capability === 'reasoning' ? 'modelDefault' : 'temporarilyUnavailable',
        body: { kind: 'notCatalogued', capability }, link: 'openSupportedModels',
      };
  }
}

/**
 * Whether the model shows its thinking: read only from the facade `reasoning/thinking` (each form's adapter produces it from that form's source; a missing source = not shown).
 */
export function modelOptionShowsThinking(
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
): boolean {
  if (!provider || !model) return false;
  return resolveModelCapabilityEvidence({ key: 'reasoning/thinking', provider, model }).support === 'supported';
}

function showsThinkingFixed(): ModelOptionCapabilityShape {
  return { kind: 'disclosure', capability: 'reasoning', status: { kind: 'showsThinkingFixed' } };
}

/** Connection class: a relay is a custom connection, everything else counts as official. */
export function modelOptionConnection(provider: Pick<Provider, 'kind'> | null | undefined): ModelOptionConnection {
  return provider?.kind === 'relay' ? 'custom' : 'official';
}

/**
 * Control facts of the thinking row (same source as the model options panel): control state -> status, declared levels, facade "shows thinking".
 */
export function modelOptionReasoningFacts(
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
  control: Pick<CapabilityControlPresentation, 'state' | 'availableIntents' | 'reasonCode'>,
): Pick<ModelOptionCapabilityInput, 'status' | 'availableIntents' | 'showsThinking'> {
  return {
    status: resolveModelControlStatus(control),
    availableIntents: control.availableIntents,
    showsThinking: modelOptionShowsThinking(provider, model),
  };
}

/**
 * Write-path table (fixture thinking.writePaths): only the llama.cpp Chat channel can write the chat-template thinking switch.
 * Engines / channels outside the table return undefined, handing back to the existing Relay rules.
 */
const LOCAL_ENGINE_THINKING_WRITABLE: Readonly<Record<string, Partial<Record<ModelOptionLocalEngine['channel'], boolean>>>> = {
  llamacpp: { chat: true, native: false },
  ollama: { chat: false },
  lmstudio: { chat: false },
  vllm: { chat: false },
  openwebui: { chat: false },
};

function localEngineReasoningShape(
  input: ModelOptionCapabilityInput,
  engine: ModelOptionLocalEngine,
): ModelOptionCapabilityShape | undefined {
  const writable = LOCAL_ENGINE_THINKING_WRITABLE[engine.engineProfile]?.[engine.channel];
  if (writable === undefined) return undefined;
  if (writable) return chatTemplateShape(input);
  // The llama.cpp native channel keeps today's "not Chat" explanation.
  if (engine.channel !== 'chat') return customOnlyNotice('reasoning');
  if (engine.declaredThinking === false) {
    return { kind: 'disclosure', capability: 'reasoning', status: { kind: 'modelLacksCapability' }, link: 'openSupportedModels' };
  }
  return {
    kind: 'notice', capability: 'reasoning', status: 'modelDefault',
    body: { kind: 'notCatalogued', capability: 'reasoning' }, link: 'openSupportedModels',
  };
}

/** Takes the local-engine facts from the connection and model; returns nothing when there is no engineProfile or the channel is not chat / native (behavior unchanged). */
export function modelOptionLocalEngine(
  provider: Pick<Provider, 'baseURLText' | 'relayRequested'>,
  model: Pick<AIModel, 'engineDeclaration' | 'relayTransport'> | null | undefined,
): ModelOptionLocalEngine | undefined {
  const engineProfile = provider.relayRequested?.engineProfile;
  if (!engineProfile) return undefined;
  const transport = effectiveTransport(provider, model);
  const channel = transport === 'llamacpp_native' ? 'native' : transport === 'openai_chat_completions' ? 'chat' : undefined;
  if (!channel) return undefined;
  const declaredThinking = model?.engineDeclaration?.thinking;
  return { engineProfile, channel, ...(typeof declaredThinking === 'boolean' ? { declaredThinking } : {}) };
}

/**
 * Relay web search row (fixtures web-fragment.v1.json + web-probe.v1.json presentationCases): local engine -> this connection cannot do it;
 * protocol undecided -> choose a protocol first; otherwise it is a chat switch: tappable (toggle) or greyed out (toggleDisabled + retest exit), with the status row following statusId.
 */
function relayWebShape(input: ModelOptionCapabilityInput, relayWeb: ModelOptionRelayWeb): ModelOptionCapabilityShape {
  if (relayWeb.localEngine) return connectionCannot();
  if (input.protocolUndecided) return { kind: 'protocolUndecided', capability: 'web', link: 'openConnectionProtocol' };
  const selected = input.selectedIntent === AUTOMATIC || input.selectedIntent === 'force' || input.selectedIntent === 'off'
    ? input.selectedIntent
    : null;
  const presentation = resolveRelayWebPresentation(relayWeb, selected);
  return {
    kind: 'toggle',
    capability: 'web',
    isOn: presentation.isOn,
    target: { kind: 'capabilityPreference', on: AUTOMATIC, off: 'off' },
    relayStatus: presentation.statusId,
    ...(presentation.row === 'toggleDisabled' ? { disabled: true } : {}),
    ...(presentation.retestLink ? { link: presentation.retestLink } : {}),
  };
}

function connectionCannot(): ModelOptionCapabilityShape {
  return { kind: 'disclosure', capability: 'web', status: { kind: 'cannotDoOnThisConnection' }, link: 'switchConnection' };
}

function customOnlyNotice(capability: ModelOptionCapability): ModelOptionCapabilityShape {
  return {
    kind: 'notice', capability, status: 'needsOwnConfiguration',
    body: { kind: 'customOnly', capability }, link: 'openAdditionalRequestBody',
  };
}

function readOnlyValue(input: ModelOptionCapabilityInput): ModelOptionReadOnlyValue {
  if (input.capability === 'web') {
    const selected = input.selectedIntent;
    return { kind: 'webPreference', preference: selected === AUTOMATIC || selected === 'force' ? selected : 'off' };
  }
  if (input.selectedIntent) return { kind: 'reasoningTier', intent: input.selectedIntent };
  if (input.availableIntents.includes(AUTOMATIC)) return { kind: 'reasoningTier', intent: AUTOMATIC };
  return { kind: 'modelDefault' };
}

/** A: the web search toggle writes the capability preference; the timing row appears only when it is on and force is declared. */
function webShape(input: ModelOptionCapabilityInput): ModelOptionCapabilityShape {
  const isOn = input.selectedIntent === AUTOMATIC || input.selectedIntent === 'force';
  const target: ModelOptionToggleTarget = { kind: 'capabilityPreference', on: AUTOMATIC, off: 'off' };
  if (isOn && input.availableIntents.includes('force')) {
    return {
      kind: 'toggleWithTiming', capability: 'web', isOn: true, target,
      timing: { options: [AUTOMATIC, 'force'], selection: input.selectedIntent === 'force' ? 'force' : AUTOMATIC },
    };
  }
  return { kind: 'toggle', capability: 'web', isOn, target, caption: 'searchesTheWeb' };
}

/** B: thinking. Only declared tiers are drawn; rejected tiers are removed from the options, and a rejected selection falls back to the nearest accepted tier. */
function reasoningShape(input: ModelOptionCapabilityInput): ModelOptionCapabilityShape {
  const declared = new Set(input.availableIntents);
  const hasAutomatic = declared.has(AUTOMATIC);
  const hasOff = declared.has('off');
  const tiers = REASONING_TIER_ORDER.filter((tier) => tier !== 'off' && declared.has(tier));
  // The automatic tier never counts as rejected: only the five tiers from off to max are considered.
  const rejectedSet = new Set(input.rejectedIntents.filter((intent) => intent !== AUTOMATIC));
  const rejected: string[] = REASONING_TIER_ORDER
    .filter((intent) => declared.has(intent) && rejectedSet.has(intent));

  if (tiers.length + (hasOff ? 1 : 0) + (hasAutomatic ? 1 : 0) <= 1) {
    const fixed = tiers[0] ?? (hasAutomatic ? AUTOMATIC : hasOff ? 'off' : undefined);
    return { kind: 'notice', capability: 'reasoning', status: 'alwaysThinks', body: { kind: 'fixedTier', ...(fixed ? { intent: fixed } : {}) } };
  }
  if (hasOff && tiers.length === 1 && !hasAutomatic && rejected.length === 0) {
    return {
      kind: 'toggle', capability: 'reasoning', isOn: input.selectedIntent === tiers[0],
      target: { kind: 'capabilityPreference', on: tiers[0], off: 'off' }, caption: 'thinksFirst',
    };
  }

  const options = [...(hasAutomatic ? [AUTOMATIC] : []), ...(hasOff ? ['off'] : []), ...tiers]
    .filter((intent) => !rejectedSet.has(intent));
  const selected = input.selectedIntent;
  let selection: string | undefined;
  if (selected && options.includes(selected)) {
    selection = selected;
  } else {
    if (selected && rejectedSet.has(selected) && declared.has(selected)) selection = nearestAcceptedReasoningTier(selected, options);
    if (!selection && hasAutomatic && options.includes(AUTOMATIC)) selection = AUTOMATIC;
  }

  let trailing: ModelOptionTierTrailing;
  let footnotes: ModelOptionTierFootnote[];
  if (rejected.length > 0) {
    const shown = selected && rejected.includes(selected) ? selected : highestTier(rejected);
    trailing = { kind: 'rejected', intent: shown };
    footnotes = selection ? [{ kind: 'rejectedFallback', rejected: shown, fallback: selection }] : [];
  } else if (hasOff) {
    trailing = selection ? { kind: 'tierNote', intent: selection } : { kind: 'modelDefault' };
    footnotes = [];
  } else if (selection) {
    trailing = { kind: 'alwaysThinks' };
    footnotes = [{ kind: 'tierNote', intent: selection }, { kind: 'costNote' }];
  } else {
    trailing = { kind: 'modelDefault' };
    footnotes = [{ kind: 'costNote' }];
  }
  return {
    kind: 'tiers', capability: 'reasoning', includesOff: hasOff, options,
    ...(selection ? { selection } : {}), trailing, footnotes, rejected,
  };
}

function highestTier(intents: readonly string[]): string {
  const order: readonly string[] = REASONING_TIER_ORDER;
  return [...intents].sort((a, b) => order.indexOf(a) - order.indexOf(b))[intents.length - 1];
}

/** C: thinking on custom / local connections relies on the chat-template switch in the additional request body. */
function chatTemplateShape(input: ModelOptionCapabilityInput): ModelOptionCapabilityShape {
  if (!input.isWritable) {
    return {
      kind: 'disclosure', capability: 'reasoning',
      status: { kind: 'currentValue', value: { kind: 'chatTemplateThinking', isOn: input.chatTemplateThinkingIsOn } },
    };
  }
  return {
    kind: 'toggle', capability: 'reasoning', isOn: input.chatTemplateThinkingIsOn,
    target: { kind: 'chatTemplateThinking' }, caption: 'chatTemplateThinking', link: 'openAdditionalRequestBody',
  };
}

/**
 * Connection form of the web row (the form input mapping of external search services): by `providerFormOf`; among subscriptions, Grok always has web on as its own item,
 * other subscriptions (Codex) and BYOK share the same basis in routing.
 */
export function webSearchRouteForm(provider: Pick<Provider, 'kind' | 'authMode'>): WebRouteForm {
  switch (providerFormOf(provider)) {
    case 'relay': return 'relay';
    case 'subscription': return provider.kind === 'grok' ? 'subscription_grok' : 'subscription_codex';
    case 'official': return 'byok';
  }
}

/** Native web search rejected (dormant): the chat page shows the rejection copy (webRuntimeRejected), and the pre-send route reads the same decision. */
export function webSearchNativeRejected(identity: CapabilityRecoveryIdentity | undefined): boolean {
  return identity ? capabilityRejectionIsDormant(identity, 'web', 'provider_recipe') : false;
}

/** Control state -> recipe web control (facts.recipeWeb). */
function recipeWebOf(status: ModelControlStatus): RecipeWebState {
  switch (status) {
    case 'automaticAvailable':
    case 'forceUnsupported':
    case 'alwaysOn':
      return 'auto_available';
    case 'unsupported':
    case 'externalConnectorOnly':
      return 'unavailable';
    case 'customOnly':
      return 'custom_only';
    default:
      return 'none';
  }
}

/**
 * Normalize this client's facts into the facts of `resolveWebSearchState`: the panel, sending and the composer web chip preview all take facts only through here.
 * Relay status = web-probe presentation statusId (local engine / undecided protocol recorded separately); relay missing facts = null (no external search).
 */
export function webSearchFacts(input: {
  form: WebRouteForm;
  status: ModelControlStatus;
  relayWeb?: ModelOptionRelayWeb;
  protocolUndecided: boolean;
  nativeRejected: boolean;
  toolCall: ToolCallSupport;
}): WebSearchFacts | null {
  const { form, status, relayWeb } = input;
  if (form === 'relay') {
    if (!relayWeb) return null;
    const relayStatus: RelayWebStatus = relayWeb.localEngine ? 'local_engine'
      : input.protocolUndecided ? 'protocol_undecided'
        : resolveRelayWebPresentation(relayWeb, null).statusId;
    return { form, relayStatus, toolCall: input.toolCall };
  }
  return {
    form,
    // Non-BYOK / subscription Codex do not read recipeWeb; always none.
    recipeWeb: form === 'byok' || form === 'subscription_codex' ? recipeWebOf(status) : 'none',
    nativeRejected: input.nativeRejected,
    managedWebAvailable: status === 'automaticAvailable',
    toolCall: input.toolCall,
  };
}

/** Web card action (route semantic name) -> panel outcome. */
export const WEB_ROUTE_LINK_ACTIONS: Readonly<Record<WebRouteAction, ModelOptionLinkAction>> = {
  pick_source: 'pickSearchSource',
  one_tap_enable: 'oneTapEnableSearch',
  add_search_service: 'addSearchService',
  open_supported_models: 'openSupportedModels',
};

/** Web combined result of the panel (shape resolution and the "Search method" pane both read it); no external search or missing facts = null. */
export function modelOptionWebSearchState(input: ModelOptionCapabilityInput, base?: ModelOptionCapabilityShape): WebSearchState | null {
  const external = input.externalSearch;
  if (input.capability !== 'web' || !external) return null;
  const facts = webSearchFacts({
    form: external.form,
    status: input.status,
    ...(input.relayWeb ? { relayWeb: input.relayWeb } : {}),
    protocolUndecided: input.protocolUndecided,
    nativeRejected: external.nativeRejected === true,
    toolCall: external.toolCall,
  });
  if (!facts) return null;
  const shape = base ?? resolveBaseCapabilityShape(input);
  const webOn = shape.kind === 'toggle' || shape.kind === 'toggleWithTiming'
    ? shape.isOn
    : input.selectedIntent === AUTOMATIC || input.selectedIntent === 'force';
  return resolveWebSearchState({
    facts,
    panelWritable: external.panelWritable,
    webOn,
    modelKey: external.modelKey,
    currentProviderKind: external.currentProviderKind,
    services: external.services,
    defaultServiceId: external.defaultServiceId,
    stored: external.stored,
    oneTapTarget: external.oneTap?.target ?? null,
    oneTapServiceName: external.oneTap?.serviceName ?? null,
  });
}

/** Web row with external search: rendered by `resolveWebSearchState().shapeMode`, no separate judgment. */
function withExternalSearch(input: ModelOptionCapabilityInput, base: ModelOptionCapabilityShape): ModelOptionCapabilityShape {
  const state = modelOptionWebSearchState(input, base);
  if (!state || state.card.existing) return base;
  const { card } = state;
  const searchCard: ModelOptionSearchCard = {
    status: card.status, notes: card.notes, link: card.link, cta: card.cta, secondary: card.secondary,
  };
  switch (state.shapeMode) {
    case 'existing':
      return base;
    case 'existing_with_actions':
    case 'search_notice': {
      if (base.kind !== 'toggle' && base.kind !== 'toggleWithTiming' && base.kind !== 'notice' && base.kind !== 'disclosure') return base;
      if (state.shapeMode === 'existing_with_actions') return { ...base, searchCard };
      // New notice: status row and actions all come from card; the previous outcome is no longer layered on.
      const { link: _link, ...rest } = base as typeof base & { link?: ModelOptionLinkAction };
      return { ...rest, searchCard } as ModelOptionCapabilityShape;
    }
    case 'toggle_with_source': {
      const native = state.route.row === 'toggle_with_source_picker' && (base.kind === 'toggle' || base.kind === 'toggleWithTiming') ? base : undefined;
      return {
        kind: 'toggleWithSource',
        capability: 'web',
        isOn: state.toggleOn,
        target: { kind: 'capabilityPreference', on: AUTOMATIC, off: 'off' },
        ...(native ? { native } : {}),
        card: searchCard,
        path: state.route.path,
        nativeFieldsSuppressed: state.nativeFieldsSuppressed,
        controls: state.toggleControls === 'external' ? 'external' : 'conversation_web',
        serviceId: state.source.serviceId,
      };
    }
  }
}

export function resolveModelOptionCapabilityCard(input: {
  web: ModelOptionCapabilityInput;
  reasoning: ModelOptionCapabilityInput;
}): ModelOptionCapabilityCard {
  const web = resolveModelOptionCapabilityShape(input.web);
  const reasoning = resolveModelOptionCapabilityShape(input.reasoning);
  if (web.kind === 'protocolUndecided' && reasoning.kind === 'protocolUndecided') {
    return { kind: 'protocolUndecided', link: 'openConnectionProtocol' };
  }
  return { kind: 'rows', web, reasoning };
}
