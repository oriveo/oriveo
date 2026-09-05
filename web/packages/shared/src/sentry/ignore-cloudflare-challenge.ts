import type { SentryEventLike } from './types';

/**
 * Cloudflare injects a bot detection script into any HTML it proxies (an inline loader
 * using `__CF$cv$params`, plus the main `/cdn-cgi/challenge-platform/**` script). The
 * loader creates a hidden iframe and then reads
 * `a.contentDocument || a.contentWindow.document`; when the iframe is removed by a content
 * blocker or the page unloads early (common on iOS Safari), contentWindow is null and the
 * read throws a TypeError. These errors come from the Cloudflare edge injection and no
 * application change can prevent them; the stack points at an inline script in the page
 * HTML, which is the loader itself.
 *
 * The filter stays narrow, with three independent match paths:
 *  1. the error message references `contentWindow`, which the application code never uses
 *     (narrow this filter before introducing a real use);
 *  2. any stack frame comes from `/cdn-cgi/`, meaning the challenge-platform script itself threw;
 *  3. when Chromium only keeps `reading 'document'`, both the loader's `c` function and an
 *     inline page frame are required, so a real error with the same message from the
 *     application bundle is not swallowed.
 */
const CONTENT_WINDOW_MESSAGE_PATTERNS = [
  "evaluating 'a.contentWindow", // Safari / Firefox  
  'contentWindow.document', //   CF loader  
] as const;

const CLOUDFLARE_FRAME_MARKER = '/cdn-cgi/';
const CHROMIUM_NULL_DOCUMENT_MESSAGE = "Cannot read properties of null (reading 'document')";
const CLOUDFLARE_INLINE_LOADER_FUNCTIONS = new Set(['c', 'HTMLDocument.c']);

function getFrames(event: SentryEventLike) {
  return event.exception?.values?.flatMap((entry) => entry?.stacktrace?.frames ?? []) ?? [];
}

function hasCloudflareFrame(event: SentryEventLike): boolean {
  return getFrames(event).some((frame) => {
    const filename = frame?.filename ?? frame?.abs_path ?? '';
    return filename.includes(CLOUDFLARE_FRAME_MARKER);
  });
}

function hasCloudflareInlineLoaderFrame(event: SentryEventLike): boolean {
  return getFrames(event).some((frame) => {
    const filename = frame?.filename ?? frame?.abs_path ?? '';
    const functionName = frame?.function ?? '';
    const isPageFrame =
      (filename.startsWith('app:///') || filename.startsWith('http://') || filename.startsWith('https://')) &&
      !filename.includes('/_next/') &&
      !filename.endsWith('.js');
    return isPageFrame && CLOUDFLARE_INLINE_LOADER_FUNCTIONS.has(functionName);
  });
}

/**
 * Returns true when the Sentry event almost certainly originates from Cloudflare's injected
 * bot-challenge script. Apps should drop these in `beforeSend` because no code change in the
 * app can prevent them.
 *
 * Shared by every app in this repo, since the whole domain is proxied through Cloudflare
 * and any page can be injected.
 */
export function isIgnorableCloudflareChallengeError(event: SentryEventLike): boolean {
  const exception = event.exception?.values?.[0];
  const message =
    exception?.value ?? (typeof event.message === 'string' ? event.message : '');

  if (CONTENT_WINDOW_MESSAGE_PATTERNS.some((pattern) => message.includes(pattern))) {
    return true;
  }
  if (message === CHROMIUM_NULL_DOCUMENT_MESSAGE && hasCloudflareInlineLoaderFrame(event)) {
    return true;
  }
  return hasCloudflareFrame(event);
}
