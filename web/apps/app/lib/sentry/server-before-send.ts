import type { ErrorEvent, EventHint } from "@sentry/nextjs";
import {
  isIgnorableMcpProtectiveAbort,
  isIgnorableRelayProtectiveAbort,
  isIgnorableStreamDisconnect,
} from "./ignore-relay-noise";
import { isProviderResponseErrorHint } from "./provider-error-detail";
import { redactSentryBreadcrumb, redactSentryEvent, redactSentrySpan, type RedactableSentryEvent } from "./redact-url";

/**
 * `beforeSend` / `beforeSendTransaction` for the Node runtime.
 *
 * They live outside `sentry.server.config.ts` so tests can call them directly: that file runs
 * `Sentry.init` on import and cannot be tested, while "credential-bearing request headers never
 * reach Sentry" has to be proven by the real hook functions, not by reading source strings.
 *
 * Order: drop known noise first, then redact what is left. Redaction (redactSentryEvent) runs
 * unconditionally on every event that passes and does not depend on a drop rule matching. Drop
 * rules match on error messages and miss as soon as a message changes; redaction must not miss
 * along with them.
 */
export function serverBeforeSend(event: ErrorEvent, hint: EventHint): ErrorEvent | null {
  if (isProviderResponseErrorHint(hint)) return null;
  if (isIgnorableRelayProtectiveAbort(event)) return null;
  if (isIgnorableMcpProtectiveAbort(event)) return null;
  if (isIgnorableStreamDisconnect(event)) return null;
  return redactSentryEvent(event);
}

/** Transaction events also carry inbound request headers (and header attributes on the root span), so they go through the same redaction as error events. */
export function serverBeforeSendTransaction<T extends RedactableSentryEvent>(event: T): T {
  return redactSentryEvent(event);
}

/**
 * Every redaction hook handed to `Sentry.init` in the Node runtime. `sentry.server.config.ts`
 * spreads this object as is and the tests initialize the real SDK with the same object, so a
 * missing hook shows up in the tests as unredacted data.
 *
 * `beforeBreadcrumb` is required: the server-side http integration records a breadcrumb for every
 * outbound request (URL, query string, fragment), and those are sent along with any later error
 * event without passing through `beforeSendSpan`.
 */
export const serverSentryHooks = {
  beforeSend: serverBeforeSend,
  beforeSendTransaction: serverBeforeSendTransaction,
  beforeSendSpan: redactSentrySpan,
  beforeBreadcrumb: redactSentryBreadcrumb,
};

/** The same hooks for the edge runtime (without the Node-only rules that drop events by error message). */
export const edgeSentryHooks = {
  beforeSend(event: ErrorEvent, hint: EventHint): ErrorEvent | null {
    if (isProviderResponseErrorHint(hint)) return null;
    return redactSentryEvent(event);
  },
  // Transaction events carry inbound request headers too, so they are redacted as well (credential headers are always removed).
  beforeSendTransaction: <T extends RedactableSentryEvent>(event: T): T => redactSentryEvent(event),
  beforeSendSpan: redactSentrySpan,
  beforeBreadcrumb: redactSentryBreadcrumb,
};
