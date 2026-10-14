import type { AIModel, Provider, RelayKind, RelayKeyEntry, RelayRequestedConfig } from '@oriveo/shared';
import { formatApiKeyPreview, makeRelayRequested } from '@oriveo/shared';
import { applyRelayKeyOp, RELAY_IMPLICIT_KEY_ID, relayKeyList } from '@oriveo/shared/relay/relay-keys';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { relayDetailKind } from '../../[providerId]/relay-detail-board';
import { buildModelBrowserGroups, type ModelBrowserGroup } from '../../[providerId]/model-browser-groups';
import { createRelayManualModel, withRelayKeyBindings } from '../../../../lib/core/provider-model-ops';
import {
  buildRelayCapabilityBitmap,
  inferRelayHeaderProfile,
  relayFamilyHintForTransport,
} from '../../../../lib/core/providers/relay-resolution';
import type {
  RelayDetectedConfiguration,
  RelayDiscoveryResult,
  RelayProbeTransportKind,
} from '../../../../lib/core/providers/probe/probe-runner';
import {
  relayEndpointExplicitTransport,
  withRelayDiscoveredRoot,
} from '../../../../lib/core/providers/relay-model-probe';
import { cachedRelayProbeCandidates } from '../../../../lib/core/providers/relay-probe-candidates';
import { makeRelayDefaultProviderInstanceName } from '../../../../lib/core/providers/provider-display';
import { setupProtocolForTransport, type SetupProtocol } from './setup-board';

/**
 * View state and pure functions of the two-step relay add (boards Setup / SetupModels).
 * The component renders only from what is produced here; the structure tests BOARD-SETUP-01 to 03 and BOARD-SETUPMODELS-01 to 05 assert against this too.
 */

export const RELAY_SECURITY_MODE = 'remote_https' as const;

// MARK: - Key drafts (step 1)

export interface RelayKeyDraft {
  id: string;
  apiKey: string;
  name: string;
}

/** Detection and save use only keys with a value: extra blank key rows are ignored (the primary key is handled by form validation). */
export function relayFilledKeyDrafts(keys: readonly RelayKeyDraft[]): RelayKeyDraft[] {
  return keys.filter((key, index) => index === 0 || key.apiKey.trim().length > 0); // key-choke: not-provider
}

export function initialRelayKeyDrafts(): RelayKeyDraft[] {
  return [{ id: RELAY_IMPLICIT_KEY_ID, apiKey: '', name: '' }];
}

/** With only one key no name input is shown; once a second is added every key (including the primary) shows it. */
export function relayShowsKeyNames(keys: readonly RelayKeyDraft[]): boolean {
  return keys.length >= 2;
}

/** Key name on chips / catalog rows: the name if there is one, otherwise the mask (no new "Key N" copy). */
export function relayKeyDisplayLabel(name: string | null | undefined, secret: string): string {
  const trimmed = name?.trim();
  return trimmed ? trimmed : formatApiKeyPreview(secret.trim());
}

// MARK: - Step 1 detection card

export type RelayCheckID = 'connection' | 'catalog' | 'protocols';
export type RelayCheckState = 'pending' | 'running' | 'done' | 'failed' | 'skipped';
export const RELAY_CHECK_IDS: readonly RelayCheckID[] = ['connection', 'catalog', 'protocols'];

export interface RelayCheck {
  state: RelayCheckState;
  startedAt?: number;
  endedAt?: number;
}

export interface RelayKeyCatalogRow {
  keyID: string;
  label: string;
  count?: number;
  failureKey?: string;
}

export interface RelayStepOneDetection {
  checks: Record<RelayCheckID, RelayCheck>;
  /** Subtitle of a reachable item: the request path that was actually reachable (e.g. /v1/models). */
  reachablePath?: string;
  connectionFailureKey?: string;
  catalogFailureKey?: string;
  discovery?: RelayDiscoveryResult;
  keyRows: RelayKeyCatalogRow[];
  catalogModels: AIModel[];
  relayKeys?: RelayKeyEntry[];
  endpointTypes: Record<string, string[]>;
}

export function startRelayStepOne(now: number): RelayStepOneDetection {
  return {
    checks: {
      connection: { state: 'running', startedAt: now },
      catalog: { state: 'pending' },
      protocols: { state: 'pending' },
    },
    keyRows: [],
    catalogModels: [],
    endpointTypes: {},
  };
}

