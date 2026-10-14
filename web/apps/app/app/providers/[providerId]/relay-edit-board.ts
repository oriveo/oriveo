import type { Provider, RelayAuthMode, RelayKeyValue, RelayKind, RelayRequestedConfig, RelayTransport } from '@oriveo/shared';
import { inferRelayKind, localEngineChannelCandidates, makeRelayRequested } from '@oriveo/shared';
import {
  displayableRelayFormIssues,
  type RelayFormIssue,
} from '@oriveo/core/providers/relay-form-validation';
import { buildRelaySettingsCandidate, type RelaySettingsPatch } from '../../../lib/core/provider-ops';
import { planRelaySettingsSave, relayEndpointComparisonKey } from '../../../lib/core/providers/provider-sync';
import { previewAPIRoot } from '../../../lib/core/providers/probe/endpoint-normalizer';
import { isCleartextRelayConnection } from '../../../lib/core/providers/relay-runtime-support';
import { resolveRelayRuntimeFields } from '../../../lib/core/providers/relay-resolution';
import { relayFamilyTransportLabel } from '../relay/new/setup-board';
import { RELAY_DETAIL_TEXT, relayDetailBoard, relayDetailKind, type DetailText } from './relay-detail-board';

/**
 * Edit Connection board (view state). The component renders only from what is produced here;
 * the structure tests BOARD-EDIT-01 to 18 assert against this too. Copy keys always carry a namespace.
 */

export const RELAY_EDIT_TEXT = {
  title: 'pages.relayDetail.editConnection',
  connection: 'pages.relayDetail.connectionTitle',
  protocolAuth: 'pages.relayDetail.editBoard.protocolAuth',
  channel: 'pages.relaySetup.localTileChannel',
  headers: 'pages.relayDetail.sectionHeadersQuery',
  compatibility: 'pages.relayDetail.sectionBehavior',
  requestURL: 'pages.relayDetail.endpoint',
  engineAddress: 'pages.relayDetail.engineAddress',
  willRequest: 'pages.relaySetup.twoStep.willRequest',
  connectionSecurity: 'pages.relayDetail.connectionType',
  securityFootnote: 'pages.relayDetail.editBoard.securityFootnote',
  defaultProtocol: 'pages.relayDetail.editBoard.defaultProtocol',
  protocolAutoFootnote: 'pages.relayDetail.editBoard.protocolAutoFootnote',
  protocolSelectedFootnote: 'pages.relayDetail.editBoard.protocolSelectedFootnote',
  authentication: 'pages.relayDetail.authMode',
  authFootnote: 'pages.relayDetail.editBoard.authFootnote',
  setCount: 'pages.relayDetail.editBoard.setCount',
  userAgent: 'pages.relayDetail.editBoard.userAgent',
  header: 'pages.relayDetail.headers',
  queryParam: 'pages.relayDetail.queryParams',
  addEntry: 'pages.relayDetail.editBoard.add',
  stream: 'pages.relayDetail.editBoard.stream',
  serviceTier: 'pages.relayDetail.serviceTier',
  disableResponseStorage: 'pages.relayDetail.disableResponseStorage',
  storageFootnote: 'pages.relayDetail.editBoard.storageFootnote',
  testConnection: 'pages.relayDetail.testRelay',
  validateAndSave: 'pages.relayDetail.editBoard.validateAndSave',
  save: 'common.save',
  testing: 'pages.relayDetail.testingRelay',
  reconnecting: 'pages.relayDetail.editBoard.reconnecting',
  verified: 'pages.relayDetail.editBoard.verified',
  saveUnverified: 'pages.relayDetail.saveUnverified',
  discardTitle: 'pages.relayDetail.editBoard.discardTitle',
  unsavedMessage: 'pages.relayDetail.editBoard.unsavedMessage',
  keepEditing: 'pages.relayDetail.editBoard.keepEditing',
  discard: 'pages.relayDetail.editBoard.discard',
  protocolAuto: 'pages.relayDetail.protocolAuto',
  authModeQueryKey: 'pages.relayDetail.authModeQueryKey',
  authModeNone: 'pages.relayDetail.authModeNone',
  connectionTypeRemoteHttps: 'pages.relayDetail.connectionTypeRemoteHttps',
  connectionTypePairedHttps: 'pages.relayDetail.connectionTypePairedHttps',
  connectionTypeLocalHttp: 'pages.relayDetail.connectionTypeLocalHttp',
  connectionTypePrivateVpn: 'pages.relayDetail.connectionTypePrivateVpn',
} as const;

