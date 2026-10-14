import type {
  AIModel,
  Provider,
  RelayAuthMode,
  RelayKeyValue,
  RelayKind,
  RelayRequestedConfig,
  RelayTransport,
} from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import type { RelayFormIssue } from '@oriveo/core/providers/relay-form-validation';
import {
  relayEditAuthenticationRow,
  relayEditAuthModeLabel,
  relayEditDefaultProtocolRow,
  relayEditEntryRows,
  relayEditHeadersSetCount,
  relayEditSplitIssues,
  relayKindForDefaultProtocol,
  RELAY_EDIT_TEXT,
  type EditGroup,
} from '../../[providerId]/relay-edit-board';
import type { DetailText } from '../../[providerId]/relay-detail-board';
import { createRelayManualModel } from '../../../../lib/core/provider-model-ops';
import { getProviderDefaultModelId } from '../../../../lib/core/metadata/metadata-client';

import { previewAPIRoot } from '../../../../lib/core/providers/probe/endpoint-normalizer';
import {
  makeRelayDefaultProviderInstanceName,
  makeUniqueProviderInstanceName,
  relayDomainNameFromEndpoint,
} from '../../../../lib/core/providers/provider-display';
import { relayEndpointExplicitTransport } from '../../../../lib/core/providers/relay-model-probe';
import { buildRelayCapabilityBitmap } from '../../../../lib/core/providers/relay-resolution';
import { PROVIDER_VALIDATION_MESSAGES } from '../../../../lib/core/providers/validation-messages';
import {
  RELAY_SECURITY_MODE,
  relayFilledKeyDrafts,
  relayKindForTransport,
  relayShowsKeyNames,
  withRelayKeyDrafts,
  type RelayKeyDraft,
} from './relay-setup-two-step';
import { RELAY_SETUP_HERO_KEYS } from './setup-board';

/**
 * View state and persisted shape of the manual setup board (the ManualSetup board).
 * It shares the shell of quick-connect step 1 and the address and all keys; the component renders only what is produced here, and the structure tests assert against this output too.
 * The protocol / auth / header rows use the same row model as the edit-connection page (relay-edit-board). Message keys always carry their namespace.
 */

export const MANUAL_SETUP_TEXT = {
  heroLabel: `pages.relaySetup.${RELAY_SETUP_HERO_KEYS[0]}`,
  heroTitle: `pages.relaySetup.${RELAY_SETUP_HERO_KEYS[1]}`,
  heroSubtitle: 'pages.relaySetup.manual.heroSubtitle',
  heroTrailing: 'pages.relaySetup.manualSetup',
  useQuickSetup: 'pages.relaySetup.manual.useQuickSetup',
  requestURL: 'pages.relaySetup.requestURLLabel',
  model: 'pages.relaySetup.defaultModelLabel',
  modelFootnote: 'pages.relaySetup.manual.modelFootnote',
  connectionName: 'pages.relaySetup.manual.connectionName',
  connectionNameSlot: 'pages.relaySetup.twoStep.keyName',
  connectionNameFootnote: 'pages.relaySetup.manual.connectionNameFootnote',
  protocol: 'pages.relaySetup.transport',
  advanced: 'pages.relaySetup.manual.advancedGroup',
  notSet: 'pages.relaySetup.manual.notSet',
  validateAndSave: RELAY_EDIT_TEXT.validateAndSave,
  validateAgain: 'pages.relaySetup.manual.validateAgain',
  notSaved: 'pages.relaySetup.manual.notSaved',
  saveUnverified: RELAY_EDIT_TEXT.saveUnverified,
} as const;

/** The model slot placeholder is the flagship model ID delivered by the server; the fallback when metadata has not arrived is unchanged. */
const FALLBACK_FLAGSHIP_MODEL_ID = 'gpt-5.6-sol';

export function relayFlagshipModelID(): string {
  return getProviderDefaultModelId('openAI') ?? FALLBACK_FLAGSHIP_MODEL_ID;
}

export type ManualSetupSectionID = 'requestURL' | 'apiKeys' | 'model' | 'connectionName' | 'protocol' | 'advanced' | 'failure';