function finish(check: RelayCheck, state: RelayCheckState, now: number): RelayCheck {
  return { ...check, state, endedAt: state === 'skipped' ? undefined : now };
}

function lastStatusCode(result: RelayDiscoveryResult): number | undefined {
  return [...result.attempts].reverse().find((attempt) => attempt.statusCode !== undefined)?.statusCode;
}

/** One-sentence classification: route unavailable / returns a web page -> address; 401 -> key; 403 -> cannot list models; network -> cannot connect; otherwise the existing reason is kept. */
export function relaySetupFailureKey(result: RelayDiscoveryResult): string {
  switch (result.failure) {
    case 'route_unavailable':
    case 'invalid_response':
      return 'twoStep.failAddress';
    case 'authentication_rejected':
      return lastStatusCode(result) === 403 ? 'twoStep.failPermission' : 'twoStep.failKey';
    case 'network':
      return 'twoStep.failNetwork';
    case 'embedded_query': return 'embeddedQuery';
    case 'rate_limited': return 'relayRateLimited';
    case 'temporary_failure': return 'temporaryFailure';
    case 'generation_not_verified': return 'noProtocolVerified';
    case 'invalid_endpoint': return 'invalidRequestURL';
    default: return 'twoStep.failAddress';
  }
}

/** Failure sentence when an extra key fetches its catalog (only the HTTP status is available). */
export function relayKeyCatalogFailureKey(status: number | null): string {
  if (status === null) return 'twoStep.failNetwork';
  if (status === 401) return 'twoStep.failKey';
  if (status === 403) return 'twoStep.failPermission';
  if (status === 429) return 'relayRateLimited';
  if (status >= 500) return 'temporaryFailure';
  return 'twoStep.failAddress';
}

function reachablePathOf(result: RelayDiscoveryResult): string | undefined {
  const attempt = [...result.attempts].reverse().find((item) => item.statusCode !== undefined && !item.failure);
  if (!attempt) return undefined;
  try {
    return new URL(attempt.requestURL).pathname;
  } catch {
    return undefined;
  }
}

/** Primary-key discovery finished: failure (including 401 / 403, same as iOS / Android) -> connectivity failed, the other two items skipped; otherwise proceed to fetching the catalog. */
export function relayStepOneAfterDiscovery(
  detection: RelayStepOneDetection,
  discovery: RelayDiscoveryResult,
  primaryLabel: string,
  now: number,
): RelayStepOneDetection {
  const { checks } = detection;
  const base = { ...detection, discovery, reachablePath: reachablePathOf(discovery) };
  if (discovery.state === 'failed') {
    return {
      ...base,
      connectionFailureKey: relaySetupFailureKey(discovery),
      checks: {
        connection: finish(checks.connection, 'failed', now),
        catalog: { state: 'skipped' },
        protocols: { state: 'skipped' },
      },
    };
  }
  const listed = discovery.detection?.catalogEvidenceSucceeded === true;
  const count = discovery.detection?.modelIDs.length ?? 0;
  return {
    ...base,
    checks: { ...checks, connection: finish(checks.connection, 'done', now), catalog: { state: 'running', startedAt: now } },
    keyRows: [{
      keyID: RELAY_IMPLICIT_KEY_ID,
      label: primaryLabel,
      ...(listed && count > 0 ? { count } : { failureKey: 'twoStep.modelsEmpty' }),
    }],
  };
}

/** Catalog merge done: non-empty -> recognize the protocol; empty (including all failed) -> catalog failed, protocol skipped, the failure sentence uses the step 2 empty-state sentence or the sole key's reason. */
export function relayStepOneAfterCatalog(
  detection: RelayStepOneDetection,
  catalog: Pick<RelayStepOneDetection, 'catalogModels' | 'relayKeys' | 'endpointTypes' | 'keyRows'>,
  now: number,
): RelayStepOneDetection {
  const { checks } = detection;
  const next = { ...detection, ...catalog };
  if (catalog.catalogModels.length === 0) {
    const reasons = new Set(catalog.keyRows.map((row) => row.failureKey).filter(Boolean));
    const only = reasons.size === 1 ? [...reasons][0] : undefined;
    return {
      ...next,
      catalogFailureKey: only ?? 'twoStep.modelsEmpty',
      checks: { ...checks, catalog: finish(checks.catalog, 'failed', now), protocols: { state: 'skipped' } },
    };
  }
  return {
    ...next,
    checks: { ...checks, catalog: finish(checks.catalog, 'done', now), protocols: { state: 'running', startedAt: now } },
  };
}

