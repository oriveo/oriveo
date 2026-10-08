/**
 * Keeps React able to unmount a hoistable element after someone else removed it from <head>.
 *
 * Why this is needed:
 * React 19 hoists `<title>`, `<meta>` and `<link>` rendered anywhere in the tree into `<head>`
 * (HostHoistable). The Next.js App Router renders metadata and viewport this way, so every route
 * change unmounts the previous set. Unmounting one of these nodes is a single unguarded
 *   `instance.parentNode.removeChild(instance)`
 * (`case 26` of `commitDeletionEffectsOnFiber` in react-dom). Ordinary host nodes take a
 * different path that carries a `hostParent` and throws `NotFoundError` when a third party moved
 * them; only hoistables throw
 * `TypeError: Cannot read properties of null (reading 'removeChild')`.
 *
 * As soon as any non-React code detaches such a node, the next route change throws in the middle
 * of the commit. The error never reaches an error boundary (it is not in the render phase), the
 * root is left half committed, and every later commit containing the same deletions throws
 * again. The page does not go blank, but navigation and list clicks stop working until a reload,
 * after which the offending script does the same thing again.
 *
 * A known offender is the desktop mode of some mobile browsers: the injected script removes
 * every `<meta name="viewport">` on the page, including the one Next.js rendered, and inserts
 * its own fixed-width one. Forced-zoom, reader-mode and ad-blocking extensions that rewrite the
 * viewport, title or favicon behave the same way.
 *
 * What it does:
 * It watches direct children being removed from `<head>`. A removed `<title>`, `<meta>` or
 * `<link>` that still has no parent is immediately placed in a DocumentFragment of its own:
 *  - `parentNode` is no longer null, so React's later `parentNode.removeChild(node)` succeeds;
 *  - the node stays out of the document (`isConnected === false`), so the page is unaffected and
 *    the third-party script's intent is not fought;
 *  - the fragment and the node only reference each other, so once React releases the fiber the
 *    pair is collected and nothing accumulates.
 * Nodes React removed itself are treated the same way, which is equally harmless and means no
 * React internals (`__reactFiber$*`) have to be read to tell the two apart.
 *
 * Observer callbacks are microtasks. The third-party removal and React's commit never share one
 * synchronous run, so the callback always goes first.
 *
 * Why a subpath export instead of the `@oriveo/shared` index:
 * `@oriveo/core` compiles the shared index without the DOM lib because it has to run in workers.
 * This file is browser-only and is imported solely through
 * `@oriveo/shared/browser/detached-hoistable-guard`.
 *
 * When it can go:
 * Once react-dom null-checks the removal in `case 26`. `detached-hoistable-guard.test.tsx` has an
 * assertion that React does throw without the guard; it turns red the day React fixes this, and
 * this file can be deleted along with it.
 */

const GUARDED_TAGS = new Set(['TITLE', 'META', 'LINK']);

const installedHeads = new WeakMap<Node, () => void>();

function adoptIfDetached(node: Node, doc: Document): void {
  if (node.nodeType !== 1) return;
  if (!GUARDED_TAGS.has((node as Element).tagName.toUpperCase())) return;
  // Leave alone a node that was removed and re-inserted within the same batch of mutations.
  if (node.parentNode !== null) return;
  doc.createDocumentFragment().appendChild(node);
}

/**
 * Call once at the earliest client entry point (Next.js `instrumentation-client.ts`, which runs
 * before hydration). Repeated calls are idempotent; the return value uninstalls the guard, which
 * tests use. Does nothing outside a browser or without MutationObserver.
 */
export function installDetachedHoistableGuard(doc?: Document): () => void {
  const targetDoc = doc ?? (typeof document === 'undefined' ? undefined : document);
  if (!targetDoc || typeof MutationObserver === 'undefined') return () => {};
  const head = targetDoc.head;
  if (!head) return () => {};

  const existing = installedHeads.get(head);
  if (existing) return existing;

  const observer = new MutationObserver((records) => {
    for (const record of records) {
      record.removedNodes.forEach((node) => adoptIfDetached(node, targetDoc));
    }
  });
  observer.observe(head, { childList: true });

  const uninstall = () => {
    observer.disconnect();
    installedHeads.delete(head);
  };
  installedHeads.set(head, uninstall);
  return uninstall;
}
