import { isValidProviderKind, type AIModel, type Provider } from '@oriveo/shared';
import { customControlRiskTiers, resolveCustomControlDefinitions } from '@oriveo/core/providers/request-preference/capability-runtime';
import { previewSafeCustomFragment } from '@oriveo/core/providers/request-builders/dispatch';
import { getCapabilityRuntime } from '../metadata/metadata-client';
import { capabilityRuntimeIdentity, decodeCapabilityTransportIdentity } from './capability-preference-settings';
import { resolveGenerationProfileForModel } from './stream-options';
import { capabilityRejectionIsDormant, clearCapabilityRejectionSetting, type CapabilityRecoveryIdentity } from './capability-recovery-runtime';
import {
  readLegacyBareStore, readPartitionedStore, writeLegacyBareStore, writePartitionedStore,
} from '../../infra/storage/partitioned-local-store';

/**
 * Custom request fields are intentionally browser-local. They must never join
 * preference sync, diagnostics, telemetry, or support exports because a draft
 * can contain provider-specific business data.
 *
 * For that same reason the local key is partitioned per UID (`oriveo.{uid}.*`, see
 * `partitioned-local-store`). Without partitioning, after one account signs out and another
 * signs in, the second user opens the same connection editor and sees the JSON the first
 * user typed - and it would still go out on the wire.
 */
const STORAGE_KEY = 'local-custom-fragments.v2';
/**
 * Retired developer gate key. Nothing reads it; the literal survives only for the one-time
 * migration that cleans up older installs.
 */
const RETIRED_DEVELOPER_GATE_KEY = 'oriveo.local-custom-fragment-developer-mode.v1';
export const CUSTOM_FRAGMENT_SETTINGS_EVENT = 'oriveo:custom-fragment-settings';

export const CUSTOM_FRAGMENT_OWNERS = ['web', 'reasoning', 'generation'] as const;
export type CustomFragmentOwner = typeof CUSTOM_FRAGMENT_OWNERS[number];
export type CustomFragmentConfigurationMode = 'auto' | 'custom';

export type CustomFragmentScope = {
  providerId: string;
  modelId: string;
  transportIdentity: string;
  owner: CustomFragmentOwner;
  /** Local-only exact identity used to reconfirm a dormant custom blob. */
  recoveryIdentity?: CapabilityRecoveryIdentity;
};

export type CustomFragmentSettings = {
  configurationMode: CustomFragmentConfigurationMode;
  raw: string;
};

/** The key separator must be a character that cannot appear in an id: model ids have
 *  contained both colons and slashes. Always write it escaped - a raw NUL byte in the
 *  source makes git treat the whole file as binary, so there is no diff and grep misses it. */
const CUSTOM_FRAGMENT_KEY_SEPARATOR = '\u0000';

function storageKey(scope: CustomFragmentScope): string {
  return [scope.providerId, scope.modelId, scope.transportIdentity, scope.owner]
    .join(CUSTOM_FRAGMENT_KEY_SEPARATOR);
}

function isSettings(value: unknown): value is CustomFragmentSettings {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return (record.configurationMode === 'auto' || record.configurationMode === 'custom')
    && typeof record.raw === 'string';
}

/**
 * Known trade-off: the whole-table read-modify-write takes no lock and does not listen for
 * `storage` events. When two tabs edit custom fields for different owners at once, the later
 * write puts back its own snapshot of the whole table over the earlier one. The reason for
 * not adding a listener is the same as for the typed preference table: writes happen per
 * keystroke, so a cross-tab replay path would turn the editor into a controlled component an
 * outside tab can rewrite - a snapshot from another tab replacing what the user is currently
 * typing is worse than the occasional overwrite.
 */
function read(): Record<string, CustomFragmentSettings> {
  try {
    const value: unknown = JSON.parse(readPartitionedStore(STORAGE_KEY) ?? '{}');
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    return Object.fromEntries(Object.entries(value).filter((entry): entry is [string, CustomFragmentSettings] => isSettings(entry[1])));
  } catch { return {}; }
}

function write(value: Record<string, CustomFragmentSettings>) {
  writePartitionedStore(STORAGE_KEY, JSON.stringify(value));
}

export function customFragmentScope(
  provider: Provider,
  model: AIModel,
  transportIdentity: string,
  owner: CustomFragmentOwner = 'generation',
): CustomFragmentScope {
  const runtimeIdentity = capabilityRuntimeIdentity(provider, model);
  return {
    providerId: provider.id, modelId: model.id, transportIdentity, owner,
    ...(runtimeIdentity?.transportIdentity === transportIdentity ? { recoveryIdentity: {
      connectionId: runtimeIdentity.providerId,
      canonicalModelId: runtimeIdentity.canonicalModelId,
      finalTransport: runtimeIdentity.finalTransport,
      runtimeRevision: runtimeIdentity.runtimeRevision,
    } } : {}),
  };
}

