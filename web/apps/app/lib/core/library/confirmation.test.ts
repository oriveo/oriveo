import { describe, expect, it, vi } from 'vitest';
import { createAppStore } from '../store/app-store';
import {
  cancelPendingLibraryConfirmation,
  clearOwnLibraryConfirmation,
  requestLibraryConfirmation,
  resolveLibraryConfirmation,
} from './confirmation';
import type { LibraryConfirmationRequest } from './types';

function request(id: string): LibraryConfirmationRequest {
  return { id, reason: 'sensitive', detail: {} };
}

/** The queue is a module-level singleton, so each test drains it and leaves no pending confirmation for the next one. */
function drainQueue(): void {
  for (let i = 0; i < 8; i += 1) cancelPendingLibraryConfirmation();
}

// A later confirmation must not settle('cancel') the previous one: the user clicked nothing, yet
// the other conversation waiting on a confirmation would be reported as cancelled. With concurrent
// background streams across conversations this is the normal case, not an edge case.
describe('requestLibraryConfirmation queueing', () => {
  it('queues a second session behind the first instead of cancelling it', async () => {
    const store = createAppStore({});
    const controllerA = new AbortController();
    const controllerB = new AbortController();
    const settledA = vi.fn();
    const settledB = vi.fn();

    const pendingA = requestLibraryConfirmation(store, request('a'), controllerA.signal);
    void pendingA.then(settledA);
    const pendingB = requestLibraryConfirmation(store, request('b'), controllerB.signal);
    void pendingB.then(settledB);

    await Promise.resolve();
    expect(settledA).not.toHaveBeenCalled();
    // A queued B does not steal the screen; A is still the one shown
    expect(store.getState().libraryConfirmation?.id).toBe('a');

    // The user hits continue on A's dialog, so A gets its answer and B moves up
    resolveLibraryConfirmation('continue');
    expect(await pendingA).toBe('continue');
    expect(store.getState().libraryConfirmation?.id).toBe('b');
    expect(settledB).not.toHaveBeenCalled();

    resolveLibraryConfirmation('redact');
    expect(await pendingB).toBe('redact');
    expect(store.getState().libraryConfirmation).toBeNull();

    drainQueue();
  });

  it('aborts only the confirmation whose signal fired', async () => {
    const store = createAppStore({});
    const controllerA = new AbortController();
    const controllerB = new AbortController();

    const pendingA = requestLibraryConfirmation(store, request('a'), controllerA.signal);
    const settledA = vi.fn();
    void pendingA.then(settledA);
    const pendingB = requestLibraryConfirmation(store, request('b'), controllerB.signal);
    const settledB = vi.fn();
    void pendingB.then(settledB);

    // B joining the queue must not touch A; only A's own signal may cancel it
    await Promise.resolve();
    expect(settledA).not.toHaveBeenCalled();

    controllerA.abort();

    expect(await pendingA).toBe('cancel');
    await Promise.resolve();
    expect(settledB).not.toHaveBeenCalled();
    // B is shown immediately once A leaves the queue
    expect(store.getState().libraryConfirmation?.id).toBe('b');

    resolveLibraryConfirmation('continue');
    expect(await pendingB).toBe('continue');
    drainQueue();
  });

  it('drops an already-aborted request without disturbing the on-screen confirmation', async () => {
    const store = createAppStore({});
    const controllerA = new AbortController();
    const aborted = new AbortController();
    aborted.abort();

    const pendingA = requestLibraryConfirmation(store, request('a'), controllerA.signal);
    expect(await requestLibraryConfirmation(store, request('dead'), aborted.signal)).toBe('cancel');

    expect(store.getState().libraryConfirmation?.id).toBe('a');
    resolveLibraryConfirmation('continue');
    expect(await pendingA).toBe('continue');
    drainQueue();
  });

  // A single send can raise two prompts in a row, for example broad_read followed by sensitive
  it('still answers the confirmation the user is looking at within one send', async () => {
    const store = createAppStore({});
    const controller = new AbortController();

    const first = requestLibraryConfirmation(store, request('step-1'), controller.signal);
    resolveLibraryConfirmation('continue');
    expect(await first).toBe('continue');
    expect(store.getState().libraryConfirmation).toBeNull();

    const second = requestLibraryConfirmation(store, request('step-2'), controller.signal);
    expect(store.getState().libraryConfirmation?.id).toBe('step-2');
    controller.abort();
    expect(await second).toBe('cancel');
    expect(store.getState().libraryConfirmation).toBeNull();
    drainQueue();
  });
});

describe('clearOwnLibraryConfirmation', () => {
  // Sends in different conversations must not abort each other: clearing unconditionally when
  // conversation A finishes normally would wipe the dialog conversation B is waiting on, and B's
  // promise only settles on resolve or abort, so B's send would hang forever
  it('leaves another send-in-flight confirmation on screen', () => {
    const store = createAppStore({});
    const controller = new AbortController();
    const pending = requestLibraryConfirmation(store, request('other-session'), controller.signal);
    const settled = vi.fn();
    void pending.then(settled);

    clearOwnLibraryConfirmation(store, new Set(['mine']));

    expect(store.getState().libraryConfirmation?.id).toBe('other-session');
    expect(settled).not.toHaveBeenCalled();
    resolveLibraryConfirmation('cancel');
  });

  it('clears the confirmation this send actually raised', () => {
    const store = createAppStore({});
    const controller = new AbortController();
    void requestLibraryConfirmation(store, request('mine'), controller.signal);

    clearOwnLibraryConfirmation(store, new Set(['mine']));

    expect(store.getState().libraryConfirmation).toBeNull();
    resolveLibraryConfirmation('cancel');
  });
});