export function relayStepOneAfterProtocols(detection: RelayStepOneDetection, now: number): RelayStepOneDetection {
  const { checks } = detection;
  return { ...detection, checks: { ...checks, protocols: finish(checks.protocols, 'done', now) } };
}

/** The n in the title row `n / 3`: the number of finished items (completed / failed / skipped). */
export function relayDetectionProgress(detection: RelayStepOneDetection): number {
  return RELAY_CHECK_IDS.filter((id) => !['pending', 'running'].includes(detection.checks[id].state)).length;
}

export function relayStepOneFinished(detection: RelayStepOneDetection | null): boolean {
  return detection !== null && relayDetectionProgress(detection) === RELAY_CHECK_IDS.length;
}

/** After detection ends: a non-empty catalog goes to step 2 automatically, otherwise stay. */
export function relayStepOneAutoAdvances(detection: RelayStepOneDetection | null): boolean {
  return relayStepOneFinished(detection) && detection!.catalogModels.length > 0;
}

/** The primary button is always Next: no finished detection -> start detection; some -> go to step 2 (failure / empty catalog is the manual-add state). Not tappable while detecting. */
export function relayStepOnePrimary(input: {
  detection: RelayStepOneDetection | null;
  isDetecting: boolean;
  canSubmit: boolean;
}): { action: 'detect' | 'advance'; enabled: boolean } {
  return {
    action: relayStepOneFinished(input.detection) ? 'advance' : 'detect',
    enabled: input.canSubmit && !input.isDetecting,
  };
}

/** Elapsed time of this item (milliseconds); null if not started or skipped. In progress it is computed against now. */
export function relayCheckElapsedMs(check: RelayCheck, now: number): number | null {
  if (check.startedAt === undefined || check.state === 'skipped' || check.state === 'pending') return null;
  return Math.max(0, (check.endedAt ?? now) - check.startedAt);
}

/** Seconds with one decimal, digits follow the UI language. */
export function formatRelayCheckSeconds(elapsedMs: number, locale: string): string {
  return new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(elapsedMs / 1000);
}

/** The protocol chip of each model = the first item of the same candidate function as probe orchestration (family reads only the cache, zero requests). */
export function relayModelProtocol(modelID: string, endpointTypes: Readonly<Record<string, readonly string[]>>): SetupProtocol {
  const first = cachedRelayProbeCandidates({ modelID, supportedEndpointTypes: endpointTypes[modelID] })[0];
  return setupProtocolForTransport(first ?? 'openai_chat_completions');
}

// MARK: - Step 2

/**
 * Step 2 identity: IDs are equal after trim, ignoring case; date snapshots are not folded and canonical is not used.
 * Manual-add duplicate detection uses the same criterion as the enablement at save time.
 */
export function relayStepTwoSameModelID(lhs: string, rhs: string): boolean {
  return lhs.trim().toLowerCase() === rhs.trim().toLowerCase();
}

/** Catalog + manual additions (ones not in the catalog are appended). */
export function relayStepTwoCatalog(catalogModels: readonly AIModel[], manualIDs: readonly string[]): AIModel[] {
  return [
    ...catalogModels,
    ...manualIDs
      .filter((id) => !catalogModels.some((model) => relayStepTwoSameModelID(model.id, id)))
      .map((id) => createRelayManualModel(id)),
  ];
}

export type RelayStepTwoAddResult =
  | { kind: 'ignored' }
  /** Already in the list: nothing is added, the existing item is checked (using its spelling). */
  | { kind: 'existing'; modelID: string }
  | { kind: 'added'; modelID: string };

