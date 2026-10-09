import type { AIModel, Provider } from '@oriveo/shared';
import { assertAdditionalBodyAccepted, validateAdditionalBody } from '@oriveo/core/providers/request-builders/additional-body';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { takeLegacyGenerationFragments } from './custom-fragment-settings';
import { readPartitionedStore, writePartitionedStore } from '../../infra/storage/partitioned-local-store';

/**
 * Additional request body: a JSON object the user writes by hand, merged into the request body as
 * the very last step.
 *
 * Stored on this device only, partitioned by uid (`oriveo.{uid}.…`): it never enters the sync
 * envelope, backup exports, telemetry or diagnostics, because the content may carry business data
 * (same boundary as the legacy custom request fields). Another account cannot read the previous
 * account's record, and sign-out clears it together with the other partitioned keys.
 *
 * Scope = connection x model x conversation (or the model default); transport and recipe version are
 * not part of it. The content is stored separately from the "send with request" switch, so turning
 * the switch off keeps the content and only stops it from being sent.
 */
const STORAGE_KEY = 'local-additional-body.v1';
export const ADDITIONAL_BODY_SETTINGS_EVENT = 'oriveo:additional-body-settings';

/** The key separator must be a character that can never appear in an id (same as custom-fragment-settings); always written as an escape in source. */
const KEY_SEPARATOR = '\u0000';

export type AdditionalBodyScope = {
  connectionId: string;
  modelId: string;
  /** Omitted = the model-default record. */
  conversationId?: string;
};

export type AdditionalBodyRecord = {
  raw: string;
  /** The "send with request" switch. */
  enabled: boolean;
  updatedAt: number;
};

function storageKey(scope: AdditionalBodyScope): string {
  return [scope.connectionId, scope.modelId, scope.conversationId ?? ''].join(KEY_SEPARATOR);
}

function parseKey(key: string): AdditionalBodyScope | null {
  const parts = key.split(KEY_SEPARATOR);
  if (parts.length !== 3 || !parts[0] || !parts[1]) return null;
  return { connectionId: parts[0], modelId: parts[1], ...(parts[2] ? { conversationId: parts[2] } : {}) };
}

function isRecord(value: unknown): value is AdditionalBodyRecord {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return typeof record.raw === 'string' && typeof record.enabled === 'boolean' && typeof record.updatedAt === 'number';
}

function readRaw(): Record<string, AdditionalBodyRecord> {
  try {
    const value: unknown = JSON.parse(readPartitionedStore(STORAGE_KEY) ?? '{}');
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    return Object.fromEntries(Object.entries(value).filter((entry): entry is [string, AdditionalBodyRecord] => isRecord(entry[1])));
  } catch { return {}; }
}

function write(value: Record<string, AdditionalBodyRecord>): void {
  writePartitionedStore(STORAGE_KEY, JSON.stringify(value));
}

/** Read entry point: lazily migrates the legacy generation custom fields first, then reads this table. */
function read(): Record<string, AdditionalBodyRecord> {
  migrateLegacyGenerationFragments();
  return readRaw();
}

/**
 * Legacy generation owner custom fields -> additional request body (the model-default record).
 *
 * - When one connection x model has a record under several transport identities, only the most
 *   recently modified one is kept (the old table's insertion order is write order, so the last is
 *   the newest); the rest are dropped.
 * - Records that were being sent and are valid under the new rules keep being sent; disabled or
 *   invalid ones (truncated JSON, protected fields) are kept as drafts and not sent by default.
 * - An existing target record is never overwritten (it reflects what the user set in the new entry).
 * - Legacy records are deleted once moved, so running it again has no effect. No marker key is used:
 *   bare-key leftovers inherited later by the first real account are moved on the next read too.
 */
export function migrateLegacyGenerationFragments(): void {
  if (typeof window === 'undefined') return;
  const legacy = takeLegacyGenerationFragments();
  if (legacy.length === 0) return;
  const latest = new Map<string, (typeof legacy)[number]>();
  for (const entry of legacy) {
    const key = storageKey({ connectionId: entry.providerId, modelId: entry.modelId });
    latest.delete(key);
    latest.set(key, entry);
  }
  const settings = readRaw();
  let changed = false;
  const now = Date.now();
  for (const [key, entry] of latest) {
    if (!entry.providerId || !entry.modelId || settings[key] || !entry.raw.trim()) continue;
    const validation = validateAdditionalBody(entry.raw);
    settings[key] = {
      raw: entry.raw,
      enabled: entry.configurationMode === 'custom' && validation.accepted,
      updatedAt: now,
    };
    changed = true;
  }
  if (changed) write(settings);
}