/** The few items editable on the page; all other fields take the store's current value on save (BOARD-EDIT-08). */
export interface RelayEditDraft {
  endpoint: string;
  transport: RelayTransport;
  authMode: RelayAuthMode;
  customUserAgent: string;
  /** Raw rows being edited (including new rows whose name is still empty); empty-name rows are dropped only on save. */
  headers: RelayKeyValue[];
  queryParams: RelayKeyValue[];
  stream: boolean;
  serviceTier: string;
  disableResponseStorage: boolean;
}

export type RelayEditStatus =
  | { kind: 'reconnecting' }
  | { kind: 'testing' }
  | { kind: 'verified' }
  | { kind: 'failed'; message: string };

export type EditGroupID = 'connection' | 'protocolAuth' | 'channel' | 'headers' | 'compatibility';
export type EditRowID =
  | 'requestURL'
  | 'engineAddress'
  | 'connectionSecurity'
  | 'defaultProtocol'
  | 'authentication'
  | 'channel'
  | 'userAgent'
  | 'header'
  | 'queryParam'
  | 'addEntry'
  | 'stream'
  | 'serviceTier'
  | 'disableResponseStorage';
export type EditIcon = 'link' | 'shield-check' | 'hard-drives' | 'key';
export type EditCompatRowID = 'stream' | 'serviceTier' | 'disableResponseStorage';
export type EditCollapsibleGroup = 'headers' | 'compatibility';

/** Edit page copy: besides DetailText, a placeholder value may itself be a copy key (the keys row title in the auth footnote). */
export type EditText = DetailText | { key: string; values?: Record<string, string | number>; keyValues: Record<string, string> };

export interface EditMenuOption {
  value: string;
  label: DetailText;
}

export interface EditRow {
  id: EditRowID;
  titleKey: string;
  icon?: EditIcon;
  /** Leading icon color (CSS variable name), same color as the same row on the detail page. */
  colorToken?: string;
  /** Row value: address / current mode / current protocol / channel name / key-value. */
  value?: DetailText;
  footnote?: EditText;
  /** Has a menu (optional); read-only rows are undefined. */
  options?: EditMenuOption[];
  /** Index of the headers / query params row in the draft array. */
  entryIndex?: number;
  /** The value slot is masked by default (headers). */
  masked?: boolean;
  /** Current value of a toggle row. */
  checked?: boolean;
}

export interface EditGroup {
  id: EditGroupID;
  titleKey: string;
  collapsible: boolean;
  expanded: boolean;
  /** Expanded by a validation hint: tapping the group header is only recorded as expanded (BOARD-EDIT-17). */
  forcedOpen: boolean;
  trailing?: DetailText;
  /** Multi-part summary (manual setup collapsed group "Auth method · filled count"), joined by · in the view. */
  trailingParts?: DetailText[];
  rows: EditRow[];
  /** Validation hints shown in this group (headers / query params go to the headers group, the rest to the connection group). */
  issues: RelayFormIssue[];
}

export interface EditStatusLine {
  kind: RelayEditStatus['kind'];
  text: DetailText;
  /** In-progress style (spinner, no icon). */
  spinning: boolean;
  icon: 'check-circle' | 'warning' | null;
  tone: 'progress' | 'success' | 'warning';
}

export interface EditActionButton {
  titleKey: string;
  enabled: boolean;
}

export interface RelayEditBoard {
  form: 'relay' | 'local';
  titleKey: string;
  subtitle: string;
  groups: EditGroup[];
  status: EditStatusLine | null;
  actionBar: { test: EditActionButton; primary: EditActionButton & { verifies: boolean } };
}

