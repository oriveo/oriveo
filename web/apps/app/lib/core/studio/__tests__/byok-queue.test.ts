// @vitest-environment node
/**
 * createStudioByokQueue: per-device concurrency of 4, cancel semantics
 * (queued never runs, running is aborted and may be billed) and late
 * responses of cancelled rounds being dropped.
 */
import { describe, expect, it } from 'vitest';
import { createStudioByokQueue, type StudioByokQueueUpdate } from '../byok-queue';

interface Deferred {
  resolve: (value: string) => void;
  reject: (error: unknown) => void;
  signal: AbortSignal;
}

function setup() {
  const pending = new Map<string, Deferred>();
  const runCalls: string[] = [];
  const updates: Array<[string, StudioByokQueueUpdate<string>]> = [];
  const queue = createStudioByokQueue<string>({
    run: (id, signal) => {
      runCalls.push(id);
      return new Promise<string>((resolve, reject) => {
        pending.set(id, { resolve, reject, signal });
      });
    },
    onUpdate: (id, update) => {
      updates.push([id, update]);
    },
  });
  return { queue, pending, runCalls, updates };
}

const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

function typesFor(updates: Array<[string, StudioByokQueueUpdate<string>]>, id: string): string[] {
  return updates.filter(([who]) => who === id).map(([, update]) => update.type);
}

describe('createStudioByokQueue', () => {
  describe('concurrency', () => {
    it('starts four rounds, queues the fifth, and starts it when one finishes', async () => {
      const { queue, pending, runCalls, updates } = setup();
      for (const id of ['a', 'b', 'c', 'd', 'e']) queue.submit(id);

      expect(runCalls).toEqual(['a', 'b', 'c', 'd']);
      expect(queue.snapshot()).toEqual({ running: ['a', 'b', 'c', 'd'], queued: ['e'] });
      expect(updates.filter(([, update]) => update.type === 'started').map(([id]) => id)).toEqual([
        'a',
        'b',
        'c',
        'd',
      ]);
      expect(typesFor(updates, 'e')).toEqual(['queued']);

      pending.get('b')?.resolve('result-b');
      await flush();

      expect(updates).toContainEqual(['b', { type: 'result', result: 'result-b' }]);
      expect(runCalls).toEqual(['a', 'b', 'c', 'd', 'e']);
      expect(typesFor(updates, 'e')).toEqual(['queued', 'started']);
      expect(queue.snapshot()).toEqual({ running: ['a', 'c', 'd', 'e'], queued: [] });
    });

    it('reports failed and frees the slot when run throws anyway', async () => {
      const { queue, pending, runCalls, updates } = setup();
      for (const id of ['a', 'b', 'c', 'd', 'e']) queue.submit(id);

      pending.get('a')?.reject(new Error('boom'));
      await flush();

      expect(typesFor(updates, 'a')).toEqual(['started', 'failed']);
      expect(runCalls).toContain('e');
      expect(queue.snapshot()).toEqual({ running: ['b', 'c', 'd', 'e'], queued: [] });
    });
  });

  describe('cancel', () => {
    it('cancels a queued round without ever calling run and without billing', async () => {
      const { queue, pending, runCalls, updates } = setup();
      for (const id of ['a', 'b', 'c', 'd', 'e']) queue.submit(id);

      queue.cancel('e');
      expect(updates).toContainEqual(['e', { type: 'cancelled', mayBeBilled: false }]);
      expect(queue.snapshot()).toEqual({ running: ['a', 'b', 'c', 'd'], queued: [] });

      pending.get('a')?.resolve('result-a');
      await flush();

      expect(runCalls).not.toContain('e');
      expect(typesFor(updates, 'e')).toEqual(['queued', 'cancelled']);
    });

    it('aborts a running round, reports it as possibly billed, and promotes the next one', () => {
      const { queue, pending, runCalls, updates } = setup();
      for (const id of ['a', 'b', 'c', 'd', 'e']) queue.submit(id);

      queue.cancel('c');

      expect(pending.get('c')?.signal.aborted).toBe(true);
      expect(pending.get('a')?.signal.aborted).toBe(false);
      expect(updates).toContainEqual(['c', { type: 'cancelled', mayBeBilled: true }]);
      expect(runCalls).toEqual(['a', 'b', 'c', 'd', 'e']);
      expect(queue.snapshot()).toEqual({ running: ['a', 'b', 'd', 'e'], queued: [] });
    });
  });

  describe('run failure', () => {
    it('emits one failed update carrying the rejection and frees the slot', async () => {
      const { queue, pending, runCalls, updates } = setup();
      for (const id of ['a', 'b', 'c', 'd', 'e']) queue.submit(id);

      const error = new Error('boom');
      pending.get('b')?.reject(error);
      await flush();

      expect(updates.filter(([who, update]) => who === 'b' && update.type === 'failed')).toEqual([
        ['b', { type: 'failed', error }],
      ]);
      expect(typesFor(updates, 'b')).toEqual(['started', 'failed']);
      expect(runCalls).toEqual(['a', 'b', 'c', 'd', 'e']);
      expect(queue.snapshot()).toEqual({ running: ['a', 'c', 'd', 'e'], queued: [] });
    });

    it('emits failed with the thrown value when run throws synchronously', async () => {
      const error = new Error('sync boom');
      const updates: Array<[string, StudioByokQueueUpdate<string>]> = [];
      const queue = createStudioByokQueue<string>({
        run: (id) => {
          if (id === 'a') throw error;
          return new Promise<string>(() => {});
        },
        onUpdate: (id, update) => {
          updates.push([id, update]);
        },
      });
      for (const id of ['a', 'b', 'c', 'd', 'e']) queue.submit(id);
      await flush();

      expect(updates.filter(([who]) => who === 'a')).toEqual([
        ['a', { type: 'started' }],
        ['a', { type: 'failed', error }],
      ]);
      expect(queue.snapshot()).toEqual({ running: ['b', 'c', 'd', 'e'], queued: [] });
    });

    it('does not emit failed for a round that was cancelled before it rejected', async () => {
      const { queue, pending, updates } = setup();
      for (const id of ['a', 'b', 'c', 'd', 'e', 'f']) queue.submit(id);

      queue.cancel('a');
      pending.get('a')?.reject(new Error('late boom'));
      await flush();

      expect(typesFor(updates, 'a')).toEqual(['started', 'cancelled']);
      expect(updates.some(([, update]) => update.type === 'failed')).toBe(false);
      expect(queue.snapshot()).toEqual({ running: ['b', 'c', 'd', 'e'], queued: ['f'] });
    });
  });

  describe('late response', () => {
    it('drops the result of a round that was cancelled while running', async () => {
      const { queue, pending, updates } = setup();
      for (const id of ['a', 'b', 'c', 'd', 'e', 'f']) queue.submit(id);

      queue.cancel('a');
      pending.get('a')?.resolve('late-a');
      await flush();

      expect(typesFor(updates, 'a')).toEqual(['started', 'cancelled']);
      expect(updates.some(([, update]) => update.type === 'result')).toBe(false);
      expect(queue.snapshot()).toEqual({ running: ['b', 'c', 'd', 'e'], queued: ['f'] });
    });
  });
});