export function isCustomFragmentEligible(provider: Provider): boolean {
  return isValidProviderKind(provider.kind);
}

/**
 * One-time migration for the retired global developer gate: the only condition for sending
 * custom fields is `configurationMode === 'custom'`.
 *
 * Migrating rather than dropping the key: installs that had the gate switched off can still
 * hold `custom` records (written while it was on, drafts kept by design afterwards). Without
 * the gate those fragments would suddenly start going out on the wire - a decision the user
 * never made, first visible as a message that behaves differently. They are rewritten to
 * `auto` with `raw` kept intact, so the editor still shows what was written and the user can
 * turn it back on. Installs that had the gate on only need the key cleared, since their
 * configuration already applies as-is.
 *
 * Idempotent: if the old key is absent this does nothing, and it writes no marker key of its
 * own. Only machines carrying the old key are affected, and a marker that could be cleared by
 * mistake would be more dangerous for fresh installs.
 */
export function migrateRetiredCustomFragmentDeveloperGate(): void {
  if (typeof window === 'undefined') return;
  let stored: string | null = null;
  try { stored = localStorage.getItem(RETIRED_DEVELOPER_GATE_KEY); } catch { return; }
  if (stored === null) return;
  try { localStorage.removeItem(RETIRED_DEVELOPER_GATE_KEY); } catch { /* local-only optional setting */ }
  if (stored === 'true') return;
  const settings = read();
  let changed = false;
  for (const [key, value] of Object.entries(settings)) {
    if (value.configurationMode !== 'custom') continue;
    settings[key] = { configurationMode: 'auto', raw: value.raw };
    changed = true;
  }
  // Go through the versioned store rather than editing the raw key.
  if (changed) write(settings);
  // The legacy bare key (no UID dimension) has to be disarmed as well. This migration runs at
  // module load as guest, and the guest partition deliberately does not delete the bare key -
  // it waits for the first real account to inherit it. The old gate key is already gone by
  // then, so this migration never runs a second time: without handling it here, the records
  // inherited after sign-in would still be `custom` and would start going out unannounced.
  disarmLegacyBareCustomFragments();
}

function disarmLegacyBareCustomFragments(): void {
  const raw = readLegacyBareStore(STORAGE_KEY);
  if (raw === null) return;
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { return; }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return;
  let changed = false;
  const next: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
    if (isSettings(value) && value.configurationMode === 'custom') {
      next[key] = { configurationMode: 'auto', raw: value.raw };
      changed = true;
    } else {
      next[key] = value;
    }
  }
  if (changed) writeLegacyBareStore(STORAGE_KEY, JSON.stringify(next));
}

// The migration runs at module load: this store has no store/init lifecycle, and every read
// or write path imports this module first, so module load is the only point guaranteed to
// precede the first outbound decision. Under SSR `window` is absent and the function bails.
migrateRetiredCustomFragmentDeveloperGate();

export function loadCustomFragmentSettings(scope: CustomFragmentScope): CustomFragmentSettings {
  return read()[storageKey(scope)] ?? { configurationMode: 'auto', raw: '' };
}

export function saveCustomFragmentSettings(scope: CustomFragmentScope, value: CustomFragmentSettings): void {
  const settings = read();
  const key = storageKey(scope);
  // Delete before write: this table has no `updatedAt` (and should not gain one, since it
  // never enters the sync envelope), so insertion order is the only signal for which entry was
  // written last, and forward porting needs it to pick a candidate. Plain assignment would
  // leave an existing key in place, so the newest write could end up first in the sequence.
  delete settings[key];
  if (!(value.configurationMode === 'auto' && !value.raw.trim())) settings[key] = value;
  write(settings);
  if (scope.recoveryIdentity) clearCapabilityRejectionSetting(scope.recoveryIdentity, scope.owner, 'custom');
  publish(scope);
}

/**
 * Change notifications go out on a microtask rather than synchronously (matching the typed
 * preference table's `publish()`).
 *
 * A synchronous dispatch means subscriber `setState` calls run before the write function has
 * returned: the caller may be in the middle of a React render or event handler, so "write to
 * storage" expands into a re-render of another subtree right there on the stack. Forward
 * porting can write several owners in one pass, and each synchronous round would observe a
 * half-written snapshot. Deferring to a microtask guarantees subscribers read the finished table.
 */