export interface RelayEditBoardInput {
  provider: Provider;
  /** The connection record when the edit page opened: the primary-button criterion only recognizes fields the user changed; default = provider. */
  baseline?: Provider;
  displayName: string;
  draft: RelayEditDraft;
  status: RelayEditStatus | null;
  isSaving: boolean;
  /** All issues of `validateRelayForm(draft, 'edit')`; required-type issues show no text but are counted. */
  issues: readonly RelayFormIssue[];
  /** The draft's address normalized by connection security mode (same function as the save path; null when the form has issues). */
  normalizedEndpoint: string | null;
  /** Compatibility rows the draft opened during this edit session (BOARD-EDIT-18). */
  shownCompatRows: ReadonlySet<EditCompatRowID>;
  /** The user's choice for the two collapsible groups; never chosen = collapsed. */
  groupChoice: Partial<Record<EditCollapsibleGroup, boolean>>;
}

const AUTH_MODES: readonly RelayAuthMode[] = ['bearer', 'x_api_key', 'x_goog_api_key', 'query_key', 'none', 'auto'];
const RELAY_TRANSPORTS: readonly RelayTransport[] = [
  'auto',
  'openai_chat_completions',
  'openai_responses',
  'anthropic_messages',
  'gemini_generate_content',
];

export function relayEditSavedRequested(provider: Provider): RelayRequestedConfig {
  return provider.relayRequested ?? makeRelayRequested(relayDetailKind(provider));
}

/** Every entry into Edit Connection rebuilds the draft from the stored configuration. */
export function relayEditDraftFromProvider(provider: Provider): RelayEditDraft {
  const requested = relayEditSavedRequested(provider);
  return {
    endpoint: provider.baseURLText ?? '',
    transport: requested.transport,
    authMode: requested.authMode,
    customUserAgent: requested.customUserAgent ?? '',
    headers: [...(requested.headers ?? [])],
    queryParams: [...(requested.queryParams ?? [])],
    stream: requested.stream !== false,
    serviceTier: requested.serviceTier ?? '',
    disableResponseStorage: requested.disableResponseStorage === true,
  };
}

function cleanEntries(entries: readonly RelayKeyValue[]): RelayKeyValue[] | undefined {
  const cleaned = entries
    .map((entry) => ({ key: entry.key.trim(), value: entry.value }))
    .filter((entry) => entry.key.length > 0);
  return cleaned.length > 0 ? cleaned : undefined;
}

/** relayKind is no longer a user option: derived from the default protocol, auto -> custom. */
export function relayKindForDefaultProtocol(transport: RelayTransport): RelayKind {
  return inferRelayKind({ transport, authMode: 'auto' });
}

/**
 * Save patch (shared by the production save path and the primary button): built on the store's current relayRequested, overriding only the items editable on the page.
 * reasoningEffort is cleared and codexCompatIdentity kept as is; the address stores the normalized draft, kept as the probed root URL if unchanged after normalization,
 * and the root is cleared only on a real change (BOARD-EDIT-11 / 13). The runtime fields are not recomputed when the connection identity is unchanged.
 */
export function relayEditSavePatch(
  provider: Provider,
  draft: RelayEditDraft,
  normalizedEndpoint: string,
): RelaySettingsPatch & { relayRequested: RelayRequestedConfig } {
  const saved = relayEditSavedRequested(provider);
  const mode = saved.securityMode;
  const endpointChanged = relayEndpointComparisonKey(normalizedEndpoint, mode) !== relayEndpointComparisonKey(provider.baseURLText, mode);
  const relayRequested: RelayRequestedConfig = {
    ...saved,
    transport: draft.transport,
    authMode: draft.authMode,
    customUserAgent: draft.customUserAgent.trim() || undefined,
    headers: cleanEntries(draft.headers),
    queryParams: cleanEntries(draft.queryParams),
    stream: draft.stream,
    serviceTier: draft.serviceTier.trim() || undefined,
    disableResponseStorage: draft.disableResponseStorage || undefined,
    reasoningEffort: undefined,
    // relayRequested.modelID writes are stopped.
    modelID: undefined,
    ...(endpointChanged ? { resolvedAPIBaseURL: undefined, resolvedAPIBaseURLs: undefined } : {}),
  };
  // Even when "unchanged", the normalized draft address is stored (same as iOS / Android); only the root is not cleared and verification is not sent.
  const baseURLText = normalizedEndpoint;
  const identityChanged = endpointChanged
    || draft.transport !== saved.transport
    || draft.authMode !== saved.authMode;
  return {
    baseURLText,
    relayKind: relayKindForDefaultProtocol(draft.transport),
    relayRequested,
    ...(identityChanged ? resolveRelayRuntimeFields({ baseURLText, relayRequested }) : {}),
  };
}

