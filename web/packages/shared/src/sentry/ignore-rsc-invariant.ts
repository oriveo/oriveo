import type { SentryEventLike } from './types';

/**
 * Known Next.js App Router framework noise: on a client-side soft navigation or prefetch that
 * hits a 404 (notFound), the router requests an RSC payload while the server returns `text/html`
 * for not-found, so the RSC parser throws
 * `Invariant: Expected RSC response, got text/html` (the message itself claims "This is a bug in
 * Next.js").
 *
 * Nothing at the application layer can prevent it: it comes from external crawlers, bots, stale
 * inbound links or hand-typed URLs hitting a localized route that does not exist, such as a
 * localized SEO path that is an intentional notFound stub, absent from the sitemap and not
 * linked internally. Zero actionable signal, so the whole class is dropped.
 *
 * Only for purely static, deterministic sites; not for the app, where it would mask real
 * navigation bugs.
 */
export function isRscNotFoundInvariantEvent(event: SentryEventLike): boolean {
  const exception = event.exception?.values?.[0];
  const message =
    exception?.value ?? (typeof event.message === 'string' ? event.message : '');
  return /Expected RSC response, got text\/html/i.test(message);
}
