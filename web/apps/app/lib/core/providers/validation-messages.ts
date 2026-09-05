/**
 * Persisted provider validation messages are stable protocol values, not UI copy.
 * UI surfaces must localize these through their `validation.*` message keys.
 */
export const PROVIDER_VALIDATION_MESSAGES = {
  invalidKey: 'The API key could not be validated. Check the value or generate a new key.',
  unverified: "We couldn't verify the connection. You can retry from the provider details.",
  catalogUnavailable: 'The model catalog could not be loaded. You can retry or add a model ID manually.',
  // The subscription path has no "type in a model ID" escape hatch, since the catalog is decided
  // by the xAI CLI proxy. The copy is kept separate from the line above: sending the user off to
  // type an id they have no way of knowing only leaves them more lost.
  grokSubscriptionCatalogUnavailable: 'The Grok subscription model list could not be loaded. Refresh the connection from provider details.',
  grokSubscriptionReauthorize: 'Your Grok sign-in has expired. Authorize again from provider details.',
  // Same for Codex: the catalog is decided by the Codex backend, and typing an unknown slug is
  // not a way out. Worded separately from the two Grok lines, because the copy has to name whose
  // session expired or the user goes and changes the wrong thing.
  openAISubscriptionCatalogUnavailable: 'The Codex model list could not be loaded. Refresh the connection from provider details.',
  openAISubscriptionReauthorize: 'Your ChatGPT sign-in has expired. Authorize again from provider details.',

  // The subscription path has four hard failures whose remedies are completely different: switch
  // account, wait for the quota to reset, wait for a fix, or reauthorize. Collapsing them into the
  // catalogUnavailable line above leaves the user pressing "refresh connection" over and over
  // against a state that will never recover. The authorization path already carries these four
  // sentences in all 16 locales, and the chat and resync paths use the same ones.
  grokSubscriptionNotEligible: "Your x.ai account's current plan doesn't allow using Grok in third-party apps.",
  grokSubscriptionQuotaExhausted: "You've used up this period's Grok subscription quota. It will resume after the next reset.",
  grokSubscriptionUnavailable: 'Grok subscription sign-in is temporarily unavailable while we update it.',
  // The upstream did return a catalog, but filtering left no usable model. That is different from
  // failing to fetch the catalog: network and credentials are fine, the problem is the model set
  // visible to the account, and telling the user to refresh the connection just sends them in a
  // circle.
  grokSubscriptionCatalogEmpty: 'Your x.ai account returned a model list, but none of those models are usable on this connection right now.',

  openAISubscriptionNotEligible: "Your ChatGPT account's current plan doesn't allow using Codex in third-party apps.",
  openAISubscriptionQuotaExhausted: "You've used up this period's Codex quota. It will resume after the next reset.",
  openAISubscriptionUnavailable: 'ChatGPT subscription sign-in is temporarily unavailable while we update it.',
  openAISubscriptionCatalogEmpty: 'Your ChatGPT account returned a model list, but none of those models are available through Codex right now.',
} as const;
