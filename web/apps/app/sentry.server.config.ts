import * as Sentry from "@sentry/nextjs";
import { serverSentryHooks } from "./lib/sentry/server-before-send";

// Error reporting is opt-in: with no DSN configured, Sentry.init installs a client that sends
// nothing, so a default deployment reports nowhere.
Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  environment: process.env.NEXT_PUBLIC_SENTRY_ENVIRONMENT ?? process.env.NODE_ENV,
  release: process.env.NEXT_PUBLIC_APP_VERSION,
  tracesSampleRate: 0.1,
  // Outgoing request URLs end up in trace spans and breadcrumbs, and the built-in PII scrubber
  // does not touch a query string: a provider key passed as `?key=` would ship verbatim without
  // these hooks. Credentials in inbound request headers (the MCP and relay forward routes carry
  // tokens in headers) are removed by the same hooks; see lib/sentry/server-before-send.ts.
  ...serverSentryHooks,
});