/**
 * Persistence patch of Edit Connection: baseline = the connection record when the edit page opened; only form fields where draft != baseline count as user-changed.
 * The return value is evaluated against the live record at the moment of persistence: fields the user did not change always take the live value, and where both changed the user wins,
 * and the rest (connection security, root URL and other off-page fields) are built by relayEditSavePatch on top of the live record.
 */
export function relayEditSavePatchFor(
  baseline: Provider,
  draft: RelayEditDraft,
  normalizedEndpoint: string,
): (live: Provider) => RelaySettingsPatch & { relayRequested: RelayRequestedConfig } {
  const base = relayEditDraftFromProvider(baseline);
  // The address is judged by its normalized comparison key (scheme / trailing slash / whitespace): adding only a trailing slash does not count as a user change.
  const baselineMode = relayEditSavedRequested(baseline).securityMode;
  const endpointTouched = relayEndpointComparisonKey(draft.endpoint, baselineMode)
    !== relayEndpointComparisonKey(base.endpoint, baselineMode);
  const changed: Partial<RelayEditDraft> = {
    ...(draft.transport !== base.transport ? { transport: draft.transport } : {}),
    ...(draft.authMode !== base.authMode ? { authMode: draft.authMode } : {}),
    ...(draft.customUserAgent.trim() !== base.customUserAgent.trim() ? { customUserAgent: draft.customUserAgent } : {}),
    ...(!entriesEqual(draft.headers, base.headers) ? { headers: draft.headers } : {}),
    ...(!entriesEqual(draft.queryParams, base.queryParams) ? { queryParams: draft.queryParams } : {}),
    ...(draft.stream !== base.stream ? { stream: draft.stream } : {}),
    ...(draft.serviceTier.trim() !== base.serviceTier.trim() ? { serviceTier: draft.serviceTier } : {}),
    ...(draft.disableResponseStorage !== base.disableResponseStorage
      ? { disableResponseStorage: draft.disableResponseStorage }
      : {}),
  };
  return (live) => {
    const merged: RelayEditDraft = { ...relayEditDraftFromProvider(live), ...changed };
    return relayEditSavePatch(live, merged, endpointTouched ? normalizedEndpoint : (live.baseURLText ?? ''));
  };
}

function entriesEqual(lhs: readonly RelayKeyValue[] | undefined, rhs: readonly RelayKeyValue[] | undefined): boolean {
  const left = cleanEntries(lhs ?? []) ?? [];
  const right = cleanEntries(rhs ?? []) ?? [];
  return left.length === right.length
    && left.every((entry, index) => entry.key === right[index]?.key && entry.value === right[index]?.value);
}

/**
 * Whether the draft equals the stored connection (address compared after normalization): decides whether leaving needs a discard confirmation,
 * and whether a connection test result may be written back to the connection status.
 */
export function relayEditDraftMatchesSaved(provider: Provider, draft: RelayEditDraft): boolean {
  const saved = relayEditDraftFromProvider(provider);
  const mode = relayEditSavedRequested(provider).securityMode;
  return relayEndpointComparisonKey(draft.endpoint, mode) === relayEndpointComparisonKey(saved.endpoint, mode)
    && draft.transport === saved.transport
    && draft.authMode === saved.authMode
    && draft.customUserAgent.trim() === saved.customUserAgent.trim()
    && entriesEqual(draft.headers, saved.headers)
    && entriesEqual(draft.queryParams, saved.queryParams)
    && draft.stream === saved.stream
    && draft.serviceTier.trim() === saved.serviceTier.trim()
    && draft.disableResponseStorage === saved.disableResponseStorage;
}

