import type { AIModel } from '../types/models';
import type {
  EngineDeclaration,
  RelayCapabilityOverrides,
  RelayModelTransport,
  RelayRequestedConfig,
  RelayTransportSource,
} from '../types/relay';

/**
 * Explicit allowlist of `RelayRequestedConfig` fields that may leave the device in a backup archive.
 *
 * This has to be an allowlist, not a "spread everything then delete a few" denylist: under a denylist
 * every new field goes out by default and only stays private if someone remembers to add a delete.
 * `true` means it may leave the device, `false` means it stays local. Every new field must take an
 * explicit position here, otherwise the `portable-config.v1.json` round-trip contract test fails.
 */
const RELAY_REQUESTED_PORTABILITY: Record<keyof RelayRequestedConfig, boolean> = {
  // Protocol and model shape: the same values on any machine, so they travel.
  transport: true,
  authMode: true,
  securityMode: true,
  modelID: true,
  reasoningEffort: true,
  serviceTier: true,
  stream: true,
  disableResponseStorage: true,
  codexCompatIdentity: true,
  imageSize: true,
  imageQuality: true,
  imageStyle: true,
  imageCount: true,
  imageResponseFormat: true,
  webSearchToolName: true,
  hasWebSearch: true,
  webSearchProfile: true,
  transportKind: true,
  /** Travels under the general rule; userInfo, query and fragment are stripped before it leaves. */
  resolvedAPIBaseURL: true,
  /** Same as above; keeps only entries whose key is a known protocol and whose value parses, stripping userInfo/query/fragment from each. */
  resolvedAPIBaseURLs: true,
  engineProfile: true,

  // Local only
  /** Header and query values can carry a second key, so the whole table stays on the device. */
  headers: false,
  queryParams: false,
  /** Already treated as sensitive material locally (cleared entirely when auth=none), so the outbound rule must match; it also widens the fingerprinting surface. */
  customUserAgent: false,
  /** A device-bound TOFU pin. Re-pairing on a new device is enough, and carrying it out only widens the profiling surface. */
  certificateFingerprint: false,
};

/** Runtime form of the outbound allowlist, for fixtures and callers to check against. There must never be a second list. */
export const PORTABLE_RELAY_REQUESTED_FIELDS: readonly string[] = Object.keys(
  RELAY_REQUESTED_PORTABILITY,
).filter((key) => RELAY_REQUESTED_PORTABILITY[key as keyof RelayRequestedConfig]);

/** Every `RelayRequestedConfig` field (allowlisted plus local-only), so a new unregistered field fails the build. */
export const ALL_RELAY_REQUESTED_FIELDS: readonly string[] = Object.keys(
  RELAY_REQUESTED_PORTABILITY,
);

/** Keeps only the explicitly portable fields before a backup archive is written. */
export function credentialFreeRelayRequested(
  requested: RelayRequestedConfig | null | undefined,
): RelayRequestedConfig | undefined {
  if (!requested) return undefined;
  const source = requested as unknown as Record<string, unknown>;
  const portable: Record<string, unknown> = {};
  for (const field of PORTABLE_RELAY_REQUESTED_FIELDS) {
    const value = source[field];
    if (value === undefined) continue;
    if (field === 'resolvedAPIBaseURL') {
      portable[field] = stripRelayURLSecrets(value as string);
    } else if (field === 'resolvedAPIBaseURLs') {
      portable[field] = portableResolvedAPIBaseURLs(value);
    } else {
      portable[field] = value;
    }
  }
  if (portable.resolvedAPIBaseURL === undefined) delete portable.resolvedAPIBaseURL;
  if (portable.resolvedAPIBaseURLs === undefined) delete portable.resolvedAPIBaseURLs;
  return portable as unknown as RelayRequestedConfig;
}

/** Keeps only entries whose key is a concrete protocol and whose value parses; if none remain returns undefined (the whole key is omitted). */
function portableResolvedAPIBaseURLs(value: unknown): Record<string, string> | undefined {
  if (!isPlainRecord(value)) return undefined;
  const kept: Record<string, string> = {};
  for (const [transport, raw] of Object.entries(value)) {
    if (!isRelayModelTransport(transport) || typeof raw !== 'string') continue;
    const stripped = stripRelayURLSecrets(raw);
    if (stripped !== undefined) kept[transport] = stripped;
  }
  return Object.keys(kept).length > 0 ? kept : undefined;
}

