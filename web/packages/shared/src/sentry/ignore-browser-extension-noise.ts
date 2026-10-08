import type { SentryEventHintLike, SentryEventLike } from './types';

const EXTENSION_FRAME_PREFIXES = [
  'blob:',
  'chrome-extension:',
  'moz-extension:',
  'safari-web-extension:',
] as const;

const EXTENSION_MESSAGE_PATTERNS = [
  "Cannot read properties of undefined (reading 'addListener')",
  "Cannot read property 'addListener' of undefined",
  "Cannot read properties of undefined (reading 'M_ID')",
] as const;

const INJECTED_EXECUTOR_FRAME = /^app:\/\/\/executors\/\d+\.js$/;

function hasInjectedScriptFrame(event: SentryEventLike): boolean {
  const frames =
    event.exception?.values?.flatMap((entry) => entry?.stacktrace?.frames ?? []) ?? [];
  return frames.some((frame) => {
    const filename = frame?.filename ?? frame?.abs_path ?? '';
    return EXTENSION_FRAME_PREFIXES.some((prefix) => filename.startsWith(prefix))
      || INJECTED_EXECUTOR_FRAME.test(filename);
  });
}

/**
 * Browser extensions sometimes inject blob-backed or `app:///executors/*` scripts into app pages.
 * Chrome reports those global errors as if they belong to the page. Keep the message + frame pair
 * narrow so real app bundle errors with the same message still surface.
 *
 * Shared across every app in this repo: browser extensions are a browser-wide phenomenon, so any
 * Next.js app wired to Sentry receives this noise.
 */
export function isIgnorableBrowserExtensionError(event: SentryEventLike): boolean {
  const exception = event.exception?.values?.[0];
  const message =
    exception?.value ?? (typeof event.message === 'string' ? event.message : '');

  if (!EXTENSION_MESSAGE_PATTERNS.some((pattern) => message.includes(pattern))) {
    return false;
  }

  return hasInjectedScriptFrame(event);
}

/**
 * Addresses of a browser extension's own resources. `webkit-masked-url://hidden/` is how Safari
 * anonymises extension script addresses. A `blob:` prefix is allowed because a blob script an
 * extension creates from its own origin is addressed as `blob:chrome-extension://…`.
 */
const EXTENSION_ORIGIN_URL =
  /^(?:blob:)?(?:(?:chrome|moz|safari-web|safari|ms-browser)-extension|webkit-masked-url):\/\//i;

const STACK_URL = /(?:blob:)?[a-z][a-z0-9+.-]*:\/\/[^\s)]+/gi;

/**
 * V8 frame lines start with `at `; Gecko and JavaScriptCore frame lines read
 * `<function>@<location>`. The leading message line is not a frame.
 */
function isStackFrameLine(line: string): boolean {
  return /^\s*at\s/.test(line) || /@.*:\d+/.test(line);
}

type StackOrigin = 'extension' | 'page' | 'none';

function classifyStackOrigin(stack: string): StackOrigin {
  let extensionFrames = 0;
  for (const line of stack.split('\n')) {
    if (!isStackFrameLine(line)) continue;
    // Frames without an address, such as `at new Promise (<anonymous>)` or `[native code]`, say
    // nothing either way.
    const urls = line.match(STACK_URL);
    if (!urls) continue;
    for (const url of urls) {
      if (!EXTENSION_ORIGIN_URL.test(url)) return 'page';
      extensionFrames += 1;
    }
  }
  return extensionFrames > 0 ? 'extension' : 'none';
}

const MAX_CAUSE_DEPTH = 8;

/**
 * Decides by origin: whether the call stack of this error, including its `cause` chain, stays
 * inside a browser extension's scripts from start to finish.
 *
 * Why it reads `hint.originalException.stack` rather than the event's frames:
 * the client frame normalisation in `@sentry/nextjs`
 * (`nextjsClientStackFrameNormalizationIntegration`) runs before `beforeSend` and replaces the
 * origin of every frame address with `app://`, whether or not the frame belongs to this site:
 *   `chrome-extension://<id>/scripts/inpage.js` becomes `app:///scripts/inpage.js` (in_app=true)
 * By the time `beforeSend` runs, nothing in the event says the frame came from an extension, so
 * matching frames on a `chrome-extension:` prefix never fires in a real browser. A wallet
 * extension's inpage script failing to connect, for example, is reported as if
 * `app:///scripts/inpage.js` were part of the application. The `stack` of the original error
 * object is the browser's own text, untouched by the SDK, and is the only place that still
 * carries the origin.
 *
 * The rule:
 * at least one frame in the chain comes from an extension address and no frame comes from
 * anywhere else. A single page-script frame (the extension called into the application, or the
 * application called an API the extension wrapped) keeps the event, because that may be an
 * application bug. Rejection values without a `stack` (strings, plain objects) are left to the
 * other filters.
 *
 * It does not look at the message, so it holds for any extension and any wording.
 */
export function isErrorThrownEntirelyByBrowserExtension(hint: SentryEventHintLike | undefined): boolean {
  let current: unknown = hint?.originalException;
  let sawExtensionFrame = false;
  for (let depth = 0; depth < MAX_CAUSE_DEPTH && current && typeof current === 'object'; depth += 1) {
    const { stack, cause } = current as { stack?: unknown; cause?: unknown };
    if (typeof stack === 'string') {
      const origin = classifyStackOrigin(stack);
      if (origin === 'page') return false;
      if (origin === 'extension') sawExtensionFrame = true;
    }
    current = cause;
  }
  return sawExtensionFrame;
}
