import * as Sentry from "@sentry/nextjs";
import { isIgnorableRelayProtectiveAbort, isIgnorableStreamDisconnect } from "./lib/sentry/ignore-relay-noise";
import { redactSentryEvent, redactSentrySpan } from "./lib/sentry/redact-url";
import { isProviderResponseErrorHint } from "./lib/sentry/provider-error-detail";

// Error reporting is opt-in: with no DSN configured, Sentry.init installs a client that sends
// nothing, so a default deployment reports nowhere.
Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  environment: process.env.NEXT_PUBLIC_SENTRY_ENVIRONMENT ?? process.env.NODE_ENV,
  release: process.env.NEXT_PUBLIC_APP_VERSION,
  tracesSampleRate: 0.1,
  // Outgoing fetch URLs end up in trace spans, and the built-in PII scrubber does not touch a
  // query string. A provider key passed as `?key=` would ship verbatim without these two hooks.
  beforeSend(event, hint) {
    if (isProviderResponseErrorHint(hint)) return null;
    if (isIgnorableRelayProtectiveAbort(event)) return null;
    if (isIgnorableStreamDisconnect(event)) return null;
    return redactSentryEvent(event);
  },
  beforeSendSpan: redactSentrySpan,
});
