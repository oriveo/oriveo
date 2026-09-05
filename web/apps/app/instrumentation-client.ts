import {
  isIgnorableBrowserExtensionError,
  isIgnorableCloudflareChallengeError,
  isIgnorableMobileBrowserInjection,
} from "@oriveo/shared";
import * as Sentry from "@sentry/nextjs";
import { isIgnorableNextDevHmrError } from "./lib/sentry/ignore-dev-hmr";
import { isIgnorableBrowserNoiseError } from "./lib/sentry/ignore-browser-noise";
import { isIgnorableMicrosoftTranslatorHydration } from "./lib/sentry/ignore-translator-noise";
import { isProviderResponseErrorHint, liftProviderErrorDetail } from "./lib/sentry/provider-error-detail";
import { redactSentryBreadcrumb, redactSentryEvent, redactSentrySpan } from "./lib/sentry/redact-url";
import { installLocalStorageQuotaGuard } from "./lib/infra/storage/quota-reclaim";

// Installed at the earliest client entry point rather than lazily, because the code that suffers
// most from a full localStorage quota is third-party SDK code we cannot reach into. The guard has
// to already be in place when their first write fails.
installLocalStorageQuotaGuard();

// Error reporting is opt-in: with no DSN configured, Sentry.init installs a client that sends
// nothing, so a default deployment reports nowhere.
Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  environment: process.env.NEXT_PUBLIC_SENTRY_ENVIRONMENT ?? process.env.NODE_ENV,
  release: process.env.NEXT_PUBLIC_APP_VERSION,
  tracesSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,
  replaysSessionSampleRate: 0.01,
  // The default depth of 3 stops one level above `contexts.<name>.<field>[i]`, and objects below
  // the cut are replaced in place with the literal "[Object]" without any warning. Diagnostic
  // context that lives in an array is invisible at the default.
  normalizeDepth: 5,
  integrations: [
    Sentry.replayIntegration({
      // This control only resets local state. The click and the replay are still recorded; it just
      // should not be reported as a slow or rage click.
      slowClickIgnoreSelectors: [
        '[data-sentry-ignore-slow-click="sync-state-reset"]',
      ],
    }),
    Sentry.browserTracingIntegration(),
  ],
  beforeSend(event, hint) {
    if (isProviderResponseErrorHint(hint)) return null;
    if (isIgnorableNextDevHmrError(event, hint)) return null;
    if (isIgnorableBrowserExtensionError(event)) return null;
    // A bot-check script injected by a CDN can throw on its own internals, such as reading
    // contentWindow of an iframe it already removed. None of it is application code.
    if (isIgnorableCloudflareChallengeError(event)) return null;
    if (isIgnorableMicrosoftTranslatorHydration(event)) return null;
    if (isIgnorableMobileBrowserInjection(event)) return null;
    if (isIgnorableBrowserNoiseError(event)) return null;
    return redactSentryEvent(liftProviderErrorDetail(event, hint));
  },
  beforeBreadcrumb: redactSentryBreadcrumb,
  // Browser tracing records outgoing fetch URLs on spans, so the same redaction applies here.
  beforeSendSpan: redactSentrySpan,
});

export const onRouterTransitionStart = Sentry.captureRouterTransitionStart;