export function stripRelayURLSecrets(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed) return undefined;
  try {
    const url = new URL(trimmed);
    url.username = '';
    url.password = '';
    url.search = '';
    url.hash = '';
    return url.toString().replace(/\/$/, '');
  } catch {
    return undefined;
  }
}

/* -- Relay 2.0 model-level fields ------------------------ */

/**
 * Fields on `AIModel` owned by Relay 2.0; `true` = may go outbound (Firestore), `false` = kept only on this device and
 * in the user's own backup file. All are local facts: other clients receiving a protocol / override / engine declaration have no corresponding probe evidence.
 * Same as the connection-level table above - a new field must be declared here, and the fixture `modelFields` is checked on every client.
 */
const RELAY_MODEL_FIELD_PORTABILITY = {
  relayTransport: false,
  relayTransportSource: false,
  relayCapabilityOverrides: false,
  engineDeclaration: false,
  relayKeyID: false,
  relayListedByKeyIDs: false,
  relayDeniedKeyID: false,
} as const satisfies Partial<Record<keyof AIModel, boolean>>;

export const ALL_RELAY_MODEL_FIELDS: readonly string[] = Object.keys(RELAY_MODEL_FIELD_PORTABILITY);

export const PORTABLE_RELAY_MODEL_FIELDS: readonly string[] = Object.entries(
  RELAY_MODEL_FIELD_PORTABILITY,
).filter(([, portable]) => portable).map(([field]) => field);

export const LOCAL_ONLY_RELAY_MODEL_FIELDS: readonly string[] = Object.entries(
  RELAY_MODEL_FIELD_PORTABILITY,
).filter(([, portable]) => !portable).map(([field]) => field);

const RELAY_MODEL_TRANSPORT_TABLE: Record<RelayModelTransport, true> = {
  openai_responses: true,
  openai_chat_completions: true,
  anthropic_messages: true,
  gemini_generate_content: true,
  llamacpp_native: true,
};

/** Model-level protocol vocabulary: all concrete protocols, excluding `auto`. */
export const RELAY_MODEL_TRANSPORTS = Object.keys(
  RELAY_MODEL_TRANSPORT_TABLE,
) as readonly RelayModelTransport[];

const RELAY_MODEL_TRANSPORT_SOURCE_TABLE: Record<RelayTransportSource, true> = {
  user: true,
  observed: true,
  reachable: true,
};

export const RELAY_MODEL_TRANSPORT_SOURCES = Object.keys(
  RELAY_MODEL_TRANSPORT_SOURCE_TABLE,
) as readonly RelayTransportSource[];

/** Value shape of each key of the override table; `reasoningLevels` is a string array (may be empty = the user explicitly says there are no levels). */
const RELAY_CAPABILITY_OVERRIDE_SHAPES: Record<keyof RelayCapabilityOverrides, 'boolean' | 'strings'> = {
  image: 'boolean',
  file: 'boolean',
  imageGeneration: 'boolean',
  toolCall: 'boolean',
  reasoningLevels: 'strings',
  web: 'boolean',
};

export const RELAY_CAPABILITY_OVERRIDE_KEYS = Object.keys(
  RELAY_CAPABILITY_OVERRIDE_SHAPES,
) as ReadonlyArray<keyof RelayCapabilityOverrides>;

const ENGINE_DECLARATION_TABLE: Record<keyof EngineDeclaration, true> = {
  image: true,
  toolCall: true,
  thinking: true,
};

export const ENGINE_DECLARATION_KEYS = Object.keys(
  ENGINE_DECLARATION_TABLE,
) as ReadonlyArray<keyof EngineDeclaration>;

export function isRelayModelTransport(value: unknown): value is RelayModelTransport {
  return typeof value === 'string' && Object.hasOwn(RELAY_MODEL_TRANSPORT_TABLE, value);
}