function publish(scope: CustomFragmentScope): void {
  if (typeof window === 'undefined') return;
  queueMicrotask(() => window.dispatchEvent(new CustomEvent(CUSTOM_FRAGMENT_SETTINGS_EVENT, { detail: scope })));
}

/**
 * The three things the model options panel needs to know: whether this connection has an
 * editable schema for the owner, what risk tier the server assigns those fields, and whether
 * they are actually rewriting the request right now.
 *
 * The conditions have to match `resolveCustomFragments` (the outbound gate) one for one - a
 * panel claiming "the preferences above will not be sent" while they are being sent is the
 * hardest kind of false state to catch. So the same conditions are reused: official
 * controlDefinitions are present, or a relay generation profile exists, and the entry really
 * does go out on the wire.
 */
export function customFragmentOwnerFacts(input: {
  provider: Provider;
  model: AIModel;
  transportIdentity: string;
  owner: CustomFragmentOwner;
}): { hasSchema: boolean; riskTiers: string[]; isActive: boolean; isSelected: boolean; hasDraft: boolean } {
  const { provider, model, owner } = input;
  if (!isCustomFragmentEligible(provider)) {
    return { hasSchema: false, riskTiers: [], isActive: false, isSelected: false, hasDraft: false };
  }
  const runtime = getCapabilityRuntime();
  const definitions = runtime
    ? resolveCustomControlDefinitions(
        owner, model.capabilityControls?.[owner], runtime.controlDefinitions, runtime.sourceIndex,
      )
    : [];
  const relayExactGeneration = provider.kind === 'relay' && owner === 'generation'
    && Boolean(model.generationProfile);
  const hasSchema = definitions.length > 0 || relayExactGeneration;
  const settings = loadCustomFragmentSettings(
    customFragmentScope(provider, model, input.transportIdentity, owner),
  );
  const isSelected = settings.configurationMode === 'custom';
  return {
    hasSchema,
    riskTiers: customControlRiskTiers(definitions),
    // `isActive` answers "will this actually rewrite the current request". The panel uses it
    // to state that the preferences above will not be sent, so getting it wrong is a false
    // state and it must cover exactly the same set as the outbound gate.
    // The outbound gate fails closed for "custom selected but empty" instead of silently
    // falling back to auto, so "non-empty draft" is not one of its conditions: an empty draft
    // takes over the request just the same (and makes it fail). What is left is schema
    // reachable plus the user having set it to custom.
    isActive: hasSchema && isSelected,
    // `isSelected` answers "did the user set this to custom". The developer entry's tri-state
    // uses it, because when the server withdraws the schema the user still needs to see that
    // something was configured here and be able to switch it off.
    isSelected,
    hasDraft: settings.raw.trim().length > 0,
  };
}

/** Tri-state for the developer row under advanced settings. */
export type CustomFragmentEntryState = 'unsupported' | 'idle' | 'inUse';

export function customFragmentEntryState(input: {
  provider: Provider;
  model: AIModel | undefined;
  transportIdentity: string | undefined;
}): CustomFragmentEntryState {
  const { provider, model, transportIdentity } = input;
  // When identity cannot be resolved (a relay whose final route is not settled yet, say), the
  // whole row degrades to "unsupported": the entry does not lie by offering a page that
  // cannot write anything.
  if (!model || !transportIdentity) return 'unsupported';
  let reachable = false;
  let inUse = false;
  for (const owner of CUSTOM_FRAGMENT_OWNERS) {
    const facts = customFragmentOwnerFacts({ provider, model, transportIdentity, owner });
    if (facts.isSelected) inUse = true;
    // Existing content counts as reachable too: the schema is server-issued and can disappear
    // on a metadata refresh while the user's configuration stays behind. Hiding the entry when
    // the schema goes away would take away the only way to switch it off.
    if (facts.hasSchema || facts.isSelected || facts.hasDraft) reachable = true;
  }
  return inUse ? 'inUse' : reachable ? 'idle' : 'unsupported';
}

// --- Lazy forward porting across recipe versions (custom JSON) ---------------

/**
 * Whether two identities are different recipe versions of the same route. Same condition as on
 * the typed preference side: the transport must be identical and only `runtimeRevision` may
 * differ; a genuine protocol change is not ported.
 */
function isSameCustomFragmentLineage(current: string, candidate: string): boolean {
  if (current === candidate) return false;
  const left = decodeCapabilityTransportIdentity(current);
  const right = decodeCapabilityTransportIdentity(candidate);
  return left !== null && right !== null
    && left.finalTransport === right.finalTransport
    && left.runtimeRevision !== right.runtimeRevision;
}