/** "Add model ID manually": empty / whitespace-only is ignored; the same as one in the catalog or already added by hand (see identity above) -> already in the list; otherwise add. */
export function relayStepTwoAddManual(
  input: { catalogModels: readonly AIModel[]; manualIDs: readonly string[] },
  raw: string,
): RelayStepTwoAddResult {
  const id = raw.trim();
  if (!id) return { kind: 'ignored' };
  const existing = relayStepTwoCatalog(input.catalogModels, input.manualIDs)
    .find((model) => relayStepTwoSameModelID(model.id, id));
  return existing ? { kind: 'existing', modelID: existing.id } : { kind: 'added', modelID: id };
}

/** The models actually enabled at save time: in display order, those identical to an earlier one keep only the first (the hint reports exactly their count). */
export function relayStepTwoEnabledSelection(ordered: readonly AIModel[]): AIModel[] {
  return ordered.filter((model, index) => ordered.findIndex((other) => relayStepTwoSameModelID(other.id, model.id)) === index);
}

/** The same grouping projection as the model library (relay groups by family keeping catalog order); models with an unknown family go to the "Other" group. */
export function relayStepTwoGroups(input: {
  catalogModels: AIModel[];
  host: string;
  query: string;
  /** Localized title of the "Other" group. */
  otherTitle: string;
}): ModelBrowserGroup[] {
  return buildModelBrowserGroups({
    catalogModels: input.catalogModels,
    query: input.query,
    capFilter: null,
    sortBy: 'recommended',
    providerKind: 'relay',
    providerLabel: input.host,
    preserveCatalogOrder: true,
    otherGroupTitle: input.otherTitle,
    literalIDs: true,
  });
}

/** Groups are collapsed by default; groups containing selected models or search hits are expanded; what the user expanded / collapsed manually takes precedence. */
export function relayStepTwoGroupExpanded(input: {
  group: ModelBrowserGroup;
  selected: ReadonlySet<string>;
  query: string;
  userExpanded: Readonly<Record<string, boolean>>;
}): boolean {
  const user = input.userExpanded[input.group.id];
  if (user !== undefined) return user;
  if (input.query.trim()) return true;
  return input.group.models.some((model) => input.selected.has(model.id));
}

/** Select all in the group: the whole group without search is passed in, so searching also selects the whole group. */
export function relayStepTwoSelectGroup(selected: ReadonlySet<string>, fullGroup: ModelBrowserGroup): Set<string> {
  const next = new Set(selected);
  for (const model of fullGroup.models) next.add(model.id);
  return next;
}

/** List the selected model ids in display order (group order without search x order within a group). */
export function relayStepTwoOrderedSelection(fullGroups: readonly ModelBrowserGroup[], selected: ReadonlySet<string>): string[] {
  return fullGroups.flatMap((group) => group.models.filter((model) => selected.has(model.id)).map((model) => model.id));
}

/** Selected models are bound one by one through RK-2 in display order; with only one key nothing is written. */
export function relayBoundSelection(provider: Provider, ordered: readonly AIModel[]): AIModel[] {
  return withRelayKeyBindings(
    { ...provider, models: [] },
    ordered.map((model) => ({ ...model, isDefault: false })),
  );
}

/** Key chip: only with two or more keys, only on checked rows; value = the name of the binding result (the mask if there is no name). */
export function relayStepTwoKeyChips(provider: Provider, ordered: readonly AIModel[]): Record<string, string> {
  const keys = relayKeyList(provider);
  if (keys.length < 2) return {};
  const chips: Record<string, string> = {};
  for (const model of relayBoundSelection(provider, ordered)) {
    const index = keys.findIndex((key) => key.id === model.relayKeyID);
    const key = keys[index >= 0 ? index : 0]!;
    chips[model.id] = relayKeyDisplayLabel(key.name, index > 0 ? key.apiKey : provider.apiKey); // key-choke: stored-field
  }
  return chips;
}

// MARK: - The connection about to be saved

export function relayKindForTransport(transport: RelayProbeTransportKind): RelayKind {
  if (transport === 'openai_responses') return 'codex_style';
  if (transport === 'anthropic_messages') return 'anthropic_compatible';
  if (transport === 'gemini_generate_content') return 'gemini_compatible';
  return 'openai_compatible';
}

/**
 * Connection-level fields of an auto connection: protocol and auth are both auto; Responses storage is off; the Codex identity is not written,
 * and at send time the default is taken by the request protocol (injected only for Responses).
 */