function isRelayTransportSource(value: unknown): value is RelayTransportSource {
  return typeof value === 'string' && Object.hasOwn(RELAY_MODEL_TRANSPORT_SOURCE_TABLE, value);
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Read-time sanitization of Relay 2.0 model-level fields (read back from local storage / after a backup import). TS has no decoder,
 * so this pure function does the same job: drop item by item, never throw, and leave all other fields untouched.
 *
 * - protocol is `auto` or unknown -> delete (back to following the connection default);
 * - protocol missing -> delete the source; protocol present but source missing / unknown -> delete both;
 * - override table: entries with an unknown key, a source other than `user` / `tested`, or a wrong value shape are deleted one by one; if none remain the whole key is deleted;
 * - engine declaration keeps only known boolean keys; if none remain the whole key is deleted (missing key = unknown).
 *
 * When there is nothing to sanitize the input is returned as is (same reference) and is not modified.
 */
export function sanitizeRelayModelFields<T extends object>(model: T): T {
  const source = model as Record<string, unknown>;
  if (!ALL_RELAY_MODEL_FIELDS.some((field) => field in source)) return model;

  const cleaned: Record<string, unknown> = { ...source };
  for (const field of ALL_RELAY_MODEL_FIELDS) delete cleaned[field];

  if (isRelayModelTransport(source.relayTransport) && isRelayTransportSource(source.relayTransportSource)) {
    cleaned.relayTransport = source.relayTransport;
    cleaned.relayTransportSource = source.relayTransportSource;
  }
  const overrides = sanitizeRelayCapabilityOverrides(source.relayCapabilityOverrides);
  if (overrides) cleaned.relayCapabilityOverrides = overrides;
  const declaration = sanitizeEngineDeclaration(source.engineDeclaration);
  if (declaration) cleaned.engineDeclaration = declaration;
  // Multi-key binding fields: a wrong shape drops the whole key; a dangling id is left to the reader to fall back to the primary key.
  if (typeof source.relayKeyID === 'string' && source.relayKeyID) cleaned.relayKeyID = source.relayKeyID;
  if (
    Array.isArray(source.relayListedByKeyIDs)
    && source.relayListedByKeyIDs.every((id) => typeof id === 'string' && id)
  ) {
    cleaned.relayListedByKeyIDs = [...source.relayListedByKeyIDs];
  }
  if (typeof source.relayDeniedKeyID === 'string' && source.relayDeniedKeyID) {
    cleaned.relayDeniedKeyID = source.relayDeniedKeyID;
  }
  return cleaned as T;
}

/** Read-time sanitization of the engine declaration: non-boolean values and unknown keys are dropped one by one; if none remain returns `undefined`. */
export function sanitizeEngineDeclaration(value: unknown): EngineDeclaration | undefined {
  if (!isPlainRecord(value)) return undefined;
  const kept: EngineDeclaration = {};
  for (const key of ENGINE_DECLARATION_KEYS) {
    if (typeof value[key] === 'boolean') kept[key] = value[key];
  }
  return Object.keys(kept).length > 0 ? kept : undefined;
}

function sanitizeRelayCapabilityOverrides(value: unknown): RelayCapabilityOverrides | undefined {
  if (!isPlainRecord(value)) return undefined;
  const kept: Record<string, unknown> = {};
  for (const key of RELAY_CAPABILITY_OVERRIDE_KEYS) {
    const entry = value[key];
    if (!isPlainRecord(entry) || (entry.source !== 'user' && entry.source !== 'tested')) continue;
    const entrySource = entry.source;
    const shape = RELAY_CAPABILITY_OVERRIDE_SHAPES[key];
    if (shape === 'boolean' && typeof entry.value === 'boolean') {
      kept[key] = { value: entry.value, source: entrySource };
    } else if (
      shape === 'strings'
      && Array.isArray(entry.value)
      && entry.value.every((level) => typeof level === 'string')
    ) {
      kept[key] = { value: [...entry.value], source: entrySource };
    }
  }
  return Object.keys(kept).length > 0 ? (kept as RelayCapabilityOverrides) : undefined;
}

/** Run the model-level sanitization over both the enabled list and the catalog of a Provider; returns the input as is when nothing changes. */
export function sanitizeProviderRelayModelFields<
  T extends { models?: readonly object[]; catalogModels?: readonly object[] },
>(provider: T): T {
  const models = sanitizeModelList(provider.models);
  const catalogModels = sanitizeModelList(provider.catalogModels);
  if (models === provider.models && catalogModels === provider.catalogModels) return provider;
  return { ...provider, models, catalogModels };
}

function sanitizeModelList<T extends object>(list: readonly T[] | undefined): readonly T[] | undefined {
  if (!Array.isArray(list)) return list;
  let changed = false;
  const next = list.map((model: T) => {
    if (typeof model !== 'object' || model === null) return model;
    const cleaned = sanitizeRelayModelFields(model);
    if (cleaned !== model) changed = true;
    return cleaned;
  });
  return changed ? next : list;
}
