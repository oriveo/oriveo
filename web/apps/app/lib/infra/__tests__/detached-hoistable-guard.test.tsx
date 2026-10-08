/**
 * A route change must survive a third-party script detaching nodes React hoisted into <head>.
 *
 * Everything renders and unmounts through the real react-dom with no React mocks, because the
 * path under test is React unmounting a hoistable node. The sequence mirrors what happens in the
 * field: the framework renders `<meta name="viewport">`, a mobile browser's desktop-mode script
 * removes every viewport meta and inserts its own, the user navigates, and React unmounts the
 * previous page's metadata.
 */
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { installDetachedHoistableGuard } from '@oriveo/shared/browser/detached-hoistable-guard';

function Page({ name }: { name: string }) {
  return (
    <main>
      <meta charSet="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>{name}</title>
      <p>{name}</p>
    </main>
  );
}

/** Stand-in for a desktop-mode injected script: removes every viewport meta, then inserts its own. */
function desktopModeRewritesViewport() {
  const own = document.createElement('meta');
  own.setAttribute('name', 'viewport');
  own.setAttribute('content', 'width=1280, user-scalable=1');
  own.setAttribute('data-width', '1280');
  document.head.querySelectorAll('meta[name="viewport"]').forEach((meta) => meta.remove());
  document.head.appendChild(own);
  return own;
}

const flushMutationObservers = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

describe('installDetachedHoistableGuard', () => {
  let container: HTMLDivElement;
  let root: Root;
  let uninstall: () => void = () => {};

  beforeEach(() => {
    document.head.innerHTML = '';
    container = document.createElement('div');
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(() => {
    uninstall();
    uninstall = () => {};
    act(() => root.unmount());
    container.remove();
    document.head.innerHTML = '';
  });

  it('without the guard, React throws a TypeError when unmounting a hoistable a third party detached', async () => {
    // This pins a defect in react-dom itself. If it turns red, React now null-checks this path
    // and the guard can be removed.
    await act(async () => root.render(<Page key="a" name="A" />));
    const reactViewport = document.head.querySelector('meta[content^="width=device-width"]');
    expect(reactViewport).not.toBeNull();

    const hoistedByReact = Array.from(document.head.querySelectorAll('title, meta, link'));
    desktopModeRewritesViewport();
    await flushMutationObservers();

    let thrown: unknown;
    try {
      await act(async () => root.render(<Page key="b" name="B" />));
    } catch (error) {
      thrown = error;
    }
    expect(thrown).toBeInstanceOf(TypeError);
    expect(String((thrown as Error).message)).toMatch(/removeChild/);

    // The commit threw halfway: React already removed the nodes ahead of the failing one, so every
    // later commit on this root throws again at an earlier position (which is why nothing responds
    // afterwards) and would leak into the next test through the global act queue. Give every
    // detached node a parent by hand so this root can unmount normally.
    for (const node of hoistedByReact) {
      if (node.parentNode === null) document.createDocumentFragment().appendChild(node);
    }
  });

  it('with the guard, the same sequence completes the route change without putting removed nodes back in the document', async () => {
    uninstall = installDetachedHoistableGuard();
    await act(async () => root.render(<Page key="a" name="A" />));
    const reactViewport = document.head.querySelector('meta[content^="width=device-width"]');
    expect(reactViewport).not.toBeNull();

    const injectedViewport = desktopModeRewritesViewport();
    await flushMutationObservers();

    // The detached node has a parent again, which is what lets React remove it later, yet it is
    // still outside the document.
    expect(reactViewport?.parentNode).not.toBeNull();
    expect(reactViewport?.isConnected).toBe(false);
    expect(injectedViewport.parentNode).toBe(document.head);

    await act(async () => root.render(<Page key="b" name="B" />));

    expect(container.querySelector('p')?.textContent).toBe('B');
    expect(document.title).toBe('B');
    // The new page mounts its own viewport as usual; the third-party one is left untouched.
    expect(injectedViewport.isConnected).toBe(true);
    // After React removes it the old node is fully detached; the guard does not adopt it again
    // and leak it.
    expect(reactViewport?.isConnected).toBe(false);
  });

  it('survives repeated render, rewrite and navigate rounds, since the script rewrites on every navigation', async () => {
    uninstall = installDetachedHoistableGuard();
    for (const name of ['A', 'B', 'C', 'D']) {
      await act(async () => root.render(<Page key={name} name={name} />));
      desktopModeRewritesViewport();
      await flushMutationObservers();
    }
    await act(async () => root.render(<Page key="end" name="End" />));
    expect(container.querySelector('p')?.textContent).toBe('End');
  });

  it('also protects a title or link that a third party detached', async () => {
    uninstall = installDetachedHoistableGuard();
    function WithLink() {
      return (
        <main>
          <title>with-link</title>
          <link rel="icon" href="/favicon.ico" />
        </main>
      );
    }
    await act(async () => root.render(<WithLink />));
    document.head.querySelector('title')?.remove();
    document.head.querySelector('link[rel="icon"]')?.remove();
    await flushMutationObservers();

    await act(async () => root.render(<Page key="next" name="Next" />));
    expect(container.querySelector('p')?.textContent).toBe('Next');
  });

  it('leaves alone nodes re-inserted within the same batch and tags that are not hoistable', async () => {
    uninstall = installDetachedHoistableGuard();
    const meta = document.createElement('meta');
    meta.setAttribute('name', 'theme-color');
    const script = document.createElement('script');
    document.head.append(meta, script);

    meta.remove();
    document.head.appendChild(meta);
    script.remove();
    await flushMutationObservers();

    expect(meta.parentNode).toBe(document.head);
    expect(script.parentNode).toBeNull();
  });

  it('is idempotent when installed more than once', () => {
    const first = installDetachedHoistableGuard();
    const second = installDetachedHoistableGuard();
    expect(second).toBe(first);
    uninstall = first;
  });
});