/**
 * Same criterion for the primary button and the save path (BOARD-EDIT-06 / 11): if planRelaySettingsSave says to verify, it is "Verify and Save".
 * What is compared is "user-changed fields merged into the live record" vs the live record; fields changed elsewhere and not by the user do not count as changes.
 */
export function relayEditNeedsVerification(
  provider: Provider,
  draft: RelayEditDraft,
  normalizedEndpoint: string | null,
  baseline: Provider = provider,
): boolean {
  const endpoint = normalizedEndpoint ?? draft.endpoint.trim();
  return planRelaySettingsSave(
    provider,
    buildRelaySettingsCandidate(provider, relayEditSavePatchFor(baseline, draft, endpoint)(provider)),
  ).needsVerification;
}

/** Compatibility trimming (BOARD-EDIT-04): list only the items relevant to the current default protocol. */
export function relayEditCompatRowsForProtocol(transport: RelayTransport): EditCompatRowID[] {
  switch (transport) {
    case 'auto':
    case 'openai_responses':
      return ['stream', 'serviceTier', 'disableResponseStorage'];
    case 'openai_chat_completions':
      return ['stream', 'serviceTier'];
    default:
      return ['stream'];
  }
}

/** Compatibility items in effect in the draft (service tier filled / do-not-retain-response on): the page accumulates from these the rows opened this session. */
export function relayEditActiveCompatRows(values: { serviceTier?: string; disableResponseStorage?: boolean }): EditCompatRowID[] {
  return [
    ...((values.serviceTier ?? '').trim() ? ['serviceTier' as const] : []),
    ...(values.disableResponseStorage ? ['disableResponseStorage' as const] : []),
  ];
}

/** The user's choice after tapping a collapsible group header (BOARD-EDIT-17): when expanded by a hint it is only recorded as expanded. */
export function relayEditNextGroupChoice(group: Pick<EditGroup, 'expanded' | 'forcedOpen'>): boolean {
  return group.forcedOpen ? true : !group.expanded;
}

/**
 * Whether the status row / failure card should dismiss the keyboard and scroll into view (BOARD-EDIT-14 / 16): reveal on appearance or when the result changes;
 * an in-flight one replaced in place by its result, a result that is dismissed, and in-flight -> in-flight are all not revealed.
 */
export function relayEditRevealsStatus(
  previous: RelayEditStatus | null,
  next: RelayEditStatus | null,
): boolean {
  if (!next) return false;
  if (!previous) return true;
  const inFlight = (status: RelayEditStatus) => status.kind === 'testing' || status.kind === 'reconnecting';
  if (inFlight(previous)) return false;
  if (inFlight(next)) return true;
  return previous.kind !== next.kind;
}

function securityModeLabelKey(mode: RelayRequestedConfig['securityMode']): string {
  if (mode === 'local_http') return RELAY_EDIT_TEXT.connectionTypeLocalHttp;
  if (mode === 'private_vpn') return RELAY_EDIT_TEXT.connectionTypePrivateVpn;
  if (mode === 'tofu_https') return RELAY_EDIT_TEXT.connectionTypePairedHttps;
  return RELAY_EDIT_TEXT.connectionTypeRemoteHttps;
}

function transportLabel(transport: RelayTransport): DetailText {
  return transport === 'auto'
    ? { key: RELAY_EDIT_TEXT.protocolAuto }
    : { literal: relayFamilyTransportLabel(transport) ?? transport };
}

export function relayEditAuthModeLabel(mode: RelayAuthMode): DetailText {
  switch (mode) {
    case 'bearer': return { literal: 'Bearer' };
    case 'x_api_key': return { literal: 'x-api-key' };
    case 'x_goog_api_key': return { literal: 'x-goog-api-key' };
    case 'query_key': return { key: RELAY_EDIT_TEXT.authModeQueryKey };
    case 'none': return { key: RELAY_EDIT_TEXT.authModeNone };
    case 'auto': return { key: RELAY_EDIT_TEXT.protocolAuto };
  }
}

