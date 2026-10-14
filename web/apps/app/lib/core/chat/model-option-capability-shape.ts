import type { AIModel, Provider, RelayRequestedConfig } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { nearestAcceptedReasoningTier } from './capability-recovery-runtime';
import type { ModelControlStatus } from './model-control-capability-layout';
import { resolveRelayWebPresentation, type RelayWebFacts, type RelayWebStatusId } from './relay-web-probe-records';

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
  | 'testCapabilities';

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
   * Relay-form web search facts: when present, the web row is a chat switch (selectedIntent = the chat web
   * preference already resolved through the default layer), shaped by the fixture presentationCases, not by the verdict state.
   */
  relayWeb?: ModelOptionRelayWeb;
};

export type ModelOptionRelayWeb = RelayWebFacts;

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
  }
  | {
    kind: 'toggleWithTiming';
    capability: 'web';
    isOn: true;
    target: ModelOptionToggleTarget;
    timing: { options: readonly ['automatic', 'force']; selection: 'automatic' | 'force' };
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
  }
  | {
    kind: 'disclosure';
    capability: ModelOptionCapability;
    status: ModelOptionDisclosureStatus;
    link?: ModelOptionLinkAction;
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
        return input.supportsChatTemplate ? chatTemplateShape(input) : customOnlyNotice('reasoning');
      }
      return {
        kind: 'notice', capability,
        status: capability === 'reasoning' ? 'modelDefault' : 'temporarilyUnavailable',
        body: { kind: 'notCatalogued', capability }, link: 'openSupportedModels',
      };
  }
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
