/**
 * Minimal structural subset of a Sentry Event, holding only the fields the browser and mobile
 * browser injection filters read.
 *
 * It is defined inside `@oriveo/shared` on purpose rather than depending on `@sentry/nextjs`, so
 * the shared package carries no runtime Sentry dependency and importing it from the server, from
 * tests, or from tooling scripts does not pull in the whole Sentry browser SDK.
 *
 * The `beforeSend(event)` hooks in the apps pass `Sentry.Event` straight to the filter functions:
 * on the fields used here the Sentry Event type is a structural superset of SentryEventLike, so
 * TypeScript structural typing adapts it with no `as` cast.
 */
export interface SentryEventLike {
  message?: unknown;
  exception?: {
    values?: ReadonlyArray<SentryExceptionLike | null | undefined>;
  };
  // In the Sentry SDK contexts is a `Record<string, Context>` (an index signature). Only
  // browser.name matters here, but a structural subset needs `& Record<string, unknown>` for the
  // Sentry Contexts type to stay compatible, otherwise TypeScript reports "no properties in common".
  contexts?: {
    browser?: { name?: string };
  } & Record<string, unknown>;
  request?: {
    // Matches RequestEventData.headers in the Sentry SDK: `{ [key: string]: string }`
    headers?: Record<string, string>;
  };
  tags?: Record<string, unknown>;
}

export interface SentryExceptionLike {
  type?: string;
  value?: string;
  stacktrace?: {
    frames?: ReadonlyArray<SentryStackFrameLike | null | undefined>;
  };
}

export interface SentryStackFrameLike {
  filename?: string;
  abs_path?: string;
  function?: string;
}