export type RelayEditEntriesDraft = Pick<RelayEditDraft, 'customUserAgent' | 'headers' | 'queryParams'>;

/** Headers group filled count: a non-blank UA counts 1 + headers with non-blank names + query params with non-blank names (empty-name rows are not counted). */
export function relayEditHeadersSetCount(draft: RelayEditEntriesDraft): number {
  const named = (entries: readonly RelayKeyValue[]) => entries.filter((entry) => entry.key.trim().length > 0).length;
  return (draft.customUserAgent.trim() ? 1 : 0) + named(draft.headers) + named(draft.queryParams);
}

/** Default protocol row (same row value in Edit Connection and manual setup, BOARD-EDIT-03 / BOARD-MANUAL-02). */
export function relayEditDefaultProtocolRow(transport: RelayTransport): EditRow {
  return {
    id: 'defaultProtocol',
    titleKey: RELAY_EDIT_TEXT.defaultProtocol,
    icon: 'hard-drives',
    colorToken: '--o-row-indigo',
    value: transportLabel(transport),
    footnote: transport === 'auto'
      ? { key: RELAY_EDIT_TEXT.protocolAutoFootnote }
      : { key: RELAY_EDIT_TEXT.protocolSelectedFootnote, values: { protocol: relayFamilyTransportLabel(transport) ?? transport } },
    options: RELAY_TRANSPORTS.map((option) => ({ value: option, label: transportLabel(option) })),
  };
}

/** Auth method row; the footnote is supplied by the caller (manual setup has no keys row to point at, so no footnote). */
export function relayEditAuthenticationRow(authMode: RelayAuthMode, footnote?: EditText): EditRow {
  return {
    id: 'authentication',
    titleKey: RELAY_EDIT_TEXT.authentication,
    icon: 'key',
    colorToken: '--o-row-orange',
    value: relayEditAuthModeLabel(authMode),
    ...(footnote ? { footnote } : {}),
    options: AUTH_MODES.map((mode) => ({ value: mode, label: relayEditAuthModeLabel(mode) })),
  };
}

/** Headers group rows: UA -> each header (masked) -> each query param (not masked) -> add. */
export function relayEditEntryRows(draft: RelayEditEntriesDraft): EditRow[] {
  return [
    { id: 'userAgent', titleKey: RELAY_EDIT_TEXT.userAgent, value: { literal: draft.customUserAgent } },
    ...draft.headers.map((entry, index): EditRow => ({
      id: 'header',
      titleKey: RELAY_EDIT_TEXT.header,
      entryIndex: index,
      value: { literal: entry.value },
      masked: true,
    })),
    ...draft.queryParams.map((entry, index): EditRow => ({
      id: 'queryParam',
      titleKey: RELAY_EDIT_TEXT.queryParam,
      entryIndex: index,
      value: { literal: entry.value },
    })),
    {
      id: 'addEntry',
      titleKey: RELAY_EDIT_TEXT.addEntry,
      options: [
        { value: 'header', label: { key: RELAY_EDIT_TEXT.header } },
        { value: 'queryParam', label: { key: RELAY_EDIT_TEXT.queryParam } },
      ],
    },
  ];
}

/** Validation hint grouping: header / query-param types go to the headers group, the rest to the connection (or key block). Only those that show text are taken. */
export function relayEditSplitIssues(issues: readonly RelayFormIssue[]): { headers: RelayFormIssue[]; other: RelayFormIssue[] } {
  const speakable = displayableRelayFormIssues(issues);
  const headers = speakable.filter((issue) => issue.field === 'headers' || issue.field === 'query_params');
  return { headers, other: speakable.filter((issue) => !headers.includes(issue)) };
}

