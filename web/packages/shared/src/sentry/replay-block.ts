/**
 * Third-party cross-origin iframes that Replay must not record.
 *
 * On iframe load rrweb reads `contentWindow.Element` to patch attachShadow. reCAPTCHA and
 * Turnstile insert their iframe as a same-origin about:blank and then navigate it cross-origin:
 * the document is still readable at serialization time, but reading Element afterwards throws an
 * unhandled SecurityError from inside @sentry/replay's onIframeLoad. Cross-origin content can't be
 * recorded anyway, so block it; the replay keeps a placeholder box.
 */
export const THIRD_PARTY_IFRAME_REPLAY_BLOCK_SELECTORS: readonly string[] = [
  'iframe[title="reCAPTCHA"]',
  'iframe[src*="/recaptcha/"]',
  '.grecaptcha-badge iframe',
  'iframe[src*="challenges.cloudflare.com"]',
];
