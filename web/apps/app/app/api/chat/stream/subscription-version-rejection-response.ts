/**
 * The two things the route does when the upstream rejects a subscription request with 426
 * (client version too old).
 *
 * This lives in its own file because a Next.js route module may only export the conventional
 * members.
 *
 * 1. Refresh the server-side metadata snapshot right away. The version header is resolved from
 *    that snapshot; without the refresh, users on this instance keep being rejected for up to one
 *    more TTL after the published value has been corrected (the browser refreshing its own copy
 *    of the metadata does not reach this one).
 * 2. Tell the browser, through response headers, which configuration this request used and
 *    whether it changed after the refresh, so reporting can be deduplicated
 *    (see lib/core/providers/subscription-version-rejection.ts).
 */
import {
  SUBSCRIPTION_CONFIG_REVISION_HEADER,
  SUBSCRIPTION_CONFIG_STALE_HEADER,
  subscriptionConfigRevision,
} from '../../../../lib/core/providers/subscription-version-rejection';
import { refreshRuntimeMetadataNow } from './runtime';

interface SubscriptionHeadersConfig {
  requiredHeaders: Record<string, string>;
}

export async function subscriptionVersionRejectionHeaders(input: {
  upstreamStatus: number;
  /** The subscription configuration this request used; null when it was not a subscription request. */
  sentConfig: SubscriptionHeadersConfig | null;
  /** Resolves the currently published subscription configuration again after the refresh. */
  resolveCurrentConfig: () => Promise<SubscriptionHeadersConfig | null>;
}): Promise<Record<string, string>> {
  if (input.upstreamStatus !== 426 || !input.sentConfig) return {};
  const sentRevision = subscriptionConfigRevision(input.sentConfig.requiredHeaders);
  let stale = false;
  try {
    await refreshRuntimeMetadataNow();
    const current = await input.resolveCurrentConfig();
    stale = current !== null && subscriptionConfigRevision(current.requiredHeaders) !== sentRevision;
  } catch {
    // A failed refresh does not stop the 426 from being handed back as is. It is treated as an
    // unchanged configuration: one report too many is the safer side.
  }
  return {
    [SUBSCRIPTION_CONFIG_REVISION_HEADER]: sentRevision,
    ...(stale ? { [SUBSCRIPTION_CONFIG_STALE_HEADER]: '1' } : {}),
  };
}
