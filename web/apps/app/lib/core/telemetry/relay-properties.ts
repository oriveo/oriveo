import type { Provider } from '@oriveo/shared';
import { resolveRelayRuntimeFields } from '../providers/relay-resolution';
// URL redaction has exactly one implementation, and the endpoint reported here uses it too, so the two dashboards can be compared
import { sanitizeTelemetryURL } from './index';

/** Aggregatable properties for relay send events; the URL keeps no userinfo, query or fragment, which can carry credentials. */
export function relaySendTelemetryProperties(provider: Provider): Record<string, string> {
  if (provider.kind !== 'relay') return {};

  const runtime = resolveRelayRuntimeFields({
    baseURLText: provider.relayResolvedBaseURLText ?? provider.baseURLText,
    relayRequested: provider.relayRequested,
  });
  const relayURL = sanitizeTelemetryURL(
    provider.relayResolvedBaseURLText ?? runtime.relayResolvedBaseURLText,
  );
  const properties: Record<string, string> = {
    relay_protocol:
      provider.relayResolvedTransport ??
      runtime.relayResolvedTransport ??
      'openai_chat_completions',
  };
  if (relayURL) properties.relay_url = relayURL;
  return properties;
}