/**
 * Forward porting for custom JSON. Typed preferences are a closed vocabulary and can be moved
 * across as-is, but what is moved here is hand-written fields that may not be valid under the
 * new recipe, so they are revalidated against it (the same `previewSafeCustomFragment` the
 * editor and the outbound compiler use).
 *
 * When revalidation fails the entry moves forward as `auto` with `raw` kept intact:
 * - staying `custom` fails closed, and the next message suddenly cannot be sent although the
 *   user changed nothing;
 * - dropping the draft decides for the user, and it may be thirty lines of JSON that took a
 *   long time to get right.
 * "Paused, draft kept" is the only outcome that neither decides for the user nor breaks the
 * experience: the editor still opens and edits, and writing valid content back re-enables it
 * automatically (the editor derives mode from content).
 *
 * Custom fields have no conversation scope here - the key is connection x model x transport x
 * owner - so there is only one level to port.
 *
 * Call this from discrete events only (panel opened, editor loaded, developer row refresh,
 * before send), never from a render path: it decodes the whole table and may write to disk.
 */
/**
 * A forward-porting write broadcasts an event, and subscribers (developer row, chip) call back
 * into forward porting when they refresh; this flag closes that loop explicitly within a single
 * round. Now that the broadcast is a microtask the flag is already released by then, and the
 * loop is stopped by forward porting's own idempotent short-circuit (`continue` when the target
 * already has a record, so no write and no broadcast) - keep both guards.
 */
let forwardPortingCustomFragments = false;

export function forwardPortCustomFragmentsIfNeeded(input: {
  provider: Provider;
  model: AIModel;
  transportIdentity: string;
}): void {
  if (typeof window === 'undefined') return;
  if (!isCustomFragmentEligible(input.provider)) return;
  if (decodeCapabilityTransportIdentity(input.transportIdentity) === null) return;
  // Writes broadcast `CUSTOM_FRAGMENT_SETTINGS_EVENT`, and subscribers (developer row, chip)
  // call back in here when they refresh - without closing that loop the first forward port
  // re-enters the whole cycle carrying a stale snapshot.
  if (forwardPortingCustomFragments) return;
  forwardPortingCustomFragments = true;
  try {
    forwardPortCustomFragments(input);
  } finally {
    forwardPortingCustomFragments = false;
  }
}


function forwardPortCustomFragments(input: {
  provider: Provider;
  model: AIModel;
  transportIdentity: string;
}): void {
  const stored = read();
  const runtime = getCapabilityRuntime();
  const generationProfile = input.provider.kind === 'relay'
    ? resolveGenerationProfileForModel(input.provider, input.model)
    : undefined;
  const keys = Object.keys(stored);
  for (const owner of CUSTOM_FRAGMENT_OWNERS) {
    const scope = customFragmentScope(input.provider, input.model, input.transportIdentity, owner);
    // Target already has a record: idempotent short-circuit. What the user expressed under the
    // current version (including a deliberate clear) always wins.
    if (stored[storageKey(scope)]) continue;
    // Insertion order is write order (`saveCustomFragmentSettings` deletes before writing), so
    // scanning backwards finds the entry written last.
    const candidateKey = [...keys].reverse().find((key) => {
      const parts = key.split(CUSTOM_FRAGMENT_KEY_SEPARATOR);
      return parts.length === 4 && parts[0] === scope.providerId && parts[1] === scope.modelId
        && parts[3] === owner && isSameCustomFragmentLineage(input.transportIdentity, parts[2] ?? '');
    });
    const candidate = candidateKey ? stored[candidateKey] : undefined;
    if (!candidate) continue;
    const staysCustom = candidate.configurationMode === 'custom'
      && revalidatesUnderCurrentSchema(candidate.raw, owner, input.model, runtime, generationProfile);
    // "Disabled with an empty draft" is the default state of this namespace, so porting it just
    // writes a record that is deleted again right away - and every write broadcasts an event,
    // which is a loop feeding itself.
    if (!staysCustom && !candidate.raw.trim()) continue;
    saveCustomFragmentSettings(scope, {
      configurationMode: staysCustom ? 'custom' : 'auto',
      raw: candidate.raw,
    });
  }
}