/** Inputs owned by the manual page (the address and keys are shared with quick connect and are not here). */
export interface ManualSetupDraft {
  model: string;
  name: string;
  transport: RelayTransport;
  authMode: RelayAuthMode;
  customUserAgent: string;
  /** The raw rows being edited (including new rows whose name is still empty); empty-name rows are dropped only on persisting. */
  headers: RelayKeyValue[];
  queryParams: RelayKeyValue[];
}

/** The default protocol starts as auto, and auth starts as auto. */
export function initialManualSetupDraft(): ManualSetupDraft {
  return { model: '', name: '', transport: 'auto', authMode: 'auto', customUserAgent: '', headers: [], queryParams: [] };
}

export type ManualSetupPhase =
  | { kind: 'idle' }
  | { kind: 'validating' }
  /** failureID: one identity per failure card, which the reveal function uses to tell whether it is a new card. */
  /** cause: persistence when persisting itself fails (not a verification failure); the failure card then does not offer "Save anyway (unverified)". */
  | { kind: 'failed'; failureID: number; cause?: 'verification' | 'persistence' }
  | { kind: 'saving' }
  | { kind: 'saved' };

export interface ManualSetupBoardInput {
  endpoint: string;
  keys: readonly RelayKeyDraft[];
  draft: ManualSetupDraft;
  /** All issues from `validateRelayForm(draft, 'create')`; required-field issues show no text but are counted. */
  issues: readonly RelayFormIssue[];
  /** The same normalization function as the save path (null when the form has problems). */
  normalizedEndpoint: string | null;
  flagshipModelID: string;
  phase: ManualSetupPhase;
  /** The user's choice for the collapsible group; never chosen = collapsed. */
  advancedChoice: boolean | undefined;
}

export interface ManualSetupBoard {
  hero: { icon: 'hard-drives'; labelKey: string; titleKey: string; subtitleKey: string; trailingKey: string };
  /** Top-left text button (no arrow); no separate back button is placed. */
  leadingAction: { titleKey: string };
  sections: ManualSetupSectionID[];
  requestURL: { titleKey: string; icon: 'link'; preview: string | null };
  /** Address / connection security / key hints all appear under the key block. */
  apiKeys: { showsNames: boolean; issues: RelayFormIssue[] };
  model: { titleKey: string; icon: 'squares-four'; placeholder: string; footnoteKey: string };
  connectionName: { titleKey: string; icon: 'pencil-simple'; slotLabelKey: string; placeholder: string; footnoteKey: string };
  protocolGroup: EditGroup;
  advancedGroup: EditGroup;
  failure: { failureID: number; noteKey: string; saveUnverifiedKey: string | null } | null;
  primary: { titleKey: string; enabled: boolean; spinning: boolean };
}

