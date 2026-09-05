import {
  clearUnsupportedParamLearning,
  type UnsupportedParamScope,
} from '@oriveo/core/providers/unsupported-param';

/**
 * Clears both renderer and Electron-main learning partitions for the same relay connection.
 *
 * The **full connection identity** has to cross the IPC boundary: the first four segments of the
 * cache key on the main side are the partition, connection and credential epoch. Sending only
 * providerKind, modelID and the fingerprint leaves the main process unable to locate any partition,
 * so clear silently becomes a no-op.
 * The granularity is per connection, covering every endpoint and revision variant of that
 * connection and model.
 */
export async function clearRuntimeUnsupportedParamLearning(
  scope: UnsupportedParamScope & {
    providerKind: 'relay';
    modelID: string;
    endpointFingerprint: string;
    partitionId: string;
    connectionInstanceId: string;
    connectionGeneration: string;
    credentialEpoch: string;
  },
): Promise<void> {
  try {
    await window.oriveo?.provider.clearUnsupportedParamLearning({
      providerKind: scope.providerKind,
      modelID: scope.modelID,
      endpointFingerprint: scope.endpointFingerprint,
      partitionId: scope.partitionId,
      connectionInstanceId: scope.connectionInstanceId,
      connectionGeneration: scope.connectionGeneration,
      credentialEpoch: scope.credentialEpoch,
    });
  } finally {
    clearUnsupportedParamLearning(scope);
  }
}