/**
 * Failure card reveal (BOARD-EDIT-14 / BOARD-MANUAL-12): dismiss the keyboard and scroll only when a new card appears;
 * the same card does not repeat, one that is dismissed is not revealed, and a repeat failure is a different card and is revealed again. The caller supplies the card identity.
 */
export function relayRevealsFailureCard<T>(previous: T | null, next: T | null): boolean {
  return next !== null && next !== previous;
}

/** The "detail page keys row title" in the auth footnote: takes that row's own key. */
function detailKeyRowTitleKey(provider: Provider): string {
  return relayDetailBoard(provider).connectionRows.find((row) => row.id === 'apiKey')?.titleKey
    ?? RELAY_DETAIL_TEXT.apiKey;
}

function statusLine(status: RelayEditStatus | null): EditStatusLine | null {
  if (!status) return null;
  switch (status.kind) {
    case 'reconnecting':
      return { kind: 'reconnecting', text: { key: RELAY_EDIT_TEXT.reconnecting }, spinning: true, icon: null, tone: 'progress' };
    case 'testing':
      return { kind: 'testing', text: { key: RELAY_EDIT_TEXT.testing }, spinning: true, icon: null, tone: 'progress' };
    case 'verified':
      return { kind: 'verified', text: { key: RELAY_EDIT_TEXT.verified }, spinning: false, icon: 'check-circle', tone: 'success' };
    case 'failed':
      return { kind: 'failed', text: { literal: status.message }, spinning: false, icon: 'warning', tone: 'warning' };
  }
}

