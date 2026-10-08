/**
 * Decides whether a subscription request rejected by the upstream for its client version
 * (HTTP 426) is worth sending to error monitoring.
 *
 * The report has exactly one purpose: saying that the published version header is below the
 * upstream minimum and the published configuration needs updating. It follows that:
 *  - if the configuration already changed after the refresh, nothing is reported. The rejected
 *    request used an old snapshot, the published value has been corrected, nobody needs to do
 *    anything, and the user's next retry carries the new value;
 *  - the same configuration is reported once per page session. Users retry repeatedly, and every
 *    attempt is the same fact.
 *
 * On the web the version header is resolved by the `/api/chat/stream` route from server-side
 * metadata, so the browser does not know what a request carried. After a 426 the route force
 * refreshes its own snapshot and returns its conclusion in the two response headers below.
 */

/** Fingerprint of the subscription configuration this request used (a digest of the required headers). */
export const SUBSCRIPTION_CONFIG_REVISION_HEADER = 'X-Oriveo-Subscription-Config-Revision';
/** Value `1`: after refreshing, the route found the published configuration differs from the one this request used. */
export const SUBSCRIPTION_CONFIG_STALE_HEADER = 'X-Oriveo-Subscription-Config-Stale';

export type SubscriptionLane = 'grok' | 'openAI';

/**
 * Stable fingerprint of the required headers: keys sorted, joined, then run through a short hash.
 * It is only used for comparison and deduplication.
 */
export function subscriptionConfigRevision(requiredHeaders: Record<string, string>): string {
  const canonical = Object.keys(requiredHeaders)
    .sort()
    .map((key) => `${key}=${requiredHeaders[key]}`)
    .join('\n');
  let hash = 5381;
  for (let index = 0; index < canonical.length; index += 1) {
    hash = ((hash << 5) + hash + canonical.charCodeAt(index)) >>> 0;
  }
  return hash.toString(36);
}

const reported = new Set<string>();

export function shouldReportSubscriptionVersionRejection(input: {
  lane: SubscriptionLane;
  /** Fingerprint of the configuration this request used; null when it failed before sending or the route did not return one. */
  revision: string | null;
  /** After the refresh the configuration differs from the one this request used. */
  stale: boolean;
}): boolean {
  if (input.stale) return false;
  const key = `${input.lane}|${input.revision ?? ''}`;
  if (reported.has(key)) return false;
  reported.add(key);
  return true;
}

/** Test-only. */
export function __resetSubscriptionVersionRejectionGateForTest(): void {
  reported.clear();
}
