export async function loadSyncCore(): Promise<typeof import('./sync-port')> {
  return import('./sync-port');
}
