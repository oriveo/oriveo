/** Deterministic rejection, explicit resend and the local dormant cache. */
export type RecoverySource = 'provider_recipe' | 'custom';
export type RecoveryOwner = 'web' | 'reasoning' | 'generation';
export type RecoveryAction = 'surface_error' | 'user_confirmed_resend_without_located_setting';

export interface CapabilityRecoveryDescriptor {
  version: 1;
  action: 'user_confirmed_resend_without_located_setting';
  source: RecoverySource;
  owners: RecoveryOwner[];
  locatedPointers: string[];
  recipeRef?: string;
}

export interface CapabilityRecoveryIdentity {
  connectionId: string;
  canonicalModelId: string;
  finalTransport: string;
  runtimeRevision: string;
}

export type CapabilityRecipeOmission = {
  recipeRef: string;
  locatedPointers: string[];
};

export type CapabilityRecoveryRetryOptions = {
  excludeCustomFragmentOwners?: RecoveryOwner[];
  capabilityRecipeOmissions?: CapabilityRecipeOmission[];
  capabilityRecipeResendOwners?: RecoveryOwner[];
};

type LocatorRule = { owner: RecoveryOwner; status: 400; pointers: string[]; errorFields: Record<string, string> };

type RecoveryInput = {
  status: number;
  preToken: boolean;
  streamStarted: boolean;
  sideEffects: boolean;
  automaticRetryCount: number;
  source: RecoverySource;
  customOwners?: RecoveryOwner[];
  customAppliedPointers?: Partial<Record<RecoveryOwner, string[]>>;
  recipeRefs?: string[];
  recipes?: unknown;
  structuredError?: unknown;
};

const CACHE_KEY = 'oriveo.capability-rejection-cache.v1';
export const CAPABILITY_RECOVERY_HEADER = 'X-Oriveo-Capability-Recovery';
const TTL_MS = 24 * 60 * 60 * 1000;
const MAX_ENTRIES = 200;
type CacheEntry = CapabilityRecoveryIdentity & {
  owner: RecoveryOwner;
  source: RecoverySource;
  recipeRef?: string;
  locatedPointers: string[];
  rejectedAt: number;
  expiresAt: number;
};

export interface ToolCallRecoveryIdentity {
  accountId: string;
  connectionId: string;
  authMode: string;
  canonicalModelId: string;
  finalTransport: string;
}

export interface ToolCallRejectionContext {
  status: number;
  structuredError: unknown;
}

const TOOL_CALL_CACHE_KEY = 'oriveo.tool-call-rejection-cache.v1';
const TOOL_CALL_MAX_ENTRIES = 500;
type ToolCallCacheEntry = ToolCallRecoveryIdentity & {
  supported: false;
  observedAt: number;
};

