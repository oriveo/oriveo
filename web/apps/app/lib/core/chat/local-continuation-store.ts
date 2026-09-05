/**
 * Browser-only opaque continuation store.
 *
 * Incomplete tool loops are marked interrupted and are never resumed by a
 * later page process. This lives in the Web app rather than @oriveo/core so
 * the runtime-agnostic package does not acquire an IndexedDB dependency.
 */
export interface LocalContinuationRecord {
  conversationId: string;
  messageId: string;
  sessionId: string;
  state: Record<string, unknown>;
  interrupted?: boolean;
}

export type LocalContinuationWrite = Omit<LocalContinuationRecord, "sessionId">;

const DB = "oriveo-continuation-v1";
const STORE = "message-state";

export class LocalContinuationStore {
  constructor(private readonly sessionId: string) {
    if (!sessionId) throw new Error("Continuation session id is required");
  }

  async save(record: LocalContinuationWrite | LocalContinuationRecord): Promise<void> {
    const db = await open();
    await request(
      db.transaction(STORE, "readwrite").objectStore(STORE).put({
        ...record,
        sessionId: this.sessionId,
      }),
    );
    db.close();
  }

  async load(conversationId: string, messageId: string): Promise<LocalContinuationRecord | null> {
    const db = await open();
    const value = await request(
      db.transaction(STORE).objectStore(STORE).get(key(conversationId, messageId)),
    );
    db.close();
    return valid(value) && value.sessionId === this.sessionId ? value : null;
  }

  async deleteMessage(conversationId: string, messageId: string): Promise<void> {
    const db = await open();
    await request(
      db.transaction(STORE, "readwrite").objectStore(STORE).delete(key(conversationId, messageId)),
    );
    db.close();
  }

  async deleteConversation(conversationId: string): Promise<void> {
    const db = await open();
    const transaction = db.transaction(STORE, "readwrite");
    await cursorDelete(
      transaction.objectStore(STORE),
      (record) => record.conversationId === conversationId,
    );
    db.close();
  }

  /** Persist the interruption fact while forbidding automatic continuation. */
  async interruptToolLoop(conversationId: string, messageId: string): Promise<void> {
    const current = await this.load(conversationId, messageId);
    if (current) await this.save({ ...current, interrupted: true });
  }
}

function key(conversationId: string, messageId: string): [string, string] {
  return [conversationId, messageId];
}

function open(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") {
    return Promise.reject(new Error("IndexedDB unavailable"));
  }
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore(STORE, { keyPath: ["conversationId", "messageId"] });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function request<T>(operation: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    operation.onsuccess = () => resolve(operation.result);
    operation.onerror = () => reject(operation.error);
  });
}

function cursorDelete(
  store: IDBObjectStore,
  predicate: (record: LocalContinuationRecord) => boolean,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = store.openCursor();
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const cursor = request.result;
      if (!cursor) {
        resolve();
        return;
      }
      if (valid(cursor.value) && predicate(cursor.value)) cursor.delete();
      cursor.continue();
    };
  });
}

function valid(value: unknown): value is LocalContinuationRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<LocalContinuationRecord>;
  return typeof record.conversationId === "string"
    && typeof record.messageId === "string"
    && typeof record.sessionId === "string"
    && typeof record.state === "object"
    && record.state !== null;
}
