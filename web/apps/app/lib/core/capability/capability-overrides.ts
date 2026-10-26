/**
 * Normalization of Relay / custom-endpoint input capability overrides (deltas).
 *
 * Only the three input keys can be overridden, op is add / remove; keys the user never touched follow the server (effective null).
 * Legacy relayCapabilityOverrides image / file entries with source=user are migrated once into deltas (setAt = now, baseVerdict = the server state of that key, unknown when absent);
 * source=tested is a probe result rather than a user choice, so it is not migrated and stays in the legacy field; other legacy keys are untouched. Stored new deltas win over the legacy field.
 * Official connections carry no overrides. Bad entries are dropped one by one. Fixture: `shared/test-fixtures/capability/overrides.v1.json`.
 */
import type { AIModel, RelayCapabilityOverrides } from '@oriveo/shared';

export type InputCapabilityKey = 'vision_input' | 'file_input' | 'video_input';
export const INPUT_CAPABILITY_KEYS: readonly InputCapabilityKey[] = ['vision_input', 'file_input', 'video_input'];

export type CapabilityOverrideOp = 'add' | 'remove';

export interface CapabilityOverrideEntry {
  op: CapabilityOverrideOp;
  /** ISO timestamp. */
  setAt: string;
  /** The server state of this key when the user set the override. */
  baseVerdict: string;
}

export type CapabilityOverrides = Partial<Record<InputCapabilityKey, CapabilityOverrideEntry>>;

export type CapabilityOverrideConnection = 'relay' | 'custom' | 'official';

export interface NormalizeCapabilityOverridesInput {
  connection: CapabilityOverrideConnection | string;
  legacy: RelayCapabilityOverrides | Record<string, unknown> | null | undefined;
  /** Locally stored deltas; the source is untrusted, so each entry is validated. */
  stored: unknown;
  /** The server state of each input key (a missing key = unknown). */
  serverVerdict: Partial<Record<string, string>> | null | undefined;
  /** ISO timestamp. */
  now: string;
}

export interface NormalizedCapabilityOverrides {
  capabilityOverrides: CapabilityOverrides;
  /** Keys still left in the legacy field after migration (in the legacy field order). */
  legacyKept: string[];
  effective: Record<InputCapabilityKey, CapabilityOverrideOp | null>;
}

/** Migratable keys in the legacy field -> new input keys. */
const LEGACY_INPUT_KEYS: Readonly<Record<string, InputCapabilityKey>> = {
  image: 'vision_input',
  file: 'file_input',
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function isInputCapabilityKey(key: string): key is InputCapabilityKey {
  return (INPUT_CAPABILITY_KEYS as readonly string[]).includes(key);
}

function parseEntry(value: unknown): CapabilityOverrideEntry | null {
  if (!isRecord(value)) return null;
  const { op, setAt, baseVerdict } = value;
  if (op !== 'add' && op !== 'remove') return null;
  if (typeof setAt !== 'string' || setAt === '' || Number.isNaN(Date.parse(setAt))) return null;
  if (typeof baseVerdict !== 'string' || baseVerdict === '') return null;
  return { op, setAt, baseVerdict };
}

function effectiveOf(overrides: CapabilityOverrides): NormalizedCapabilityOverrides['effective'] {
  return {
    vision_input: overrides.vision_input?.op ?? null,
    file_input: overrides.file_input?.op ?? null,
    video_input: overrides.video_input?.op ?? null,
  };
}

export function normalizeCapabilityOverrides(input: NormalizeCapabilityOverridesInput): NormalizedCapabilityOverrides {
  if (input.connection === 'official') {
    return { capabilityOverrides: {}, legacyKept: [], effective: effectiveOf({}) };
  }

  const overrides: CapabilityOverrides = {};
  if (isRecord(input.stored)) {
    for (const key of INPUT_CAPABILITY_KEYS) {
      const entry = parseEntry(input.stored[key]);
      if (entry) overrides[key] = entry;
    }
  }

  const legacyKept: string[] = [];
  const legacy: Record<string, unknown> = isRecord(input.legacy) ? input.legacy : {};
  for (const legacyKey of Object.keys(legacy)) {
    const target = LEGACY_INPUT_KEYS[legacyKey];
    const raw = legacy[legacyKey];
    const userChoice = isRecord(raw) && raw.source === 'user' && typeof raw.value === 'boolean' ? raw.value : null;
    if (!target || userChoice === null) {
      legacyKept.push(legacyKey);
      continue;
    }
    // The user choice has been consumed: when the new deltas already hold the same key they win and the old value is dropped.
    if (overrides[target]) continue;
    const server = input.serverVerdict?.[target];
    overrides[target] = {
      op: userChoice ? 'add' : 'remove',
      setAt: input.now,
      baseVerdict: typeof server === 'string' && server !== '' ? server : 'unknown',
    };
  }

  // Emit in a fixed key order so serialization is stable.
  const ordered: CapabilityOverrides = {};
  for (const key of INPUT_CAPABILITY_KEYS) {
    const entry = overrides[key];
    if (entry) ordered[key] = entry;
  }
  return { capabilityOverrides: ordered, legacyKept, effective: effectiveOf(ordered) };
}

/** Keys in the legacy field that correspond to an input key. */
const LEGACY_KEY_OF: Readonly<Record<'vision_input' | 'file_input', 'image' | 'file'>> = {
  vision_input: 'image',
  file_input: 'file',
};

/**
 * Overrides of a Relay model after normalization (read side): stored deltas + legacy user choices. serverVerdict only affects baseVerdict of migrated entries; the read side does not care.
 */
export function relayModelCapabilityOverrides(
  model: Pick<AIModel, 'relayCapabilityOverrides' | 'capabilityOverrides'>,
  now: string = new Date().toISOString(),
): NormalizedCapabilityOverrides {
  return normalizeCapabilityOverrides({
    connection: 'relay',
    legacy: model.relayCapabilityOverrides,
    stored: model.capabilityOverrides,
    serverVerdict: null,
    now,
  });
}

/**
 * Effective value of a Relay vision / file override: user deltas (add -> true, remove -> false) first, then the not-yet-migrated tested value in the legacy field; undefined when neither exists.
 * source tells where it came from: tested is a probe result and cannot beat the negative cache.
 */
export function relayInputOverrideValue(
  model: Pick<AIModel, 'relayCapabilityOverrides' | 'capabilityOverrides'>,
  key: 'vision_input' | 'file_input',
): { value: boolean; source: 'user' | 'tested' } | undefined {
  const op = relayModelCapabilityOverrides(model).effective[key];
  if (op) return { value: op === 'add', source: 'user' };
  const legacy = model.relayCapabilityOverrides?.[LEGACY_KEY_OF[key]];
  if (legacy?.source === 'tested' && typeof legacy.value === 'boolean') return { value: legacy.value, source: 'tested' };
  return undefined;
}