// Kept word for word in sync with the runtime constants in the shared fixture, with 422 additionally
// excluded: it usually means request entity validation failed, which says nothing about whether the
// model supports tools.
const TOOL_CALL_SUBJECT_PATTERNS = [
  /\btools?\b/i,
  /\btool_calls?\b/i,
  /\btool_choice\b/i,
  /\bfunctions?\b/i,
  /\bfunction[_ ]call(ing)?\b/i,
] as const;
const TOOL_CALL_VERDICT_PATTERNS = [
  /\bunsupported\b/i,
  /\bnot (currently )?support(ed)?\b/i,
  /\bdoes(n't| not) support\b/i,
  /\binvalid\b/i,
  /\bunknown\b/i,
  /\bunrecognized\b/i,
  /\bunexpected\b/i,
  /\bextra (inputs?|fields?|parameters?)\b/i,
  /\bnot (allowed|permitted|available)\b/i,
  /\bnot a valid\b/i,
] as const;

/** Compatibility result for callers that need only the action. Never returns an automatic action. */
export function decideCapabilityRecovery(input: RecoveryInput, definitions: unknown): RecoveryAction {
  return locateCapabilityRecovery(input, definitions)?.action ?? 'surface_error';
}

/**
 * Admits only an actual custom fragment or a same-envelope reviewed structured
 * locator. Error prose is never scanned for a parameter name.
 */
export function locateCapabilityRecovery(input: RecoveryInput, definitions: unknown): CapabilityRecoveryDescriptor | null {
  if (input.status !== 400 || !input.preToken || input.streamStarted || input.sideEffects || input.automaticRetryCount !== 0) return null;
  if (input.source === 'custom') {
    const param = isRecord(input.structuredError) ? readJsonPointer(input.structuredError, '/error/param') : undefined;
    const pointer = typeof param === 'string' ? structuredParamPointer(param) : null;
    if (!pointer || !isRecord(input.customAppliedPointers)) return null;
    const matches = (['web', 'reasoning', 'generation'] as const).flatMap((owner) => {
      const pointers = input.customAppliedPointers?.[owner];
      return Array.isArray(pointers) && pointers.every(isSafePointer) && pointers.includes(pointer)
        ? [{ owner, pointer }]
        : [];
    });
    return matches.length === 1 ? {
      version: 1,
      action: 'user_confirmed_resend_without_located_setting',
      source: 'custom',
      owners: [matches[0]!.owner],
      locatedPointers: [matches[0]!.pointer],
    } : null;
  }
  if (!isRecord(definitions) || !isRecord(input.recipes) || !isRecord(input.structuredError)) return null;
  for (const recipeRef of input.recipeRefs ?? []) {
    const recipe = input.recipes[recipeRef];
    if (!isRecord(recipe) || typeof recipe.errorRecoveryRef !== 'string' || !isOwner(recipe.capability)
      || !isRecord(recipe.transport) || typeof recipe.transport.protocol !== 'string'
      || typeof recipe.responseParserKind !== 'string' || !Array.isArray(recipe.requestOps)) continue;
    const definition = definitions[recipe.errorRecoveryRef];
    if (!isRecord(definition) || definition.capability !== recipe.capability
      || definition.protocol !== recipe.transport.protocol || definition.responseParserKind !== recipe.responseParserKind
      || !Array.isArray(definition.locatorRules)) continue;
    const ownedPointers = recipe.requestOps.flatMap((operation) => isRecord(operation) && isSafePointer(operation.pointer) ? [operation.pointer] : []);
    for (const value of definition.locatorRules) {
      const rule = parseLocatorRule(value);
      if (!rule || input.status !== rule.status || rule.owner !== recipe.capability
        || !rule.pointers.every((pointer) => ownedPointers.includes(pointer))
        || !Object.entries(rule.errorFields).every(([pointer, expected]) => readJsonPointer(input.structuredError, pointer) === expected)) continue;
      return {
        version: 1,
        action: 'user_confirmed_resend_without_located_setting',
        source: 'provider_recipe',
        owners: [rule.owner],
        locatedPointers: [...rule.pointers],
        recipeRef,
      };
    }
  }
  return null;
}

export function encodeCapabilityRecoveryDescriptor(descriptor: CapabilityRecoveryDescriptor): string {
  return base64Url(JSON.stringify(descriptor));
}

export function decodeCapabilityRecoveryDescriptor(value: string | null): CapabilityRecoveryDescriptor | null {
  if (!value || value.length > 4_096) return null;
  try {
    const parsed = JSON.parse(fromBase64Url(value)) as unknown;
    if (!isRecord(parsed) || parsed.version !== 1 || parsed.action !== 'user_confirmed_resend_without_located_setting'
      || (parsed.source !== 'provider_recipe' && parsed.source !== 'custom') || !Array.isArray(parsed.owners)
      || !Array.isArray(parsed.locatedPointers)) return null;
    const owners = uniqueOwners(parsed.owners);
    const locatedPointers = parsed.locatedPointers.filter(isSafePointer);
    if (!owners.length || locatedPointers.length !== parsed.locatedPointers.length) return null;
    if (parsed.source === 'provider_recipe' && (typeof parsed.recipeRef !== 'string' || !parsed.recipeRef)) return null;
    return {
      version: 1,
      action: 'user_confirmed_resend_without_located_setting',
      source: parsed.source,
      owners,
      locatedPointers,
      ...(typeof parsed.recipeRef === 'string' ? { recipeRef: parsed.recipeRef } : {}),
    };
  } catch {
    return null;
  }
}

/** Writes only a descriptor already admitted by the deterministic gate. */
export function recordCapabilityRejection(
  identity: CapabilityRecoveryIdentity,
  descriptor: CapabilityRecoveryDescriptor,
  now = Date.now(),
): void {
  if (!validIdentity(identity) || typeof localStorage === 'undefined') return;
  const current = readCache(now);
  for (const owner of descriptor.owners) {
    const entry: CacheEntry = {
      ...identity,
      owner,
      source: descriptor.source,
      ...(descriptor.recipeRef ? { recipeRef: descriptor.recipeRef } : {}),
      locatedPointers: descriptor.locatedPointers,
      rejectedAt: now,
      expiresAt: now + TTL_MS,
    };
    current.set(cacheKey(entry), entry);
  }
  const newest = [...current.values()].sort((left, right) => right.rejectedAt - left.rejectedAt).slice(0, MAX_ENTRIES);
  try { localStorage.setItem(CACHE_KEY, JSON.stringify(newest)); } catch { /* quota is non-fatal */ }
}

export function capabilityRejectionIsDormant(
  identity: CapabilityRecoveryIdentity,
  owner: RecoveryOwner,
  source: RecoverySource,
  now = Date.now(),
): boolean {
  if (!validIdentity(identity)) return false;
  return [...readCache(now).values()].some((entry) => entry.connectionId === identity.connectionId
    && entry.canonicalModelId === identity.canonicalModelId
    && entry.finalTransport === identity.finalTransport
    && entry.runtimeRevision === identity.runtimeRevision
    && entry.owner === owner
    && entry.source === source);
}

/**
 * A persisted message can outlive the connection/model/runtime that produced it.
 * The CTA is therefore armed only while the exact rejected setting still exists
 * in the cache partition for the identity that will dispatch the retry.
 */
export function capabilityRecoveryDescriptorIsCurrent(
  identity: CapabilityRecoveryIdentity,
  descriptor: CapabilityRecoveryDescriptor,
  now = Date.now(),
): boolean {
  if (!validIdentity(identity) || !validDescriptor(descriptor)) return false;
  const expectedPointers = canonicalPointers(descriptor.locatedPointers);
  const entries = [...readCache(now).values()];
  return descriptor.owners.every((owner) => entries.some((entry) => entry.connectionId === identity.connectionId
    && entry.canonicalModelId === identity.canonicalModelId
    && entry.finalTransport === identity.finalTransport
    && entry.runtimeRevision === identity.runtimeRevision
    && entry.owner === owner
    && entry.source === descriptor.source
    && entry.recipeRef === descriptor.recipeRef
    && canonicalPointers(entry.locatedPointers) === expectedPointers));
}

/** Fail-closed CTA boundary: a stale card never degrades into an ordinary retry. */
export function invokeCapabilityRecoveryRetry(
  identity: CapabilityRecoveryIdentity,
  descriptor: CapabilityRecoveryDescriptor,
  retry: (options: CapabilityRecoveryRetryOptions) => unknown,
  now = Date.now(),
): boolean {
  if (!capabilityRecoveryDescriptorIsCurrent(identity, descriptor, now)) return false;
  if (descriptor.source === 'custom') {
    retry({ excludeCustomFragmentOwners: [...descriptor.owners] });
  } else {
    retry({
      capabilityRecipeOmissions: [{ recipeRef: descriptor.recipeRef!, locatedPointers: [...descriptor.locatedPointers] }],
      capabilityRecipeResendOwners: [...descriptor.owners],
    });
  }
  return true;
}

/** Exact recipe settings learned from deterministic 400s for this runtime identity. */
export function capabilityRecipeOmissions(
  identity: CapabilityRecoveryIdentity,
  now = Date.now(),
): CapabilityRecipeOmission[] {
  if (!validIdentity(identity)) return [];
  const unique = new Map<string, CapabilityRecipeOmission>();
  for (const entry of readCache(now).values()) {
    if (entry.source !== 'provider_recipe' || typeof entry.recipeRef !== 'string' || entry.locatedPointers.length === 0
      || entry.connectionId !== identity.connectionId || entry.canonicalModelId !== identity.canonicalModelId
      || entry.finalTransport !== identity.finalTransport || entry.runtimeRevision !== identity.runtimeRevision) continue;
    const omission = { recipeRef: entry.recipeRef, locatedPointers: [...entry.locatedPointers].sort() };
    unique.set(recipeSettingIdentity(omission.recipeRef, omission.locatedPointers), omission);
  }
  return [...unique.values()];
}

export function clearCapabilityRejectionsForConnection(connectionId: string): void {
  if (typeof localStorage === 'undefined') return;
  const retained = [...readCache(Date.now()).values()].filter((entry) => entry.connectionId !== connectionId);
  try { localStorage.setItem(CACHE_KEY, JSON.stringify(retained)); } catch { /* quota is non-fatal */ }
}

/** Explicit reconfirmation of one source/owner leaves every other cache entry intact. */
export function clearCapabilityRejectionSetting(
  identity: CapabilityRecoveryIdentity,
  owner: RecoveryOwner,
  source: RecoverySource,
): void {
  if (!validIdentity(identity) || typeof localStorage === 'undefined') return;
  const retained = [...readCache(Date.now()).values()].filter((entry) => !(entry.connectionId === identity.connectionId
    && entry.canonicalModelId === identity.canonicalModelId
    && entry.finalTransport === identity.finalTransport
    && entry.runtimeRevision === identity.runtimeRevision
    && entry.owner === owner
    && entry.source === source));
  try { localStorage.setItem(CACHE_KEY, JSON.stringify(retained)); } catch { /* quota is non-fatal */ }
}

/**
 * Admits only a structured, pre-stream HTTP rejection whose body independently
 * identifies both the tool field and an unsupported/invalid verdict. Ordinary
 * error prose and ambiguous validation failures remain fail-open.
 */
export function isDeterministicToolCallUnsupported(
  context: unknown,
): context is ToolCallRejectionContext {
  if (!isRecord(context) || typeof context.status !== 'number') return false;
  if (context.status < 400 || context.status > 499
    || [401, 402, 403, 407, 408, 422, 429].includes(context.status)
    || !('structuredError' in context)
    || !isRecordOrArray(context.structuredError)) return false;
  let body: string;
  try {
    body = JSON.stringify(context.structuredError);
  } catch {
    return false;
  }
  return TOOL_CALL_SUBJECT_PATTERNS.some((pattern) => pattern.test(body))
    && TOOL_CALL_VERDICT_PATTERNS.some((pattern) => pattern.test(body));
}

/** Missing/unknown identities are deliberately not cacheable. */
export function toolCallSupportIsRememberedFalse(
  identity: ToolCallRecoveryIdentity,
): boolean {
  if (!validToolCallIdentity(identity)) return false;
  return readToolCallCache().has(toolCallCacheKey(identity));
}

/** Called only after the explicit no-tools resend has completed successfully. */
export function recordToolCallSupportFalse(
  identity: ToolCallRecoveryIdentity,
  now = Date.now(),
): void {
  if (!validToolCallIdentity(identity) || typeof localStorage === 'undefined') return;
  const current = readToolCallCache();
  const entry: ToolCallCacheEntry = { ...identity, supported: false, observedAt: now };
  current.set(toolCallCacheKey(entry), entry);
  const newest = [...current.values()]
    .sort((left, right) => right.observedAt - left.observedAt)
    .slice(0, TOOL_CALL_MAX_ENTRIES);
  try { localStorage.setItem(TOOL_CALL_CACHE_KEY, JSON.stringify(newest)); } catch { /* quota is non-fatal */ }
}

/** Connection resync/deletion and any credential/endpoint/model mutation invalidate D5 observations. */
export function clearToolCallMemoryForConnection(
  accountId: string,
  connectionId: string,
): void {
  if (!validIdentityPart(accountId) || !validIdentityPart(connectionId)
    || typeof localStorage === 'undefined') return;
  const retained = [...readToolCallCache().values()].filter((entry) => !(
    entry.accountId === accountId && entry.connectionId === connectionId
  ));
  try { localStorage.setItem(TOOL_CALL_CACHE_KEY, JSON.stringify(retained)); } catch { /* quota is non-fatal */ }
}

function readToolCallCache(): Map<string, ToolCallCacheEntry> {
  const output = new Map<string, ToolCallCacheEntry>();
  if (typeof localStorage === 'undefined') return output;
  try {
    const raw = JSON.parse(localStorage.getItem(TOOL_CALL_CACHE_KEY) ?? '[]') as unknown;
    if (!Array.isArray(raw)) return output;
    for (const value of raw) {
      if (!isToolCallCacheEntry(value)) continue;
      output.set(toolCallCacheKey(value), value);
    }
  } catch { /* malformed local state is ignored */ }
  return output;
}

function toolCallCacheKey(value: ToolCallRecoveryIdentity): string {
  return [value.accountId, value.connectionId, value.authMode, value.canonicalModelId, value.finalTransport].join('\u0000');
}

function validToolCallIdentity(value: ToolCallRecoveryIdentity): boolean {
  return [value.accountId, value.connectionId, value.authMode, value.canonicalModelId, value.finalTransport]
    .every(validIdentityPart)
    && value.authMode !== 'unknown'
    && value.authMode !== 'auto'
    && value.finalTransport !== 'unknown';
}

function isToolCallCacheEntry(value: unknown): value is ToolCallCacheEntry {
  return isRecord(value) && value.supported === false && typeof value.observedAt === 'number'
    && typeof value.authMode === 'string'
    && typeof value.accountId === 'string' && typeof value.connectionId === 'string'
    && typeof value.canonicalModelId === 'string' && typeof value.finalTransport === 'string'
    && validToolCallIdentity(value as unknown as ToolCallRecoveryIdentity);
}

function validIdentityPart(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 512;
}

function isRecordOrArray(value: unknown): value is Record<string, unknown> | unknown[] {
  return isRecord(value) || Array.isArray(value);
}

function readCache(now: number): Map<string, CacheEntry> {
  const output = new Map<string, CacheEntry>();
  if (typeof localStorage === 'undefined') return output;
  try {
    const raw = JSON.parse(localStorage.getItem(CACHE_KEY) ?? '[]') as unknown;
    if (!Array.isArray(raw)) return output;
    for (const value of raw) {
      if (!isCacheEntry(value) || value.expiresAt <= now) continue;
      output.set(cacheKey(value), value);
    }
  } catch { /* malformed local state is dormant/ignored */ }
  return output;
}

function validDescriptor(value: CapabilityRecoveryDescriptor): boolean {
  if (value.version !== 1 || value.action !== 'user_confirmed_resend_without_located_setting'
    || (value.source !== 'provider_recipe' && value.source !== 'custom')
    || uniqueOwners(value.owners).length !== value.owners.length || value.owners.length === 0
    || value.locatedPointers.length === 0 || !value.locatedPointers.every(isSafePointer)) return false;
  return value.source === 'provider_recipe'
    ? typeof value.recipeRef === 'string' && value.recipeRef.length > 0
    : value.recipeRef === undefined;
}

function canonicalPointers(values: readonly string[]): string {
  return [...new Set(values)].sort().join('\u0000');
}

function cacheKey(value: CapabilityRecoveryIdentity & {
  owner: RecoveryOwner;
  source: RecoverySource;
  recipeRef?: string;
  locatedPointers?: string[];
}): string {
  const settingIdentity = value.source === 'provider_recipe'
    ? recipeSettingIdentity(value.recipeRef ?? '', value.locatedPointers ?? [])
    : `custom:${value.owner}`;
  return [value.connectionId, value.canonicalModelId, value.finalTransport, value.runtimeRevision, value.source, value.owner, settingIdentity].join('\u0000');
}
function recipeSettingIdentity(recipeRef: string, pointers: readonly string[]): string {
  return `${recipeRef}:${[...pointers].sort().join(',')}`;
}
function validIdentity(value: CapabilityRecoveryIdentity): boolean {
  return [value.connectionId, value.canonicalModelId, value.finalTransport, value.runtimeRevision]
    .every((part) => typeof part === 'string' && part.length > 0 && part.length <= 512);
}
function isCacheEntry(value: unknown): value is CacheEntry {
  return isRecord(value) && typeof value.connectionId === 'string' && typeof value.canonicalModelId === 'string'
    && typeof value.finalTransport === 'string' && typeof value.runtimeRevision === 'string' && isOwner(value.owner)
    && (value.source === 'provider_recipe' || value.source === 'custom') && Array.isArray(value.locatedPointers)
    && value.locatedPointers.every(isSafePointer)
    && (value.source !== 'provider_recipe' || (typeof value.recipeRef === 'string' && value.recipeRef.length > 0 && value.locatedPointers.length > 0))
    && typeof value.rejectedAt === 'number' && typeof value.expiresAt === 'number';
}
function parseLocatorRule(value: unknown): LocatorRule | null {
  if (!isRecord(value) || !isOwner(value.owner) || value.status !== 400
    || !Array.isArray(value.pointers) || value.pointers.length === 0 || !value.pointers.every(isSafePointer)
    || !isRecord(value.errorFields) || Object.keys(value.errorFields).length === 0
    || !Object.entries(value.errorFields).every(([pointer, expected]) => isSafePointer(pointer) && typeof expected === 'string' && expected.length > 0)) return null;
  return value as unknown as LocatorRule;
}
function readJsonPointer(value: unknown, pointer: string): unknown {
  if (pointer === '') return value;
  let current = value;
  for (const segment of pointer.slice(1).split('/').map((item) => item.replace(/~1/g, '/').replace(/~0/g, '~'))) {
    if (!isRecord(current) || !(segment in current)) return undefined;
    current = current[segment];
  }
  return current;
}
function structuredParamPointer(value: string): string | null {
  const trimmed = value.trim();
  if (isSafePointer(trimmed) && trimmed !== '') return trimmed;
  if (!/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(trimmed)) return null;
  return `/${trimmed.split('.').join('/')}`;
}
function uniqueOwners(values: unknown[]): RecoveryOwner[] { return [...new Set(values.filter(isOwner))]; }
function isOwner(value: unknown): value is RecoveryOwner { return value === 'web' || value === 'reasoning' || value === 'generation'; }
function isSafePointer(value: unknown): value is string { return typeof value === 'string' && value.length <= 256 && (value === '' || value.startsWith('/')); }
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value !== null && !Array.isArray(value); }
function base64Url(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}
function fromBase64Url(value: string): string {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4);
  const binary = atob(padded);
  return new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
}
