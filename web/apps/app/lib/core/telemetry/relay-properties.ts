import type { AIModel, Provider } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { resolveRelayRuntimeFields } from '../providers/relay-resolution';
// URL redaction has exactly one implementation, and the endpoint reported here uses it too, so the two dashboards can be compared
import { sanitizeTelemetryURL } from './index';

/** Aggregatable properties for relay send events; the URL keeps no userinfo, query or fragment, which can carry credentials. */
export function relaySendTelemetryProperties(
  provider: Provider,
  model?: Pick<AIModel, 'relayTransport'> | null,
): Record<string, string> {
  if (provider.kind !== 'relay') return {};

  const runtime = resolveRelayRuntimeFields({
    baseURLText: provider.relayResolvedBaseURLText ?? provider.baseURLText,
    relayRequested: provider.relayRequested,
  });
  const relayURL = sanitizeTelemetryURL(
    provider.relayResolvedBaseURLText ?? runtime.relayResolvedBaseURLText,
  );
  // The protocol comes from the model of this send (same resolver as the send chain), not from a connection-level derived value.
  const properties: Record<string, string> = {
    relay_protocol: effectiveTransport(provider, model),
  };
  if (relayURL) properties.relay_url = relayURL;
  return properties;
}
