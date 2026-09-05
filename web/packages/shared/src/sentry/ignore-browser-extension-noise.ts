import type { SentryEventLike } from './types';

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
