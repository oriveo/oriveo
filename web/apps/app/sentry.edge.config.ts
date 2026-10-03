import * as Sentry from "@sentry/nextjs";
import { edgeSentryHooks } from "./lib/sentry/server-before-send";

// Opt-in, same as the Node runtime: no DSN means nothing is sent.
Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  environment: process.env.NEXT_PUBLIC_SENTRY_ENVIRONMENT ?? process.env.NODE_ENV,
  release: process.env.NEXT_PUBLIC_APP_VERSION,
  tracesSampleRate: 0.1,
  // The edge runtime reaches the same provider endpoints, so it carries the same URL-leak risk.
  ...edgeSentryHooks,
});