export function autoRelayRequested(base: RelayRequestedConfig): RelayRequestedConfig {
  const { codexCompatIdentity: _codexCompatIdentity, ...rest } = base;
  return { ...rest, transport: 'auto', authMode: 'auto', disableResponseStorage: true };
}

/** Form protocol of the quick path: the user chose no protocol, so take the OpenAI-compatible preset (only its auth and headers are used). */
export function relayQuickFormRequested(): RelayRequestedConfig {
  return { ...makeRelayRequested('openai_compatible'), securityMode: RELAY_SECURITY_MODE };
}

/**
 * The connection the quick path will save (primary key, no enabled models). The connection default protocol recognizes only the protocol route the address carries, otherwise auto;
 * the discovery root is placed accordingly; the auth / header profile of the discovered protocol is applied to the connection only when it is the connection's actual default protocol.
 */
export function relayAddBaseProvider(input: {
  id: string;
  endpoint: string;
  apiKey: string;
  detection?: RelayDetectedConfiguration;
  providers: readonly Provider[];
  now: string;
}): Provider {
  const { endpoint, detection } = input;
  const formRequested = relayQuickFormRequested();
  const detectedKind = detection ? relayKindForTransport(detection.transport) : 'openai_compatible';
  const explicit = relayEndpointExplicitTransport(endpoint, RELAY_SECURITY_MODE);
  const chosen: RelayRequestedConfig = explicit
    ? {
        ...formRequested,
        transport: explicit,
        authMode: formRequested.authMode === 'auto' && detection ? detection.authMode : formRequested.authMode,
      }
    : autoRelayRequested(formRequested);
  chosen.securityMode = RELAY_SECURITY_MODE;
  // relayRequested.modelID writes are stopped.
  chosen.modelID = undefined;
  const requested = detection
    ? withRelayDiscoveredRoot({ baseURLText: endpoint, relayRequested: chosen }, detection.transport, detection.apiBaseURL)
    : chosen;
  const discoveredIsConnectionDefault = Boolean(explicit) && detection !== undefined
    && detection.transport === effectiveTransport({ baseURLText: endpoint, relayRequested: requested }, null);
  return {
    id: input.id,
    kind: 'relay',
    customName: makeRelayDefaultProviderInstanceName(endpoint, [...input.providers]),
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    lastCheckedAt: input.now,
    lastError: undefined,
    apiKey: input.apiKey,
    apiKeyPreview: formatApiKeyPreview(input.apiKey),
    baseURLText: endpoint,
    // The kind is stored by connection protocol: an auto connection is classed as fully custom.
    relayKind: relayDetailKind({ relayKind: detectedKind, relayRequested: requested }),
    relayRequested: requested,
    relayResolvedBaseURLText: detection?.apiBaseURL,
    ...(discoveredIsConnectionDefault && detection
      ? {
          relayResolvedAuthMode: detection.authMode,
          relayResolvedHeaderProfile: inferRelayHeaderProfile(detection.transport, detection.authMode),
          relayResolvedFamilyHint: relayFamilyHintForTransport(detection.transport),
        }
      : {}),
    relayCapabilityBitmap: buildRelayCapabilityBitmap(detection?.transport ?? 'openai_chat_completions', {
      catalogEvidenceSucceeded: detection?.catalogEvidenceSucceeded ?? false,
    }),
    relayProbeVersion: 2,
    relayLastProbeAt: input.now,
  };
}

/** Remaining keys are written via RK-2 add (on save the primary key is registered first, then the rest); with two or more keys the primary key's name is written too. */
export function withRelayKeyDrafts(provider: Provider, keys: readonly RelayKeyDraft[]): Provider {
  let next: Provider = provider;
  for (const key of keys.slice(1)) {
    const name = key.name.trim();
    const applied = applyRelayKeyOp(next, { type: 'add', id: key.id, ...(name ? { name } : {}), apiKey: key.apiKey.trim() }); // key-choke: not-provider
    if (applied !== 'refused') next = applied;
  }
  const primaryName = keys[0]?.name.trim();
  if (keys.length >= 2 && primaryName) {
    const renamed = applyRelayKeyOp(next, { type: 'rename', id: keys[0]!.id, name: primaryName });
    if (renamed !== 'refused') next = renamed;
  }
  return next;
}
