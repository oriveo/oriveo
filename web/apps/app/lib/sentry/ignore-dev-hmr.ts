import type { ErrorEvent, Event, EventHint } from "@sentry/nextjs";

const HMR_FILENAME_PATTERNS = [
  "/mini-css-extract-plugin/",
  "/next/dist/compiled/mini-css-extract-plugin/",
  "webpack.hot-update.",
  "hotModuleReplacement",
];

const HMR_MESSAGE_PATTERNS = [
  "Cannot read properties of null (reading 'removeChild')",
  "Cannot read property 'removeChild' of null",
];

/**
 * The Next.js dev server's Fast Refresh combined with mini-css-extract-plugin HMR occasionally throws a
 * `removeChild` NPE while hot-reloading CSS. It is development-only noise with no production impact, so
 * it is filtered out to keep Sentry statistics clean.
 */
export function isIgnorableNextDevHmrError(
  event: Event,
  hint?: EventHint,
): boolean {
  if (process.env.NODE_ENV === "production") return false;

  const errorEvent = event as ErrorEvent;
  const exception = errorEvent.exception?.values?.[0];
  const message = exception?.value ?? errorEvent.message ?? "";

  if (!HMR_MESSAGE_PATTERNS.some((pattern) => message.includes(pattern))) {
    return false;
  }

  const frames = exception?.stacktrace?.frames ?? [];
  const hasHmrFrame = frames.some((frame) => {
    const filename = frame.filename ?? "";
    return HMR_FILENAME_PATTERNS.some((pattern) => filename.includes(pattern));
  });
  if (hasHmrFrame) return true;

  const originalException = hint?.originalException;
  if (originalException && typeof originalException === "object") {
    const stack = (originalException as { stack?: string }).stack ?? "";
    if (
      HMR_FILENAME_PATTERNS.some((pattern) => stack.includes(pattern))
    ) {
      return true;
    }
  }
  return false;
}
