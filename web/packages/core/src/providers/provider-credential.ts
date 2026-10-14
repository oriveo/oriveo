import type { AIModel, Provider } from '@oriveo/shared/pure-types';
import { relayEffectiveKeyID, relayKeySecret } from '@oriveo/shared/relay/relay-keys';

/**
 * The only connection fields needed to fetch a key (structural subtype): callers carrying only `apiKey` still get the primary key.
 */
export type ProviderCredentialSource = Pick<Provider, 'apiKey'> & {
  kind?: string;
  relayKeys?: Provider['relayKeys'];
  models?: ReadonlyArray<Pick<AIModel, 'id' | 'relayKeyID'>>;
};

/**
 * The single entry point for fetching a connection key by model.
 * Contract fixture: `shared/test-fixtures/relay/credential-resolve.v1.json`.
 * When a relay has a key list: an enabled model's `relayKeyID` that hits the list -> that key's value;
 * missing, dangling, model not among the enabled ones, or empty model id -> the primary key. Non-relay ignores the list. Never trimmed.
 */
export function resolveProviderAPIKey(
  provider: ProviderCredentialSource,
  modelId?: string | null,
): string {
  if (provider.kind !== 'relay' || !provider.relayKeys?.length) return provider.apiKey;
  return relayKeySecret(provider, relayEffectiveKeyID(provider, modelId)) ?? provider.apiKey;
}
