/**
 * Sample fixture data and per-page presets: every value comes from the shared manifest `shared/test-fixtures/shots/relay.v1.json` (read by the entry and passed in as an argument),
 * and objects are built through the production constructors; this file keeps only the mechanics (view to query string, error body text, catalog stub switching).
 * Only imported dynamically from the development branch; data goes into the in-memory store only and is never persisted.
 */
import type { StoreApi } from 'zustand';
import type {
  AIModel,
  Provider,
  RelayCapabilityOverrides,
  RelayKeyEntry,
  RelayModelTransport,
  RelayRequestedConfig,
  RelayTransportSource,
} from '@oriveo/shared';
import { formatApiKeyPreview, makeRelayRequested } from '@oriveo/shared';
import { RELAY_IMPLICIT_KEY_ID } from '@oriveo/shared/relay/relay-keys';
import { RELAY_WEB_FRAGMENT_TEMPLATES, type RelayWebFragments, type RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import { relayWebFragmentHash, type RelayWebProbeRecord } from '@oriveo/core/providers/relay-web-probe';
import { RELAY_WEB_FRAGMENTS_STORAGE_KEY } from '../../../lib/core/chat/relay-web-fragments';
import { RELAY_WEB_PROBE_RECORDS_STORAGE_KEY } from '../../../lib/core/chat/relay-web-probe-records';
import type { AppStore } from '../../../lib/core/store/app-store';
import { refreshProviderMetadata } from '../../../lib/core/store/persistence';
import { ensureProviderCatalogs, getRelayRuntimeConfig, initMetadata } from '../../../lib/core/metadata/metadata-client';
import { createRelayManualModel } from '../../../lib/core/provider-model-ops';
import { buildRelayCapabilityBitmap } from '../../../lib/core/providers/relay-resolution';
import { toProviderError } from '../../../lib/core/providers/errors';
import { beginCapabilityEvidenceIdentityIfAbsent } from '../../../lib/core/providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { capabilityPreferenceIdentity, relayWebPreferenceIdentity, saveCapabilityPreferences } from '../../../lib/core/chat/capability-preference-settings';
import type { RelayShotSeed } from '../../../lib/dev/relay-shots-mode';
import type { RelayShotPage } from './relay-shots-pages';
import { relayKeyNotice } from '../../providers/[providerId]/relay-keys-board';

/** The part of the shared manifest `oriveo-shots-manifest/v1` this client reads (keys starting with `$` are ignored). */
export interface ShotsManifestKey {
  ref: string;
  implicit?: boolean;
  id?: string;
  name?: string;
  secret: string;
  state: NonNullable<RelayKeyEntry['status']>['state'];
  httpStatus: number | null;
}

export interface ShotsManifestPage {
  name: string;
  host: 'relay' | 'local' | 'setup';
  /** modelOptions = the production chat model options panel (expanded), for the model given by `model`. */
  view: 'detail' | 'keys' | 'library' | 'advanced' | 'webSearch' | 'modelOptions' | 'setup';
  model?: string;
  connection?: { transport?: RelayRequestedConfig['transport']; modelTransports?: 'unset'; status?: 'unverified'; enabled?: string[] };
  preset?: {
    fetchingKeys?: string[];
    addKeyOpen?: boolean;
    /** The model library opens filtered by this key (manifest key reference) via key(id). */
    keyFilter?: string;
    /** The key (manifest key reference) whose "added successfully" notice the keys page presets; the keys page wires the notice. */
    keyAdded?: string;
    expandedGroups?: string[];
    capabilityTest?: {
      results: NonNullable<NonNullable<RelayShotSeed['detail']>['capabilityTest']>['results'];
      running: NonNullable<NonNullable<RelayShotSeed['detail']>['capabilityTest']>['running'];
    };
    draftFromTemplate?: string[];
    /** Web fragments already stored before entering the page (per protocol; the capability test panel's web item needs a fragment on the first protocol). */
    webFragments?: RelayWebFragments;
    /** Web probe records that already exist before entering the page (rejected area): the hash comes from the effective fragment of the same protocol (webFragments, or that protocol's template when none is stored), and `at` is the time the page opens. */
    webProbeRecords?: Array<{ model: string; transport: RelayWebTransport; result: RelayWebProbeRecord['result']; source: RelayWebProbeRecord['source'] }>;
    /** Web capability overrides on enabled models (the tested override written by a probe). */
    webOverrides?: Array<{ model: string; value: boolean; source: NonNullable<RelayCapabilityOverrides['web']>['source'] }>;
    /** Chat web preference: on = write "on" for this page's model through the production preference store. */
    webPreference?: 'on';
    editConnection?: boolean;
    saveFailure?: { afterMs: number; httpStatus: number; reason: string; canSaveUnverified: boolean };
    setup?: {
      mode: 'quick' | 'manual';
      endpoint?: 'relay';
      key?: string;
      transport?: RelayModelTransport;
      model?: string;
      submit?: boolean;
      /** Verification on this page always fails: the fence answers every request to the fake relay with unauthorizedError. */
      failure?: { httpStatus: number; reason: string };
      detect?: boolean;
      manualModelAddOpen?: boolean;
    };
  };
}

export interface ShotsManifest {
  schema: string;
  clock: { connectionCheckedAgoSeconds: number; keyCheckedAgoSeconds: number; localCheckedAgoSeconds: number };
  relay: {
    id: string;
    name: string;
    endpoint: string;
    apiRoot: string;
    transport: RelayRequestedConfig['transport'];
    authMode: RelayRequestedConfig['authMode'];
    securityMode: NonNullable<RelayRequestedConfig['securityMode']>;
    resolvedTransports: string[];
    /** The fake relay's reply for an invalid key (shared by the edit-save failure and the manual-setup failure). */
    unauthorizedError: { httpStatus: number; body: string };
    keys: ShotsManifestKey[];
    catalog: Array<{ id: string; listedBy: string[] }>;
    enabled: Array<{
      id: string;
      key: string;
      capabilities?: Partial<Record<'image' | 'file' | 'imageGeneration' | 'toolCall', boolean>>;
      capabilitySource?: NonNullable<RelayCapabilityOverrides['image']>['source'];
      transport?: RelayModelTransport;
      transportSource?: RelayTransportSource;
    }>;
  };
  local: {
    id: string;
    name: string;
    endpoint: string;
    transport: RelayModelTransport;
    authMode: RelayRequestedConfig['authMode'];
    securityMode: NonNullable<RelayRequestedConfig['securityMode']>;
    engine: NonNullable<RelayRequestedConfig['engineProfile']>;
    models: Array<{ id: string; load: 'loaded' | 'unloaded'; declaration: NonNullable<AIModel['engineDeclaration']> }>;
    enabledCount: number;
  };
  setupCatalog: string[];
  pages: ShotsManifestPage[];
}

/** The currently active manifest (written by applyRelayShotPlan); the fence's fake upstream answers only while it exists, otherwise everything is offline. */
let active: { manifest: ShotsManifest; setup: boolean; unauthorized: boolean } | null = null;

function manifestPage(manifest: ShotsManifest, page: RelayShotPage): ShotsManifestPage {
  const entry = manifest.pages.find((item) => item.name === page);
  if (!entry) throw new Error(`[relay-shots] shots manifest has no page ${page}`);
  return entry;
}

function manifestKey(manifest: ShotsManifest, ref: string): ShotsManifestKey {
  const key = manifest.relay.keys.find((item) => item.ref === ref);
  if (!key) throw new Error(`[relay-shots] shots manifest has no key ${ref}`);
  return key;
}

/** Manifest key ref to production key id: the implicit primary key uses RELAY_IMPLICIT_KEY_ID. */
function keyID(manifest: ShotsManifest, ref: string): string {
  const key = manifestKey(manifest, ref);
  return key.implicit ? RELAY_IMPLICIT_KEY_ID : key.id!;
}

/** The catalog the fake relay answers for a key: on the setup flow page the primary key uses the setupCatalog stub, other pages use the manifest catalog's listedBy; empty while no manifest is active. */
export function demoUpstreamCatalog(ref: string): readonly string[] {
  if (!active) return [];
  const { manifest, setup } = active;
  if (setup && manifestKey(manifest, ref).implicit) return manifest.setupCatalog;
  return manifest.relay.catalog.filter((item) => item.listedBy.includes(ref)).map((item) => item.id);
}

/** Parameters of the fence's fake upstream; null while no manifest is active (requests get a local 503 as "other requests"). */
export function demoUpstream(): {
  relayEndpoint: string;
  /** Verification on this page always fails (manifest setup.failure): the fake relay answers unauthorizedError for any key. */
  relayUnauthorizedPage: boolean;
  unauthorizedError: ShotsManifest['relay']['unauthorizedError'];
  keyBySecret: (secret: string | undefined) => ShotsManifestKey | null;
  localEndpoint: string;
  localModels: readonly string[];
  loadedLocalModels: readonly string[];
} | null {
  if (!active) return null;
  const { relay, local } = active.manifest;
  return {
    relayEndpoint: relay.endpoint,
    relayUnauthorizedPage: active.unauthorized,
    unauthorizedError: relay.unauthorizedError,
    keyBySecret: (secret) => relay.keys.find((key) => key.secret === secret) ?? null,
    localEndpoint: local.endpoint,
    localModels: local.models.map((model) => model.id),
    loadedLocalModels: local.models.filter((model) => model.load === 'loaded').map((model) => model.id),
  };
}

/** Times are offset from the moment the page is entered (same as iOS); the offsets are in the manifest clock. */
const ago = (seconds: number) => new Date(Date.now() - seconds * 1000).toISOString();
/** The lastError production writes onto the connection on "save unverified" (provider-ops uses the English text of relaySetup.connectionUnverified). */
const UNVERIFIED_MESSAGE = 'Connection has not been verified.';

function vendorGroup(modelID: string): Pick<AIModel, 'groupKey' | 'groupName'> {
  if (modelID.startsWith('gpt-')) return { groupKey: 'openai', groupName: 'OpenAI' };
  if (modelID.startsWith('claude-')) return { groupKey: 'anthropic', groupName: 'Anthropic' };
  return {};
}

function catalogModel(manifest: ShotsManifest, modelID: string): AIModel {
  const listedBy = manifest.relay.catalog.find((item) => item.id === modelID)?.listedBy ?? [];
  return {
    id: modelID,
    name: modelID,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...vendorGroup(modelID),
    relayListedByKeyIDs: listedBy.map((ref) => keyID(manifest, ref)),
  };
}

function enabledRelayModels(manifest: ShotsManifest, entry: ShotsManifestPage): AIModel[] {
  const only = entry.connection?.enabled;
  const models = manifest.relay.enabled
    .filter((item) => !only || only.includes(item.id))
    .map((item): AIModel => {
      const model: AIModel = { ...catalogModel(manifest, item.id), relayKeyID: keyID(manifest, item.key) };
      const overrides: RelayCapabilityOverrides = {};
      if (item.capabilities) {
        for (const [capability, value] of Object.entries(item.capabilities) as Array<[keyof typeof item.capabilities, boolean]>) {
          overrides[capability] = { value, source: item.capabilitySource! };
        }
      }
      const web = entry.preset?.webOverrides?.find((override) => override.model === item.id);
      if (web) overrides.web = { value: web.value, source: web.source };
      if (Object.keys(overrides).length > 0) model.relayCapabilityOverrides = overrides;
      // Leave the protocol unset when the manifest gives none (long names etc.): production drops a protocol without a source, and the chip follows the connection default.
      if (item.transport) return { ...model, relayTransport: item.transport, relayTransportSource: item.transportSource! };
      return model;
    });
  if (entry.connection?.modelTransports === 'unset') {
    return models.map(({ relayTransport: _transport, relayTransportSource: _source, ...rest }) => rest);
  }
  return models;
}

/** `okRef`: the key whose fetch on this page just wrote back successfully (preset.keyAdded); its status is set to ok instead of using the manifest status. */
function demoRelayKeys(manifest: ShotsManifest, okRef?: string): RelayKeyEntry[] {
  const CHECKED_AT = ago(manifest.clock.keyCheckedAgoSeconds);
  return manifest.relay.keys.map((key) => ({
    id: key.implicit ? RELAY_IMPLICIT_KEY_ID : key.id!,
    ...(key.name !== undefined ? { name: key.name } : {}),
    // The plaintext of the implicit primary key lives on the connection apiKey and stays empty in the key table (same shape as production storage).
    apiKey: key.implicit ? '' : key.secret,
    // Manifest null = no recorded response code (RelayKeyStatus.httpStatus is optional), so the field is not written.
    status: key.ref === okRef
      ? { state: 'ok', checkedAt: CHECKED_AT }
      : { state: key.state, ...(key.httpStatus !== null ? { httpStatus: key.httpStatus } : {}), checkedAt: CHECKED_AT },
  }));
}

export function demoRelayProvider(page: RelayShotPage, manifest: ShotsManifest): Provider {
  const entry = manifestPage(manifest, page);
  const { relay } = manifest;
  const unverified = entry.connection?.status === 'unverified';
  const mainSecret = relay.keys.find((key) => key.implicit)!.secret;
  const checkedAt = ago(manifest.clock.connectionCheckedAgoSeconds);
  return {
    id: relay.id,
    kind: 'relay',
    customName: relay.name,
    status: unverified ? { kind: 'issue', message: UNVERIFIED_MESSAGE } : { kind: 'connected' },
    ...(unverified ? { lastError: UNVERIFIED_MESSAGE } : {}),
    models: enabledRelayModels(manifest, entry),
    catalogModels: relay.catalog.map((item) => catalogModel(manifest, item.id)),
    lastCheckedAt: checkedAt,
    apiKey: mainSecret,
    apiKeyPreview: formatApiKeyPreview(mainSecret),
    baseURLText: relay.endpoint,
    relayKind: 'openai_compatible',
    relayKeys: demoRelayKeys(manifest, entry.preset?.keyAdded),
    relayRequested: {
      ...makeRelayRequested('openai_compatible'),
      transport: entry.connection?.transport ?? relay.transport,
      authMode: relay.authMode,
      securityMode: relay.securityMode,
      resolvedAPIBaseURLs: Object.fromEntries(relay.resolvedTransports.map((transport) => [transport, relay.apiRoot])),
    },
    relayResolvedBaseURLText: relay.apiRoot,
    relayResolvedAuthMode: relay.authMode as Provider['relayResolvedAuthMode'],
    updatedAt: checkedAt,
  };
}

export function studioOllamaProvider(manifest: ShotsManifest): Provider {
  const { local } = manifest;
  // Same shape as the local settings storage (LocalComputeSetup): catalog = all, with the first enabledCount enabled.
  const catalog: AIModel[] = local.models.map((item) => ({
    ...createRelayManualModel(item.id),
    localLoadState: item.load,
    executionLocality: 'local',
    engineDeclaration: item.declaration,
  }));
  const apiRoot = `${local.endpoint}/v1`;
  const CHECKED_AT = ago(manifest.clock.localCheckedAgoSeconds);
  return {
    id: local.id,
    kind: 'relay',
    customName: local.name,
    status: { kind: 'connected' },
    models: catalog.slice(0, local.enabledCount),
    catalogModels: catalog,
    lastCheckedAt: CHECKED_AT,
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: local.endpoint,
    relayKind: 'openai_compatible',
    relayRequested: {
      ...makeRelayRequested('openai_compatible'),
      transport: local.transport,
      authMode: local.authMode,
      securityMode: local.securityMode,
      resolvedAPIBaseURL: apiRoot,
      engineProfile: local.engine,
    },
    relayResolvedBaseURLText: apiRoot,
    relayResolvedTransport: local.transport,
    relayResolvedAuthMode: local.authMode as Provider['relayResolvedAuthMode'],
    relayCapabilityBitmap: buildRelayCapabilityBitmap(local.transport, { catalogEvidenceSucceeded: true }),
    relayProbeVersion: 2,
    relayLastProbeAt: CHECKED_AT,
    updatedAt: CHECKED_AT,
  };
}

/** Edit page save failure: the fake relay's reply for an invalid key (manifest unauthorizedError), built through the production error constructor. */
export function demoInvalidKeyError(manifest: ShotsManifest) {
  const { httpStatus, body } = manifest.relay.unauthorizedError;
  return toProviderError(httpStatus, body, `${manifest.relay.apiRoot}/responses`);
}

export type RelayShotTarget =
  | { kind: 'detail'; providerId: string; query: string }
  /** The production chat model options panel (expanded); see RelayModelOptionsHost for the host. */
  | { kind: 'modelOptions'; providerId: string; modelId: string }
  | { kind: 'setup' };

/** DOM-driven steps: only click buttons that carry a data-testid on the production page. */
export type RelayShotDrive = 'none' | 'detect' | 'manualSubmit';

export interface RelayShotPlan {
  providers: Provider[];
  target: RelayShotTarget;
  seed: RelayShotSeed;
  /** Key/values written to the in-memory localStorage before entering the page (in sample mode localStorage is an in-memory stand-in). */
  localStorage: Record<string, string>;
  drive: RelayShotDrive;
  /** Chat web preferences (connection x model) written through the production capability preference store before entering the page. */
  webPreferences: Array<{ providerId: string; modelId: string; web: 'automatic' }>;
  /** The manifest and page name that built this plan; applyRelayShotPlan uses them to set the fence fake upstream's data source and per-page replies. */
  manifest: ShotsManifest;
  page: RelayShotPage;
}

const MODEL_BROWSER_EXPANDED_RELAY_KEY = 'oriveo.modelBrowser.expandedGroup.relay';

/** Manifest view to detail page query string (this client's routing mechanics); preset.keyFilter is translated into the model library's key(id) filter. */
function detailQuery(manifest: ShotsManifest, entry: ShotsManifestPage): string {
  switch (entry.view) {
    case 'keys':
      return '?view=keys';
    case 'library': {
      const ref = entry.preset?.keyFilter;
      return ref ? `?view=library&key=${encodeURIComponent(keyID(manifest, ref))}` : '?view=library';
    }
    case 'advanced':
      return `?view=advanced&model=${encodeURIComponent(entry.model!)}`;
    case 'webSearch':
      return '?view=web';
    default:
      return '';
  }
}

export function relayShotPlan(page: RelayShotPage, manifest: ShotsManifest): RelayShotPlan {
  const entry = manifestPage(manifest, page);
  const preset = entry.preset ?? {};
  if (entry.host === 'setup') {
    const setup = preset.setup;
    const seed: NonNullable<RelayShotSeed['setup']> = {};
    if (setup?.mode === 'manual') seed.cloudMode = 'manual';
    if (setup?.endpoint === 'relay') seed.endpoint = manifest.relay.endpoint;
    if (setup?.key) seed.apiKey = manifestKey(manifest, setup.key).secret;
    if (setup?.transport || setup?.model) seed.manualDraft = { transport: setup.transport, model: setup.model };
    if (setup?.manualModelAddOpen) seed.addManualOpen = true;
    return {
      providers: [],
      target: { kind: 'setup' },
      seed: { setup: seed },
      localStorage: {},
      webPreferences: [],
      drive: setup?.submit ? 'manualSubmit' : setup?.detect ? 'detect' : 'none',
      manifest,
      page,
    };
  }
  const detail: NonNullable<RelayShotSeed['detail']> = {};
  if (preset.editConnection) detail.editing = true;
  if (preset.saveFailure) {
    detail.settingsFailure = {
      delayMs: preset.saveFailure.afterMs,
      failure: {
        error: demoInvalidKeyError(manifest),
        phase: 'generation',
        canSaveUnverified: preset.saveFailure.canSaveUnverified,
      },
    };
  }
  if (preset.capabilityTest) {
    detail.capabilityTest = { results: { ...preset.capabilityTest.results }, running: preset.capabilityTest.running };
  }
  if (preset.fetchingKeys) detail.keysFetchingIDs = preset.fetchingKeys.map((ref) => keyID(manifest, ref));
  if (preset.addKeyOpen) detail.keysAddOpen = true;
  if (preset.keyAdded) {
    // keyAdded means this key's status on this page is ok (demoRelayKeys has already set it to ok at the moment the fetch wrote back successfully);
    // the "added successfully" notice is computed by the production notice function for the sample connection, not hand-written as N / M.
    const added = manifestKey(manifest, preset.keyAdded);
    const notice = relayKeyNotice(
      demoRelayProvider(page, manifest),
      { type: 'add', id: keyID(manifest, preset.keyAdded), apiKey: added.secret },
      true,
    );
    // If the notice cannot be computed (broken manifest: the key does not exist or the catalog is 0), throw instead of silently drawing a sample without the notice (same as iOS).
    if (!notice || typeof notice === 'string') {
      throw new Error(`[relay-shots] keyAdded ${preset.keyAdded} yields no added notice (${notice ?? 'none'})`);
    }
    detail.keysNotices = [notice];
  }
  if (preset.draftFromTemplate) detail.webSearchTemplate = true;
  // The model library remembers a single expanded group (the production ModelBrowser's single-value key).
  const expanded = preset.expandedGroups?.[0];
  const storage: Record<string, string> = expanded ? { [MODEL_BROWSER_EXPANDED_RELAY_KEY]: expanded } : {};
  if (preset.webFragments) {
    // Same shape as the production web fragments storage (version 1, per connection id); the entry writes it to the in-memory stand-in via safeLocalStorage.
    storage[RELAY_WEB_FRAGMENTS_STORAGE_KEY] = JSON.stringify({ version: 1, connections: { [manifest.relay.id]: preset.webFragments } });
  }
  if (preset.webProbeRecords) {
    // Same shape as the production probe record storage; the hash must belong to a fragment already stored for the same protocol, otherwise production reads it as untested (a broken manifest throws instead of silently drawing an empty page).
    const at = new Date().toISOString();
    const entries = preset.webProbeRecords.map((record) => {
      // Effective fragment = the stored fragment, or that protocol's built-in template when none is stored (same as production relayEffectiveWebFragment); a protocol outside the four web protocols is an error.
      const fragment = preset.webFragments?.[record.transport] ?? RELAY_WEB_FRAGMENT_TEMPLATES[record.transport];
      if (!fragment) throw new Error(`[relay-shots] webProbeRecords ${record.model} has no ${record.transport} fragment`);
      return {
        connectionId: manifest.relay.id,
        modelId: record.model,
        transport: record.transport,
        result: record.result,
        source: record.source,
        at,
        fragmentHash: relayWebFragmentHash(fragment),
      };
    });
    storage[RELAY_WEB_PROBE_RECORDS_STORAGE_KEY] = JSON.stringify({ version: 1, entries });
  }
  const providerId = entry.host === 'local' ? manifest.local.id : manifest.relay.id;
  return {
    providers: [demoRelayProvider(page, manifest), studioOllamaProvider(manifest)],
    target: entry.view === 'modelOptions'
      ? { kind: 'modelOptions', providerId, modelId: entry.model! }
      : { kind: 'detail', providerId, query: entry.host === 'local' ? '' : detailQuery(manifest, entry) },
    seed: Object.keys(detail).length > 0 ? { detail } : {},
    localStorage: storage,
    webPreferences: preset.webPreference === 'on' ? [{ providerId, modelId: entry.model!, web: 'automatic' }] : [],
    drive: 'none',
    manifest,
    page,
  };
}

const METADATA_WAIT_MS = 5_000;

/**
 * Fake data goes into the store; the manifest becomes the fence fake upstream's data source (the setup flow page switches to the setupCatalog stub); the sample connection is seeded with a capability evidence identity as production does (after provider-ops persists it),
 * and in sample mode localStorage is the fence's in-memory stand-in, so nothing is written to real storage.
 */
export function applyRelayShotPlan(plan: RelayShotPlan, store: StoreApi<AppStore>): void {
  active = {
    manifest: plan.manifest,
    setup: plan.target.kind === 'setup',
    unauthorized: manifestPage(plan.manifest, plan.page).preset?.setup?.failure !== undefined,
  };
  store.getState().setProviders(plan.providers);
  store.setState({ lastUsedModelRef: null });
  const uid = getActiveUIDSync();
  for (const provider of plan.providers) beginCapabilityEvidenceIdentityIfAbsent(uid, provider.id);
  // The chat web preference is written through the production store (connection x model layer, the same intent the panel's "on" writes); if the identity cannot be computed, fail instead of silently drawing a switch that is off.
  for (const preference of plan.webPreferences) {
    const provider = plan.providers.find((item) => item.id === preference.providerId);
    const model = provider?.models.find((item) => item.id === preference.modelId);
    // Fixed identity of the relay web switch.
    const identity = provider && model ? relayWebPreferenceIdentity(provider, model) ?? capabilityPreferenceIdentity(provider, model) : null;
    if (!identity) throw new Error(`[relay-shots] no capability preference identity for ${preference.modelId}`);
    saveCapabilityPreferences({ ...identity, scope: 'connection_model' }, { web: preference.web });
  }
}

/**
 * Preparation before entering the page: metadata goes into memory (in sample mode IndexedDB is an in-memory stand-in), fake data goes into the store, and production enrich runs once.
 * The flow continues if the metadata backend is absent (only the official catalog's thinking tiers are missing).
 */
export async function prepareRelayShot(page: RelayShotPage, manifest: ShotsManifest, store: StoreApi<AppStore>): Promise<RelayShotPlan> {
  const plan = relayShotPlan(page, manifest);
  const metadata = (async () => {
    await initMetadata();
    await ensureProviderCatalogs(getRelayRuntimeConfig().officialProviderWhitelist);
  })().catch((error: unknown) => console.warn('[relay-shots] metadata unavailable', error));
  await Promise.race([metadata, new Promise((resolve) => setTimeout(resolve, METADATA_WAIT_MS))]);
  applyRelayShotPlan(plan, store);
  await refreshProviderMetadata(store);
  return plan;
}
