import type { SentryEventLike } from './types';

/**
 * Some mobile browsers (MiUI, UC, QQ, Huawei, Vivo, OPPO, Baidu, Quark) inject translation,
 * copy, ad or dark-mode scripts. Those scripts can mutate the DOM before React hydrates, causing
 * hydration errors, and they can turn an inline SVG into a data URI while analysing page images,
 * which then fails to load. The events come from the browser and no application code can prevent them.
 *
 * The filter stays deliberately narrow: an event must first match a known injecting browser and then
 * either a hydration signature, or the combination of UnhandledRejection with no stack and a failed
 * inline-SVG image load. Ordinary image errors and errors with an application stack are kept.
 */
const INJECTING_BROWSER_PATTERNS = [
  'miuibrowser',
  'ucbrowser',
  'qqbrowser',
  'huaweibrowser',
  'vivobrowser',
  'oppobrowser',
  'baidubrowser',
  'quark',
] as const;

const SVG_IMAGE_REJECTION_PREFIX =
  'Non-Error promise rejection captured with value: Unable to load image data:image/svg+xml;base64,';

const HYDRATION_MESSAGE_PATTERNS = [
  'Hydration',
  'Text content does not match',
  'Text content did not match',
  'did not match',
  'Minified React error #418',
  'Minified React error #421',
  'Minified React error #423',
  'Minified React error #425',
] as const;

/**
 * Private namespaces belonging to the host browser's own injected content script.
 *
 * Firefox for iOS injects ReaderMode.js at document-start, defining `window.__firefox__.reader`, and
 * the Swift side then calls `checkReadability()` through evaluateJavaScript. Before the injection
 * finishes that expression throws a TypeError, and WebKit attributes evaluateJavaScript exceptions to
 * line 1 of the page URL, so the event arrives with `app:///<path>:1` and inApp=true and looks like a
 * bundle error.
 *
 * The UA cannot be used here: Firefox for iOS ships a webcompat UA that drops the FxiOS token and
 * poses as Mobile Safari, indistinguishable from real Safari. The only usable signal is the private
 * namespace literal in the message, which this project's own source never references.
 *
 * The second family is the Android native bridge: embedded WebViews in mobile browsers and super-apps
 * use evaluateJavascript to inject content extraction, reader mode, form autofill or ad SDK scripts,
 * and those scripts call back into their own bridge object. When the bridge is not attached they throw
 * `TypeError: <bridge>.<method> is not a function`, which bubbles up to window.onerror and is collected
 * here (`mbrowser` and `_dsbridge` are the two observed bridges). The UA is useless again: a bare
 * WebView UA carries only `wv` and no brand token, so Sentry classifies it as "Chrome Mobile WebView"
 * and none of the brand patterns above match. The literals include the trailing dot to pin the property
 * access shape, which matches the real error text and avoids false positives from bare identifiers.
 */
const BROWSER_PRIVATE_NAMESPACE_PATTERNS = ['__firefox__', 'mbrowser.', '_dsbridge.'] as const;

function extractBrowserSignature(event: SentryEventLike): string {
  const tags = event.tags ?? {};
  const tagBrowserName = typeof tags['browser.name'] === 'string' ? (tags['browser.name'] as string) : '';
  const tagBrowser = typeof tags['browser'] === 'string' ? (tags['browser'] as string) : '';
  const ctxBrowser = event.contexts?.browser?.name ?? '';
  const headers = event.request?.headers ?? {};
  const ua = headers['User-Agent'] ?? headers['user-agent'] ?? '';
  return `${tagBrowserName} ${tagBrowser} ${ctxBrowser} ${ua}`;
}

function isHydrationLikeMessage(message: string): boolean {
  if (!message) return false;
  return HYDRATION_MESSAGE_PATTERNS.some((pattern) => message.includes(pattern));
}

function isInjectingBrowser(event: SentryEventLike): boolean {
  // Sentry renders the QQBrowser UA as `QQ Browser Mobile`, so compare after removing spaces,
  // punctuation and case, keeping the UA name and the display name from diverging.
  const normalizedSignature = extractBrowserSignature(event)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
  return INJECTING_BROWSER_PATTERNS.some((pattern) => normalizedSignature.includes(pattern));
}

function isInjectedSvgImageLoadRejection(event: SentryEventLike): boolean {
  const exception = event.exception?.values?.[0];
  if (exception?.type !== 'UnhandledRejection') return false;
  if (!exception.value?.startsWith(SVG_IMAGE_REJECTION_PREFIX)) return false;

  return (exception.stacktrace?.frames?.length ?? 0) === 0;
}

function isBrowserPrivateNamespaceError(event: SentryEventLike): boolean {
  const exception = event.exception?.values?.[0];
  const message =
    exception?.value ?? (typeof event.message === 'string' ? event.message : '');
  if (!message) return false;
  return BROWSER_PRIVATE_NAMESPACE_PATTERNS.some((pattern) => message.includes(pattern));
}

/**
 * Returns true when the Sentry event almost certainly originates from the **host browser's own
 * injected content script** rather than our bundle. Apps should drop these in `beforeSend`
 * because no code change in the app can prevent them.
 *
 * Two independent paths:
 * 1. An error in a browser-private JS namespace, which is UA-independent because a spoofed UA would
 *    always defeat a UA gate.
 * 2. A known injecting mobile browser combined with a hydration error or an inline-SVG rejection.
 */
export function isIgnorableMobileBrowserInjection(event: SentryEventLike): boolean {
  if (isBrowserPrivateNamespaceError(event)) return true;
  if (!isInjectingBrowser(event)) return false;
  return isHydrationErrorEvent(event) || isInjectedSvgImageLoadRejection(event);
}

/**
 * Returns true when the Sentry event is a React hydration mismatch (regardless of browser).
 *
 * Building block for `isIgnorableMobileBrowserInjection`. Also used directly by the **static
 * marketing site**: every site page is deterministic server-rendered content (no client
 * state / IndexedDB / auth-dependent markup), so any hydration mismatch there is almost
 * always the browser's built-in "translate this page" feature or an extension mutating the
 * DOM before React hydrates — most prevalent on CJK (zh / ja / ko) legal pages (terms /
 * privacy), and observed across mainstream desktop browsers (Chrome / Safari / Edge), not
 * just the injecting mobile browsers above. The app code cannot prevent it.
 *
 * ⚠️ Only the static site should drop these wholesale. The dynamic app must keep hydration
 * errors to catch real SSR/CSR mismatches.
 */
export function isHydrationErrorEvent(event: SentryEventLike): boolean {
  const exception = event.exception?.values?.[0];
  const message =
    exception?.value ?? (typeof event.message === 'string' ? event.message : '');
  return isHydrationLikeMessage(message);
}
