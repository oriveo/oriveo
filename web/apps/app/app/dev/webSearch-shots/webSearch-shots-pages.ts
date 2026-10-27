/** Page names for the web search page family shots (the same list as the shared manifest test-fixtures/shots/webSearch.v1.json and iOS / Android; case preserved). */
export const WEB_SEARCH_SHOT_PAGES = [
  'webSearchHome',
  'webSearchEmpty',
  'webSearchMain',
  'webSearchAdd',
  'webSearchConnectReuse',
  'webSearchConnectPaste',
  'webSearchConnectPassed',
  'webSearchDetail',
  'webSearchDetailOwnKey',
  'webSearchCustomForm',
  'webSearchCustomManual',
  'webSearchCustomConsent',
  'webSearchCustomConsentFailed',
  'webSearchOptExternal',
  'webSearchOptPresearch',
  'webSearchOptNotArmed',
  'webSearchOptReuse',
  'webSearchOptNone',
  'webSearchOptNative',
  'webSearchOptFallback',
  'webSearchSourcePicker',
  'webSearchChatSearching',
  'webSearchChatAnswer',
  'webSearchChatError',
  'webSearchChatErrorRateLimited',
  'webSearchChatErrorFormat',
  'webSearchChatErrorHostChanged',
  'webSearchChatErrorWithdrawn',
  'webSearchChatErrorNetwork',
  'webSearchChatReused',
] as const;

export type WebSearchShotPage = (typeof WEB_SEARCH_SHOT_PAGES)[number];

export function isWebSearchShotPage(value: string): value is WebSearchShotPage {
  return (WEB_SEARCH_SHOT_PAGES as readonly string[]).includes(value);
}