export function relayEditBoard(input: RelayEditBoardInput): RelayEditBoard {
  const { provider, draft, status, isSaving, issues, shownCompatRows, groupChoice } = input;
  const saved = relayEditSavedRequested(provider);
  const securityMode = saved.securityMode ?? 'remote_https';
  const cleartext = isCleartextRelayConnection(securityMode);
  const engine = saved.engineProfile;
  const form: RelayEditBoard['form'] = engine ? 'local' : 'relay';
  const hasHeadersGroup = form === 'relay' || !cleartext;
  const split = relayEditSplitIssues(issues);
  const headerIssues = hasHeadersGroup ? split.headers : [];
  const connectionIssues = displayableRelayFormIssues(issues).filter((issue) => !headerIssues.includes(issue));

  const securityRow: EditRow = {
    id: 'connectionSecurity',
    titleKey: RELAY_EDIT_TEXT.connectionSecurity,
    icon: 'shield-check',
    colorToken: '--o-row-teal',
    value: { key: securityModeLabelKey(securityMode) },
    footnote: { key: RELAY_EDIT_TEXT.securityFootnote },
  };
  const authenticationRow = relayEditAuthenticationRow(
    draft.authMode,
    { key: RELAY_EDIT_TEXT.authFootnote, keyValues: { row: detailKeyRowTitleKey(provider) } },
  );

  const groups: EditGroup[] = [];
  if (form === 'relay') {
    const preview = previewAPIRoot(draft.endpoint, securityMode);
    groups.push({
      id: 'connection',
      titleKey: RELAY_EDIT_TEXT.connection,
      collapsible: false,
      expanded: true,
      forcedOpen: false,
      rows: [
        {
          id: 'requestURL',
          titleKey: RELAY_EDIT_TEXT.requestURL,
          icon: 'link',
          colorToken: '--o-row-cyan',
          value: { literal: draft.endpoint },
          ...(preview ? { footnote: { key: RELAY_EDIT_TEXT.willRequest, values: { url: `${preview}/…` } } } : {}),
        },
        securityRow,
      ],
      issues: connectionIssues,
    });
    groups.push({
      id: 'protocolAuth',
      titleKey: RELAY_EDIT_TEXT.protocolAuth,
      collapsible: false,
      expanded: true,
      forcedOpen: false,
      rows: [
        relayEditDefaultProtocolRow(draft.transport),
        authenticationRow,
      ],
      issues: [],
    });
  } else {
    const channels = localEngineChannelCandidates(engine).transports;
    groups.push({
      id: 'connection',
      titleKey: RELAY_EDIT_TEXT.connection,
      collapsible: false,
      expanded: true,
      forcedOpen: false,
      rows: [
        {
          id: 'engineAddress',
          titleKey: RELAY_EDIT_TEXT.engineAddress,
          icon: 'link',
          colorToken: '--o-row-cyan',
          value: { literal: draft.endpoint },
        },
        securityRow,
      ],
      issues: connectionIssues,
    });
    groups.push({
      id: 'channel',
      titleKey: RELAY_EDIT_TEXT.channel,
      collapsible: false,
      expanded: true,
      forcedOpen: false,
      rows: [
        {
          id: 'channel',
          titleKey: RELAY_EDIT_TEXT.channel,
          icon: 'hard-drives',
          colorToken: '--o-row-indigo',
          value: transportLabel(draft.transport),
          // With a single candidate it is read-only, no chevron.
          ...(channels.length > 1
            ? { options: channels.map((transport) => ({ value: transport, label: transportLabel(transport) })) }
            : {}),
        },
        ...(cleartext ? [] : [authenticationRow]),
      ],
      issues: [],
    });
  }

  if (hasHeadersGroup) {
    const count = relayEditHeadersSetCount(draft);
    const forcedOpen = headerIssues.length > 0;
    const expanded = forcedOpen || groupChoice.headers === true;
    groups.push({
      id: 'headers',
      titleKey: RELAY_EDIT_TEXT.headers,
      collapsible: true,
      expanded,
      forcedOpen,
      ...(count > 0 ? { trailing: { key: RELAY_EDIT_TEXT.setCount, values: { count } } } : {}),
      rows: relayEditEntryRows(draft),
      issues: headerIssues,
    });
  }

  if (form === 'relay') {
    // Items in effect are shown (turned on in the store or draft, BOARD-EDIT-15); rows opened this session stay until the page is left (BOARD-EDIT-18).
    const visible = new Set<EditCompatRowID>([
      ...relayEditCompatRowsForProtocol(draft.transport),
      ...relayEditActiveCompatRows(saved),
      ...relayEditActiveCompatRows(draft),
      ...shownCompatRows,
    ]);
    const order: EditCompatRowID[] = ['stream', 'serviceTier', 'disableResponseStorage'];
    const compatRow = (id: EditCompatRowID): EditRow => {
      switch (id) {
        case 'stream':
          return { id, titleKey: RELAY_EDIT_TEXT.stream, checked: draft.stream };
        case 'serviceTier':
          return { id, titleKey: RELAY_EDIT_TEXT.serviceTier, value: { literal: draft.serviceTier } };
        case 'disableResponseStorage':
          return {
            id,
            titleKey: RELAY_EDIT_TEXT.disableResponseStorage,
            checked: draft.disableResponseStorage,
            footnote: { key: RELAY_EDIT_TEXT.storageFootnote },
          };
      }
    };
    groups.push({
      id: 'compatibility',
      titleKey: RELAY_EDIT_TEXT.compatibility,
      collapsible: true,
      expanded: groupChoice.compatibility === true,
      forcedOpen: false,
      rows: order.filter((id) => visible.has(id)).map(compatRow),
      issues: [],
    });
  }

  const reconnecting = status?.kind === 'reconnecting';
  const testing = status?.kind === 'testing';
  const endpointBlank = draft.endpoint.trim().length === 0;
  const verifies = relayEditNeedsVerification(provider, draft, input.normalizedEndpoint, input.baseline);
  return {
    form,
    titleKey: RELAY_EDIT_TEXT.title,
    subtitle: input.displayName,
    groups,
    status: statusLine(status),
    actionBar: {
      test: {
        titleKey: RELAY_EDIT_TEXT.testConnection,
        enabled: !reconnecting && !isSaving && !testing && !endpointBlank,
      },
      primary: {
        titleKey: verifies ? RELAY_EDIT_TEXT.validateAndSave : RELAY_EDIT_TEXT.save,
        verifies,
          // Tappable looks at all issues (including silent required-type ones such as an empty address); the text and landing point use only the displayable subset.
        enabled: !reconnecting && !isSaving && issues.length === 0,
      },
    },
  };
}