export function additionalBodyScope(provider: Provider, model: AIModel, conversationId?: string | null): AdditionalBodyScope {
  return { connectionId: provider.id, modelId: model.id, ...(conversationId ? { conversationId } : {}) };
}

export function loadAdditionalBody(scope: AdditionalBodyScope): AdditionalBodyRecord | null {
  return read()[storageKey(scope)] ?? null;
}

/** The record in effect right now: the conversation-level record if there is one, otherwise the model default. */
export function resolveEffectiveAdditionalBody(scope: AdditionalBodyScope): AdditionalBodyRecord | null {
  const settings = read();
  if (scope.conversationId) {
    const conversation = settings[storageKey(scope)];
    if (conversation) return conversation;
  }
  return settings[storageKey({ connectionId: scope.connectionId, modelId: scope.modelId })] ?? null;
}

/** For sending: returns the raw text only when the effective record is enabled and non-empty; validation is left to the request-body boundary (a local rejection sends no request). */
export function resolveAdditionalBodyForSend(input: {
  provider: Provider;
  model: AIModel;
  conversationId?: string | null;
}): { raw: string } | undefined {
  const record = resolveEffectiveAdditionalBody(additionalBodyScope(input.provider, input.model, input.conversationId));
  if (!record?.enabled || !record.raw.trim()) return undefined;
  return { raw: record.raw };
}

/**
 * Attaches the currently effective additional body to the final outbound options. It is validated
 * first with the same pure function, and an invalid body throws `AdditionalBodyRejectedError`
 * (no request is sent and no connection fault is recorded). The stream route validates again as a
 * second check.
 */
export function withAdditionalBody(
  options: StreamOptions | undefined,
  input: { provider: Provider; model: AIModel; conversationId?: string | null; omit?: boolean },
): StreamOptions | undefined {
  // "Retry without the additional body" omits it for this one send only; the stored content and the switch stay untouched.
  if (input.omit) return options;
  const additionalBody = resolveAdditionalBodyForSend(input);
  if (!additionalBody) return options;
  assertAdditionalBodyAccepted(additionalBody);
  return { ...(options ?? {}), additionalBody };
}

/**
 * Stores exactly what it is given: a conversation-level record with empty content and the switch
 * off is kept too, because it expresses "written in the model default, but not sent in this
 * conversation". Only an explicit clear (null) deletes the record and falls back to the layer below.
 */
export function saveAdditionalBody(scope: AdditionalBodyScope, value: { raw: string; enabled: boolean } | null): void {
  const settings = read();
  const key = storageKey(scope);
  if (value === null) delete settings[key];
  else settings[key] = { raw: value.raw, enabled: value.enabled, updatedAt: Date.now() };
  write(settings);
  publish(scope);
}

/**
 * Draft conversation -> real conversation: the first outbound message reads the real conversation
 * id, so the record under the draft has to move over at the moment the conversation is created.
 * If the target already has a record, the target wins and the draft's record is discarded.
 */
export function migrateAdditionalBodySession(input: {
  connectionId: string;
  modelId: string;
  fromConversationId: string;
  toConversationId: string;
}): void {
  if (input.fromConversationId === input.toConversationId) return;
  const settings = read();
  const fromKey = storageKey({ connectionId: input.connectionId, modelId: input.modelId, conversationId: input.fromConversationId });
  const record = settings[fromKey];
  if (!record) return;
  const to = { connectionId: input.connectionId, modelId: input.modelId, conversationId: input.toConversationId };
  const toKey = storageKey(to);
  if (!settings[toKey]) settings[toKey] = record;
  delete settings[fromKey];
  write(settings);
  publish(to);
}

/** Call together with `removeGenerationParameterScopes` when a connection, model or conversation is deleted. */
export function removeAdditionalBodyScopes(input: { providerId?: string; modelId?: string; conversationId?: string }): void {
  if (!input.providerId && !input.modelId && !input.conversationId) return;
  const settings = read();
  let changed = false;
  for (const key of Object.keys(settings)) {
    const scope = parseKey(key);
    if (!scope) continue;
    if (input.providerId && scope.connectionId !== input.providerId) continue;
    if (input.modelId && scope.modelId !== input.modelId) continue;
    if (input.conversationId && scope.conversationId !== input.conversationId) continue;
    delete settings[key];
    changed = true;
  }
  if (changed) write(settings);
}

/** Change notifications go through a microtask (same reason as custom-fragment-settings: subscribers always read a fully written table). */
function publish(scope: AdditionalBodyScope): void {
  if (typeof window === 'undefined') return;
  queueMicrotask(() => window.dispatchEvent(new CustomEvent(ADDITIONAL_BODY_SETTINGS_EVENT, { detail: scope })));
}
