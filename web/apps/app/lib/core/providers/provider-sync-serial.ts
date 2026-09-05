/**
 * A provider's active record and its tombstone are the same entity, so the local decision and any
 * write that follows it stay ordered per account: two edits to the same provider cannot interleave
 * and leave the last write disagreeing with the state that produced it.
 */
const providerSyncTails = new Map<string, Promise<void>>();

export async function serializeProviderSyncMutation<T>(
  uid: string,
  mutation: () => Promise<T> | T,
): Promise<T> {
  const previous = providerSyncTails.get(uid) ?? Promise.resolve();
  const current = previous.catch(() => undefined).then(mutation);
  const tail = current.then(() => undefined, () => undefined);
  providerSyncTails.set(uid, tail);

  try {
    return await current;
  } finally {
    if (providerSyncTails.get(uid) === tail) {
      providerSyncTails.delete(uid);
    }
  }
}