export function manualSetupBoard(input: ManualSetupBoardInput): ManualSetupBoard {
  const { draft, phase } = input;
  const split = relayEditSplitIssues(input.issues);
  const preview = previewAPIRoot(input.endpoint, RELAY_SECURITY_MODE);
  const domain = relayDomainNameFromEndpoint(input.normalizedEndpoint ?? input.endpoint.trim()) ?? '';
  const count = relayEditHeadersSetCount(draft);
  const forcedOpen = split.headers.length > 0;
  const failure = phase.kind === 'failed'
    ? {
        failureID: phase.failureID,
        noteKey: MANUAL_SETUP_TEXT.notSaved,
        // When persisting itself failed, "Save anyway" would just fail to persist again.
        saveUnverifiedKey: phase.cause === 'persistence' ? null : MANUAL_SETUP_TEXT.saveUnverified,
      }
    : null;
  const busy = phase.kind === 'validating' || phase.kind === 'saving' || phase.kind === 'saved';
  const trailingCount: DetailText = count > 0
    ? { key: RELAY_EDIT_TEXT.setCount, values: { count } }
    : { key: MANUAL_SETUP_TEXT.notSet };
  return {
    hero: {
      icon: 'hard-drives',
      labelKey: MANUAL_SETUP_TEXT.heroLabel,
      titleKey: MANUAL_SETUP_TEXT.heroTitle,
      subtitleKey: MANUAL_SETUP_TEXT.heroSubtitle,
      trailingKey: MANUAL_SETUP_TEXT.heroTrailing,
    },
    leadingAction: { titleKey: MANUAL_SETUP_TEXT.useQuickSetup },
    sections: ['requestURL', 'apiKeys', 'model', 'connectionName', 'protocol', 'advanced', ...(failure ? ['failure' as const] : [])],
    requestURL: { titleKey: MANUAL_SETUP_TEXT.requestURL, icon: 'link', preview: preview ? `${preview}/…` : null },
    apiKeys: { showsNames: relayShowsKeyNames(input.keys), issues: split.other },
    model: { titleKey: MANUAL_SETUP_TEXT.model, icon: 'squares-four', placeholder: input.flagshipModelID, footnoteKey: MANUAL_SETUP_TEXT.modelFootnote },
    connectionName: {
      titleKey: MANUAL_SETUP_TEXT.connectionName,
      icon: 'pencil-simple',
      slotLabelKey: MANUAL_SETUP_TEXT.connectionNameSlot,
      placeholder: domain,
      footnoteKey: MANUAL_SETUP_TEXT.connectionNameFootnote,
    },
    protocolGroup: {
      id: 'protocolAuth',
      titleKey: MANUAL_SETUP_TEXT.protocol,
      collapsible: false,
      expanded: true,
      forcedOpen: false,
      rows: [relayEditDefaultProtocolRow(draft.transport)],
      issues: [],
    },
    advancedGroup: {
      id: 'headers',
      titleKey: MANUAL_SETUP_TEXT.advanced,
      collapsible: true,
      // Stay expanded while the group has a hint (even if the user chose to collapse it); once the hint disappears, follow the user's choice.
      expanded: forcedOpen || input.advancedChoice === true,
      forcedOpen,
      trailingParts: [relayEditAuthModeLabel(draft.authMode), trailingCount],
      rows: [relayEditAuthenticationRow(draft.authMode), ...relayEditEntryRows(draft)],
      issues: split.headers,
    },
    failure,
    primary: {
      titleKey: phase.kind === 'failed' ? MANUAL_SETUP_TEXT.validateAgain : MANUAL_SETUP_TEXT.validateAndSave,
      // Clickable to see all issues (including the silent required-field ones) + model non-blank; click handling uses the same criterion.
      enabled: !busy && input.issues.length === 0 && draft.model.trim().length > 0,
      spinning: phase.kind === 'validating' || phase.kind === 'saving',
    },
  };
}

/**
 * Input snapshot for in-flight invalidation: address (compared after normalization), the values of all keys, model, protocol, auth, UA, headers, and query parameters.
 * Connection name and key names are not included (changing them does not invalidate the failure card).
 */
export function manualSetupInputKey(input: {
  normalizedEndpoint: string | null;
  endpoint: string;
  keys: readonly RelayKeyDraft[];
  draft: ManualSetupDraft;
}): string {
  const { draft } = input;
  return JSON.stringify([
    input.normalizedEndpoint ?? input.endpoint.trim(),
    // Empty extra-key slots are neither attached nor verified, and adding an empty slot does not count as changing the input.
    relayFilledKeyDrafts(input.keys).map((key) => key.apiKey), // key-choke: not-provider
    draft.model.trim(),
    draft.transport,
    draft.authMode,
    draft.customUserAgent,
    draft.headers,
    draft.queryParams,
  ]);
}

function cleanEntries(entries: readonly RelayKeyValue[]): RelayKeyValue[] | undefined {
  const cleaned = entries
    .map((entry) => ({ key: entry.key.trim(), value: entry.value }))
    .filter((entry) => entry.key.length > 0);
  return cleaned.length > 0 ? cleaned : undefined;
}

/**
 * Connection-level config (same shape as quick connect's "add manually after connection failure"): protocol / auth are what the user picked, stream = true;
 * Responses carries do-not-retain-responses and the Codex identity, auto carries only do-not-retain-responses; UA is stored trimmed, and header / query-parameter rows with empty names are dropped;
 * the connection-level modelID is empty. It does not go through RelayKindDefaults (makeRelayRequested), so there is no service tier / connection-level reasoning.
 */
