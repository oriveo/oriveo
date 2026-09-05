import * as Sentry from "@sentry/nextjs";
import { redactSentryEvent, redactSentrySpan } from "./lib/sentry/redact-url";
import { isProviderResponseErrorHint } from "./lib/sentry/provider-error-detail";

// Opt-in, same as the Node runtime: no DSN means nothing is sent.
Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  environment: process.env.NEXT_PUBLIC_SENTRY_ENVIRONMENT ?? process.env.NODE_ENV,
  release: process.env.NEXT_PUBLIC_APP_VERSION,
  tracesSampleRate: 0.1,
  // The edge runtime reaches the same provider endpoints, so it carries the same URL-leak risk.
  beforeSend(event, hint) {
    if (isProviderResponseErrorHint(hint)) return null;
    return redactSentryEvent(event);
  },
  beforeSendSpan: redactSentrySpan,
});
