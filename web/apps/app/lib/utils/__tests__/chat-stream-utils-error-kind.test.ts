import { describe, expect, it } from 'vitest';
import type { ProviderErrorKind } from '@oriveo/core';
import enMessages from '../../../messages/en.json';
import { mapErrorKindKey, resolveErrorCopyKey } from '../chat-stream-utils';

describe('mapErrorKindKey', () => {
  it('maps the moderation kind to the moderationBlocked errors key', () => {
    expect(mapErrorKindKey('moderation')).toBe('moderationBlocked');
  });

  it('passes through known kinds and defaults unknown kinds to upstream', () => {
    expect(mapErrorKindKey('network')).toBe('network');
    expect(mapErrorKindKey('invalidKey')).toBe('invalidKey');
    expect(mapErrorKindKey('somethingUnknown')).toBe('upstream');
  });

  // Redirecting quotaExceeded / unauthorized / unavailable to rateLimited / requestFailed / upstream
  // meant none of those three sets of copy ever rendered in any of the 16 languages: an exhausted
  // quota showed up as "rate limit exceeded", which invites the user to retry a request that can
  // never succeed. Each kind has its own copy and must be passed through.
  it('renders quota / auth / availability kinds with their own copy instead of redirecting', () => {
    expect(mapErrorKindKey('quotaExceeded')).toBe('quotaExceeded');
    expect(mapErrorKindKey('unauthorized')).toBe('unauthorized');
    expect(mapErrorKindKey('unavailable')).toBe('unavailable');
  });

});

describe('resolveErrorCopyKey', () => {
  // errorTitle/errorDetail are persisted as the localized text from the moment of failure, so a
  // Chinese UI would show an English card. Rendering re-translates from the semantic identifier,
  // which only works when the kind really lives under errors.*.
  it('maps a known kind to a copy key usable at render time', () => {
    expect(resolveErrorCopyKey('network')).toBe('network');
    expect(resolveErrorCopyKey('moderation')).toBe('moderationBlocked');
    // Kinds bucketed into upstream but semantically settled are translated at render time too
    expect(resolveErrorCopyKey('emptyResponse')).toBe('upstream');
  });

  it('returns null for older data with no errorKind so the caller falls back to the stored string', () => {
    expect(resolveErrorCopyKey(undefined)).toBeNull();
    expect(resolveErrorCopyKey('')).toBeNull();
  });

  // Library errorKind values are not ProviderError.kind, and the mapErrorKindKey upstream fallback
  // would turn "the library needs re-authorization" into "provider failure, try again later".
  // Returning null keeps the stored copy.
  it('returns null for kinds that are not ProviderError semantics instead of falling back to upstream', () => {
    expect(resolveErrorCopyKey('library_needs_reauth')).toBeNull();
    expect(resolveErrorCopyKey('library_quota_exceeded')).toBeNull();
    expect(resolveErrorCopyKey('library_source_error')).toBeNull();
    expect(resolveErrorCopyKey('somethingUnknown')).toBeNull();
    expect(mapErrorKindKey('library_needs_reauth')).toBe('upstream');
  });
});

/**
 * Exhaustiveness gate: every ProviderErrorKind must be able to render its own localized copy.
 *
 * Both allowlists (the pass-through condition in mapErrorKindKey and RENDER_LOCALIZABLE_ERROR_KINDS)
 * are hand-maintained, and a missing entry **raises no error** - it silently swaps the dedicated
 * copy for "provider failure, try again later". That is how quotaExceeded / unauthorized /
 * unavailable once failed to render in any of the 16 languages, showing an exhausted quota as
 * "rate limit exceeded" and inviting retries that could never succeed.
 *
 * One trap in the assertion design: checking only that the resulting key exists under errors.*
 * **cannot catch** a missing entry, because a missing entry lands on the upstream fallback and
 * upstream does exist. The real assertion is that a kind with dedicated copy must be passed
 * through untouched rather than swallowed by the fallback.
 */
describe('every ProviderErrorKind renders localized copy', () => {
  // Record<ProviderErrorKind, true> makes typecheck maintain this list: adding a member to the
  // union without adding it here makes tsc report the missing key instead of silently skipping it.
  const ALL_PROVIDER_ERROR_KINDS: Record<ProviderErrorKind, true> = {
    invalidKey: true,
    unauthorized: true,
    badRequest: true,
    quotaExceeded: true,
    rateLimited: true,
    unavailable: true,
    network: true,
    emptyResponse: true,
    upstream: true,
    emptyModelCatalog: true,
    grokSubscriptionUnavailable: true,
    grokSubscriptionIneligible: true,
    grokSubscriptionExpired: true,
    grokSubscriptionQuotaExhausted: true,
    openAISubscriptionUnavailable: true,
    openAISubscriptionIneligible: true,
    openAISubscriptionExpired: true,
    openAISubscriptionQuotaExhausted: true,
    moderation: true,
    customRequestFieldsRejected: true,
    relayUpstream: true,
  };

  const kinds = Object.keys(ALL_PROVIDER_ERROR_KINDS) as ProviderErrorKind[];

  // relayUpstream goes through the separate RelayGuidanceCode path (errors.relay*), not errors.<kind>.
  const NOT_KEYED_BY_KIND = new Set<ProviderErrorKind>(['relayUpstream']);
  // moderation is the one deliberate rename (to moderationBlocked), pinned by the test above.
  const RENAMED = new Set<ProviderErrorKind>(['moderation']);
  // Same name does not mean same meaning: both kinds do have entries under errors.*, but that copy
  // describes the **model catalog** ("invalid model catalog response" / "empty model catalog"),
  // whereas emptyResponse in chat means "the provider returned no assistant content". Passing it
  // through would render a chat failure as a catalog error, so these are deliberately bucketed into
  // upstream; see the existing resolveErrorCopyKey assertion.
  // That is also the one weakness of this gate: it can verify that a key exists, not that the
  // meaning matches. A new exemption must spell out why, and must never be added just to turn the
  // test green.
  const INTENTIONALLY_BUCKETED = new Set<ProviderErrorKind>(['emptyResponse', 'emptyModelCatalog']);

  it.each(kinds.filter((k) => !NOT_KEYED_BY_KIND.has(k)))(
    '%s has copy under errors.* in en.json',
    (kind) => {
      const key = mapErrorKindKey(kind);
      expect(enMessages.errors).toHaveProperty(key);
    },
  );

  it.each(
    kinds.filter(
      (k) => !NOT_KEYED_BY_KIND.has(k) && !RENAMED.has(k) && !INTENTIONALLY_BUCKETED.has(k),
    ),
  )('%s is passed through untouched when it has dedicated copy, not swallowed by upstream', (kind) => {
    if (!(kind in enMessages.errors)) return; // A kind with no dedicated copy is correct to fall back
    expect(mapErrorKindKey(kind)).toBe(kind);
    // Same on the render side: a null from resolveErrorCopyKey means falling back to the stored string
    expect(resolveErrorCopyKey(kind)).not.toBeNull();
  });
});