export function manualSetupRequested(draft: ManualSetupDraft): RelayRequestedConfig {
  return {
    transport: draft.transport,
    authMode: draft.authMode,
    securityMode: RELAY_SECURITY_MODE,
    stream: true,
    ...(draft.transport === 'openai_responses' ? { disableResponseStorage: true, codexCompatIdentity: true } : {}),
    ...(draft.transport === 'auto' ? { disableResponseStorage: true } : {}),
    customUserAgent: draft.customUserAgent.trim() || undefined,
    headers: cleanEntries(draft.headers),
    queryParams: cleanEntries(draft.queryParams),
  };
}

/** Analytics relay_kind uses the effective protocol: the chosen one if chosen; with auto and an address that carries a protocol path, the one inferred from the address; when the address cannot become a request, it is reported as auto. */
export function manualSetupEffectiveRelayKind(endpoint: string, transport: RelayTransport): RelayKind {
  if (transport !== 'auto') return relayKindForDefaultProtocol(transport);
  const explicit = relayEndpointExplicitTransport(endpoint, RELAY_SECURITY_MODE);
  return explicit ? relayKindForTransport(explicit) : relayKindForDefaultProtocol('auto');
}

/**
 * The connection about to be saved (the shape when verification passes): the primary key + the other keys that were filled in (with names; a single key is not listed);
 * the enabled model is exactly this one (declaring text only), the catalog holds it first and is refreshed after persisting. No detection was run, so per-key state and which key lists which model are not written.
 */
export function manualSetupProvider(input: {
  id: string;
  endpoint: string;
  keys: readonly RelayKeyDraft[];
  draft: ManualSetupDraft;
  providers: readonly Provider[];
  now: string;
}): Provider {
  const { endpoint, draft } = input;
  const primaryKey = input.keys[0]!.apiKey.trim(); // key-choke: not-provider
  const model: AIModel = { ...createRelayManualModel(draft.model.trim()), isDefault: false };
  const requested = manualSetupRequested(draft);
  const name = draft.name.trim();
  // Attach keys before placing the model: adding a key pins existing models to the primary key and adds "listed by primary key" to the catalog, and since no detection was run these are not written.
  const base: Provider = {
    id: input.id,
    kind: 'relay',
    customName: name
      ? makeUniqueProviderInstanceName(name, 'relay', [...input.providers])
      : makeRelayDefaultProviderInstanceName(endpoint, [...input.providers]),
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    lastCheckedAt: input.now,
    lastError: undefined,
    apiKey: primaryKey,
    apiKeyPreview: formatApiKeyPreview(primaryKey),
    baseURLText: endpoint,
    relayKind: relayKindForDefaultProtocol(draft.transport),
    relayRequested: requested,
    relayCapabilityBitmap: buildRelayCapabilityBitmap(
      draft.transport === 'auto' ? 'openai_chat_completions' : draft.transport,
      { catalogEvidenceSucceeded: false },
    ),
    relayProbeVersion: 2,
    relayLastProbeAt: input.now,
  };
  return { ...withRelayKeyDrafts(base, input.keys), models: [model], catalogModels: [model] };
}

/** Failure card "Save anyway (unverified)": the status uses the same stable text as an unverified save on the edit-connection page, and the original error text is not stored. */
export function manualSetupUnverified(provider: Provider): Provider {
  return {
    ...provider,
    status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
    lastCheckedAt: undefined,
    lastError: PROVIDER_VALIDATION_MESSAGES.unverified,
  };
}

/** Three tiers for "Switch to quick connect": 100% on one line, then 85% on one line, then 85% on at most two lines; no tier truncates. */
export type QuickSetupButtonFit = 'full' | 'scaled' | 'wrapped';

export const QUICK_SETUP_BUTTON_SCALE = 0.85;

/** The tier is decided only from two widths; if not yet measured (<= 0) it uses 100% on one line. The tolerance absorbs sub-pixel and floating-point error. */
export function quickSetupButtonFit(availableWidth: number, fullSizeOneLineWidth: number): QuickSetupButtonFit {
  if (availableWidth <= 0 || fullSizeOneLineWidth <= 0) return 'full';
  const epsilon = 0.01;
  if (fullSizeOneLineWidth <= availableWidth + epsilon) return 'full';
  if (fullSizeOneLineWidth * QUICK_SETUP_BUTTON_SCALE <= availableWidth + epsilon) return 'scaled';
  return 'wrapped';
}
