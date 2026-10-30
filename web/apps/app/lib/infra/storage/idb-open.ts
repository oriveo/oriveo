import {
  openDB as idbOpenDB,
  unwrap,
  wrap,
  type DBSchema,
  type IDBPDatabase,
  type OpenDBCallbacks,
} from 'idb';

/**
 * The only `openDB` entry point for app code: every transaction's `tx.done` is marked as handled up front.
 *
 * idb **eagerly creates** `tx.done` whenever it wraps a transaction, whether or not the caller uses it.
 * The read shortcuts (`db.get` / `getAll` / `count` / `*FromIndex`) only consume the request result and
 * never subscribe to `tx.done`. When the transaction aborts after its requests succeeded without setting
 * `tx.error` (WebKit's commit failure `didCommit(error)`, `didStart(error)` and context stop all leave it
 * null), `tx.done` rejects with `new DOMException('AbortError', 'AbortError')`, and with no listener it
 * surfaces as a stackless global unhandledrejection. WKWebView-based in-app browsers hit this when backgrounded.
 *
 * This only stops an unsubscribed `done` from escaping: callers that `await tx.done` or
 * `Promise.all([..., tx.done])` still receive the rejection and take their normal error path
 * (marking a promise handled does not change its outcome).
 */

const guardedDatabases = new WeakSet<object>();
const noop = () => {};

function observeDone(tx: { done: Promise<void> }): void {
  tx.done.catch(noop);
}

function guardDatabase<DBTypes extends DBSchema | unknown>(db: IDBPDatabase<DBTypes>): IDBPDatabase<DBTypes> {
  const raw = unwrap(db) as IDBDatabase;
  if (guardedDatabases.has(raw)) return db;
  guardedDatabases.add(raw);
  // idb's proxy reads `transaction` off the target, and the read shortcuts call `this.transaction` too,
  // so shadowing the prototype method on the instance covers every entry point. wrap() caches per raw
  // transaction, so it returns the same proxy the caller receives.
  Object.defineProperty(raw, 'transaction', {
    configurable: true,
    writable: true,
    value: function guardedTransaction(this: IDBDatabase, ...args: Parameters<IDBDatabase['transaction']>) {
      const nativeTransaction = (Object.getPrototypeOf(this) as IDBDatabase).transaction;
      const tx = nativeTransaction.apply(this, args);
      observeDone(wrap(tx) as unknown as { done: Promise<void> });
      return tx;
    },
  });
  return db;
}

export function openDB<DBTypes extends DBSchema | unknown = unknown>(
  name: string,
  version?: number,
  callbacks: OpenDBCallbacks<DBTypes> = {},
): Promise<IDBPDatabase<DBTypes>> {
  const { upgrade } = callbacks;
  return idbOpenDB<DBTypes>(name, version, {
    ...callbacks,
    upgrade: upgrade
      ? (database, oldVersion, newVersion, transaction, event) => {
        // An aborted upgrade rejects the open request for the caller; its done has no subscriber either.
        observeDone(transaction);
        return upgrade(database, oldVersion, newVersion, transaction, event);
      }
      : undefined,
  }).then(guardDatabase);
}
