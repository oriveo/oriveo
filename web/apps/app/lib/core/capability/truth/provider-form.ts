import type { Provider } from '@oriveo/shared';

/**
  * The "form" of capability truth: it decides who has the final say on a connection's capabilities (hosted catalog / free catalog / the user's own
  * relay / upstream declarations of a logged-in account / official metadata). It is not ProviderKind - vendor distinctions such as `grok`, `openAI`
  * do not belong to the form.
 */
export type ProviderForm = 'relay' | 'subscription' | 'official';

/**
  * Derive the form from a Provider once. The order is fixed and the first match wins (shared contract forms.order):
  * relay comes before subscription because the truth of a relay connection always comes from the user's own machine,
  * and leftover auth fields on the connection must not change its attribution.
 */
export function providerFormOf(provider: Pick<Provider, 'kind' | 'authMode'>): ProviderForm {
  if (provider.kind === 'relay') return 'relay';
  if (provider.authMode === 'subscription') return 'subscription';
  return 'official';
}

/**
  * The community edition has no hosted or free forms, so no kind maps to one. Kept so callers that ask
  * "is this a hosted kind" keep a single answer.
 */
export function hostedProviderFormOf(_kind: Provider['kind']): undefined {
  return undefined;
}
