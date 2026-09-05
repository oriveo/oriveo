import { isValidProviderKind, type Provider, type ProviderKind } from '@oriveo/shared';

/**
 * Effective status for display and statistics: "no API key on this device" is treated as an issue.
 *
 * API keys are stored encrypted locally and never uploaded, so a provider synced from another
 * device has an empty apiKey field here. Its business status may still be connected, from a
 * successful validation on the other device, while it cannot actually be used here and has to be
 * shown as "needs key".
 *
 * This is a display-layer derivation only and does not modify Provider.status itself: the real
 * status is still what business logic such as resync and telemetry uses.
 */
export type EffectiveStatusKind = 'connected' | 'syncing' | 'issue' | 'needsKey';

/** Every provider except the platform's virtual ones needs a local API key. Relay connections also carry a user-supplied key. */
export function allowsCredentialEditing(kind: ProviderKind): boolean {
  return isValidProviderKind(kind);
}

/**
 * Display-derived state: a missing local key shows as needsKey, otherwise the original status is
 * kept. Local engines (a non-empty relayRequested.engineProfile) are exempt - they need no
 * authentication and send no credentials, so an empty key is a valid state rather than a missing
 * one. Without the exemption a working LM Studio connection gets labelled "needs key".
 */
export function getEffectiveStatusKind(provider: Provider): EffectiveStatusKind {
  // Subscription sign-in credentials do not live in `apiKey`, which stays empty even though the
  // connection is fully usable. Without checking this first, the whole subscription path shows as
  // "needs key" in the list, on the detail page and on the recovery card, while the user has no
  // key to enter.
  //
  // The dispatch has to be by kind, using exactly the same rule as resync in `provider-sync` and
  // the authorization panel on the detail page: `authMode` only says that a connection uses a
  // subscription, not which path it uses. Reading only `grokSubscription` makes every Codex
  // instance report needsKey while the credential sits safely in `openAISubscription`, asks the
  // user for a key that does not exist on that path, and lets the fake state mask the real
  // `lastError` - a hero card reading "Needs API Key" once hid a catalog fetch failure.
  if (provider.authMode === 'subscription') {
    const credential = provider.kind === 'openAI'
      ? provider.openAISubscription
      : provider.grokSubscription;
    return credential?.accessToken ? provider.status.kind : 'needsKey';
  }
  if (
    allowsCredentialEditing(provider.kind)
    && provider.apiKey.trim().length === 0
    && !provider.relayRequested?.engineProfile
  ) {
    return 'needsKey';
  }
  return provider.status.kind;
}

/** Both issue and needsKey count as "in trouble", which drives cluster statistics and the Recovery Card. */
export function isEffectiveWarning(kind: EffectiveStatusKind): boolean {
  return kind === 'issue' || kind === 'needsKey';
}