/** Whether this JSON still holds up under the current recipe. Same call as the editor's validation preview, so the rule is never written twice. */
function revalidatesUnderCurrentSchema(
  raw: string,
  owner: CustomFragmentOwner,
  model: AIModel,
  runtime: ReturnType<typeof getCapabilityRuntime>,
  generationProfile: ReturnType<typeof resolveGenerationProfileForModel>,
): boolean {
  if (!raw.trim()) return false;
  const definitions = runtime
    ? resolveCustomControlDefinitions(owner, model.capabilityControls?.[owner], runtime.controlDefinitions, runtime.sourceIndex)
    : [];
  const relayGenerationProfile = owner === 'generation' ? generationProfile : undefined;
  if (definitions.length === 0 && !relayGenerationProfile) return false;
  return previewSafeCustomFragment({
    raw,
    owner,
    generationProfile: relayGenerationProfile,
    recipes: [],
    intents: {},
    ...(definitions.length > 0
      ? { declaredOwners: Object.fromEntries(definitions.map((definition) => [definition.targetPointer, owner])) }
      : {}),
  }).accepted;
}

/**
 * Models enabled on this connection where at least one owner actually declares a field schema.
 * Only enabled models: a catalog model has to be enabled before it can be selected, so listing
 * it here would be a second dead end (same condition as the main panel).
 */
export function customFragmentSupportedModels(provider: Provider): AIModel[] {
  if (!isCustomFragmentEligible(provider)) return [];
  return provider.models.filter((candidate) => CUSTOM_FRAGMENT_OWNERS.some((owner) => customFragmentOwnerFacts({
    provider,
    model: candidate,
    transportIdentity: capabilityRuntimeIdentity(provider, candidate)?.transportIdentity ?? '',
    owner,
  }).hasSchema));
}

/**
 * Whether this connection has any editable custom-field schema for the current transport (any
 * owner counts).
 *
 * The `custom_only` path depends on it: if the server says "custom only" and not a single
 * schema can be parsed locally, sending the user into advanced settings only yields an
 * "unsupported" row - a dead end, which is worse than having no path at all.
 */
export function hasSafeCustomFragmentSchema(
  provider: Provider, model: AIModel, transportIdentity: string,
): boolean {
  return CUSTOM_FRAGMENT_OWNERS.some((owner) => customFragmentOwnerFacts({
    provider, model, transportIdentity, owner,
  }).hasSchema);
}

/** Final request boundary. Auto, unavailable Custom, and an empty Custom draft never emit raw. */
export function resolveCustomFragments(input: {
  provider: Provider;
  model: AIModel;
  transportIdentity: string;
  allow: boolean;
  runtime?: {
    controlDefinitions: Readonly<Record<string, unknown>>;
    sourceIndex: Readonly<Record<string, unknown>>;
  } | null;
}): Partial<Record<CustomFragmentOwner, { raw: string }>> | undefined {
  // The only condition for going out on the wire is `configurationMode === 'custom'`, plus a
  // reachable schema and a non-empty draft. No global switch may be multiplied in here.
  if (!input.allow || !isCustomFragmentEligible(input.provider)) return undefined;
  const fragments: Partial<Record<CustomFragmentOwner, { raw: string }>> = {};
  const recoveryIdentity = capabilityRuntimeIdentity(input.provider, input.model);
  for (const owner of CUSTOM_FRAGMENT_OWNERS) {
    if (recoveryIdentity && capabilityRejectionIsDormant({
      connectionId: recoveryIdentity.providerId,
      canonicalModelId: recoveryIdentity.canonicalModelId,
      finalTransport: recoveryIdentity.finalTransport,
      runtimeRevision: recoveryIdentity.runtimeRevision,
    }, owner, 'custom')) continue;
    const serverRefAvailable = Boolean(input.runtime && resolveCustomControlDefinitions(
      owner,
      input.model.capabilityControls?.[owner],
      input.runtime.controlDefinitions,
      input.runtime.sourceIndex,
    ).length > 0);
    const relayExactGenerationAvailable = input.provider.kind === 'relay' && owner === 'generation'
      && Boolean(input.model.generationProfile);
    if (!serverRefAvailable && !relayExactGenerationAvailable) continue;
    const scope = customFragmentScope(input.provider, input.model, input.transportIdentity, owner);
    const settings = loadCustomFragmentSettings(scope);
    if (settings.configurationMode !== 'custom') continue;
    // "Custom selected but empty" is not silently downgraded to auto, and storage is never
    // rewritten at the send boundary.
    //
    // Both would be wrong: the editor shows a warning that messages using the control will fail
    // to send, while a downgraded request would go out anyway - the UI would be lying - and the
    // send path would quietly change configuration the user never chose. The value is handed to
    // the compiler as-is and fails closed there (`compileSafeCustomFragment` rejects empty or
    // invalid JSON, and dispatch throws).
    fragments[owner] = { raw: settings.raw };
  }
  return Object.keys(fragments).length > 0 ? fragments : undefined;
}
