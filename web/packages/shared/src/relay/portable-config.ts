import type { RelayRequestedConfig } from '../types/relay';

/**
 * Explicit allowlist of `RelayRequestedConfig` fields that may leave the device (cloud sync or backup
 * export).
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
  /** Stored in the user's own partition, so it syncs under the general rule; userInfo, query and fragment are stripped before it leaves. */
  resolvedAPIBaseURL: true,
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

/** Keeps only the explicitly portable fields before backup or cloud sync. */
export function credentialFreeRelayRequested(
  requested: RelayRequestedConfig | null | undefined,
): RelayRequestedConfig | undefined {
  if (!requested) return undefined;
  const source = requested as unknown as Record<string, unknown>;
  const portable: Record<string, unknown> = {};
  for (const field of PORTABLE_RELAY_REQUESTED_FIELDS) {
    const value = source[field];
    if (value === undefined) continue;
    portable[field] = field === 'resolvedAPIBaseURL'
      ? stripRelayURLSecrets(value as string)
      : value;
  }
  if (portable.resolvedAPIBaseURL === undefined) delete portable.resolvedAPIBaseURL;
  return portable as unknown as RelayRequestedConfig;
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
