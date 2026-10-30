import 'fake-indexeddb/auto';
import { deleteDB } from 'idb';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { openDB } from '../idb-open';

// idb eagerly creates tx.done for every transaction; the read shortcuts never subscribe to it.
// When a transaction aborts with a null tx.error (WebKit commit failure / explicit abort), done rejects with
// DOMException('AbortError','AbortError') and, unobserved, surfaces as a global unhandledrejection.

const DB_NAME = 'idb-open-guard-test';

async function collectUnhandled(run: () => Promise<void>): Promise<unknown[]> {
  const seen: unknown[] = [];
  const onUnhandled = (reason: unknown) => { seen.push(reason); };
  process.on('unhandledRejection', onUnhandled);
  try {
    await run();
    // unhandledRejection is dispatched after a macrotask boundary; leave a few turns.
    await new Promise((resolve) => setTimeout(resolve, 30));
  } finally {
    process.off('unhandledRejection', onUnhandled);
  }
  return seen;
}

async function openTestDB() {
  return openDB(DB_NAME, 1, {
    upgrade(db) {
      db.createObjectStore('kv');
    },
  });
}

/** Captures the next native transaction from db.transaction so the test can abort it before the request completes. */
function captureNextTransaction(): { get: () => IDBTransaction | undefined; restore: () => void } {
  const proto = IDBDatabase.prototype;
  const original = proto.transaction;
  let captured: IDBTransaction | undefined;
  const spy = vi.spyOn(proto, 'transaction').mockImplementation(function (this: IDBDatabase, ...args) {
    const tx = original.apply(this, args as Parameters<IDBDatabase['transaction']>);
    captured ??= tx;
    return tx;
  });
  return { get: () => captured, restore: () => spy.mockRestore() };
}

afterEach(async () => {
  vi.restoreAllMocks();
  await deleteDB(DB_NAME);
});

describe('openDB guard', () => {
  it('an aborted read-shortcut transaction does not leak its unobserved tx.done as an unhandled rejection', async () => {
    const db = await openTestDB();
    const next = captureNextTransaction();
    let readError: unknown;
    const leaked = await collectUnhandled(async () => {
      const read = db.get('kv', 'missing');
      const tx = next.get();
      expect(tx).toBeDefined();
      tx!.abort();
      expect(tx!.error).toBeNull();
      readError = await read.catch((error: unknown) => error);
    });
    next.restore();
    db.close();
    // The request failure itself still reaches the caller.
    expect((readError as DOMException).name).toBe('AbortError');
    expect(leaked).toEqual([]);
  });

  it('callers that subscribe to tx.done still get AbortError (the guard does not change the outcome)', async () => {
    const db = await openTestDB();
    const tx = db.transaction('kv', 'readwrite');
    void tx.store.put('v', 'k').catch(() => {});
    tx.abort();
    const error = await tx.done.then(() => null, (e: unknown) => e);
    db.close();
    expect((error as DOMException).name).toBe('AbortError');
    expect((error as DOMException).message).toBe('AbortError');
  });

  it('a failed write-shortcut transaction still rejects for the caller', async () => {
    const db = await openTestDB();
    const next = captureNextTransaction();
    const write = db.put('kv', 'v', 'k');
    next.get()!.abort();
    await expect(write).rejects.toMatchObject({ name: 'AbortError' });
    next.restore();
    db.close();
  });

  it('an aborted upgrade fails the open for the caller without leaking done', async () => {
    let openError: unknown;
    const leaked = await collectUnhandled(async () => {
      openError = await openDB(DB_NAME, 1, {
        upgrade(_db, _old, _new, transaction) {
          transaction.abort();
        },
      }).then(() => null, (e: unknown) => e);
    });
    expect((openError as DOMException).name).toBe('AbortError');
    expect(leaked).toEqual([]);
  });
});
