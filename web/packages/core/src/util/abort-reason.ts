/**
 * Unified abort reason for AbortControllers owned by this app.
 *
 * **Why a reason is required**: a bare `controller.abort()` makes the browser build its own
 * DOMException, whose message is word-for-word the same as the one vendor SDKs produce when
 * they tear down their own connections (Chrome `signal is aborted without reason` /
 * `The user aborted a request.`, Safari `Fetch is aborted`). Those vendor aborts can escape to
 * window.onunhandledrejection as pure noise, and the stack alone cannot tell them apart from
 * our own aborts. Any filter would have to rely on a probabilistic signal, and loosening it
 * slightly would swallow the aborts we actually want to see.
 *
 * Once every abort we own carries the `oriveo:` prefix, a bare message logically cannot come
 * from us, so the filter becomes exclusive instead of probabilistic.
 *
 * Only controllers whose aborts can escape to the global unhandledrejection in the browser are
 * constrained; server routes (Next.js route handlers) and the desktop main process are out of scope.
 */

/** Message prefix of our own aborts. Filters rely on it being exclusive; changing it loosens them. */
export const ORIVEO_ABORT_REASON_PREFIX = "oriveo:";

/**
 * Builds an AbortError annotated with its purpose.
 *
 * `name` stays `AbortError`, so every existing `err.name === 'AbortError'` check keeps working;
 * only `message` changes, and it also becomes `signal.reason`, propagating per spec to the
 * rejections on both the fetch promise and the response body stream.
 *
 * @param purpose Short kebab-case purpose, e.g. `chat-stream-cancel`, `relay-probe-superseded`.
 */
export function oriveoAbortReason(purpose: string): DOMException {
  return new DOMException(`${ORIVEO_ABORT_REASON_PREFIX}${purpose}`, "AbortError");
}
