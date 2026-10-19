import { RhoCalibration, RhoCalibrationTable } from '@oriveo/core/context/calibration';
import { CONTEXT_MANIFEST_LOG_LIMIT, type ContextManifest } from '@oriveo/core/context/manifest';
import { getPartitionDB } from './idb';

/*
 * Local storage for the context ledger (idb v11): the rho calibration table and the latest 50 manifests per conversation.
 * Held in this device's partition only, not part of any backup; idb.deleteConversation deletes a conversation's manifests together with it.
 */

/** Read the calibration for (transportInstanceId, modelId); returns the initial value when there is no record. */
export async function getRhoCalibration(transportInstanceId: string, modelId: string): Promise<RhoCalibration> {
  const db = await getPartitionDB();
  const json = await db.get('contextRhoCalibration', [transportInstanceId, modelId]);
  return json ? RhoCalibration.fromJSON(json) : RhoCalibration.initial();
}

export async function putRhoCalibration(
  transportInstanceId: string,
  modelId: string,
  calibration: RhoCalibration,
): Promise<void> {
  const db = await getPartitionDB();
  await db.put('contextRhoCalibration', calibration.toJSON(), [transportInstanceId, modelId]);
}

/** Read the whole table into an in-memory RhoCalibrationTable. */
export async function getRhoCalibrationTable(): Promise<RhoCalibrationTable> {
  const db = await getPartitionDB();
  const tx = db.transaction('contextRhoCalibration');
  const table = new RhoCalibrationTable();
  for await (const cursor of tx.store.iterate()) {
    const [transportInstanceId, modelId] = cursor.key;
    table.set(transportInstanceId, modelId, RhoCalibration.fromJSON(cursor.value));
  }
  await tx.done;
  return table;
}

/** Write one manifest and trim the conversation to the newest CONTEXT_MANIFEST_LOG_LIMIT entries (by createdAt). */
export async function appendContextManifest(manifest: ContextManifest): Promise<void> {
  const db = await getPartitionDB();
  const tx = db.transaction('contextManifests', 'readwrite');
  await tx.store.put(manifest);
  const entries = await tx.store.index('by-conversation').getAll(manifest.conversationId);
  const overflow = entries.length - CONTEXT_MANIFEST_LOG_LIMIT;
  if (overflow > 0) {
    const oldest = sortByCreatedAt(entries).slice(0, overflow);
    await Promise.all(oldest.map((entry) => tx.store.delete([entry.conversationId, entry.requestId])));
  }
  await tx.done;
}

/** The manifests of a conversation, oldest to newest. */
export async function getContextManifests(conversationId: string): Promise<ContextManifest[]> {
  const db = await getPartitionDB();
  const entries = await db.getAllFromIndex('contextManifests', 'by-conversation', conversationId);
  return sortByCreatedAt(entries);
}

function sortByCreatedAt(entries: ContextManifest[]): ContextManifest[] {
  return [...entries].sort((a, b) => a.createdAt - b.createdAt);
}
