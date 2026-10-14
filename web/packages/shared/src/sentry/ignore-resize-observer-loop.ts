import type { SentryEventLike } from './types';

/**
 * The notice a browser reports to window.onerror when a ResizeObserver could not deliver every
 * notification within one frame. It is not a thrown exception: the remaining notifications are
 * deferred to the next frame and the page is unaffected.
 *
 * The Sentry SDK's default ignore list only covers the current wording, `ResizeObserver loop
 * completed with undelivered notifications.`; the older Chrome wording, `ResizeObserver loop limit
 * exceeded`, gets through. Seen from Chrome 114 as a burst of two dozen events with no stack
 * frames within a few seconds of one page load. This fills in the older wording so both are
 * treated the same way.
 */
const RESIZE_OBSERVER_LOOP_MESSAGE = /^(?:Error: )?ResizeObserver loop limit exceeded\.?$/;

export function isResizeObserverLoopNotice(event: SentryEventLike): boolean {
  const values = event.exception?.values ?? [];
  if (values.some((entry) => RESIZE_OBSERVER_LOOP_MESSAGE.test(entry?.value ?? ''))) return true;
  return typeof event.message === 'string' && RESIZE_OBSERVER_LOOP_MESSAGE.test(event.message);
}
