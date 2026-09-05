/**
 * The protocol logic lives in @oriveo/core so web and desktop import the same implementation.
 * The core version takes its metadata lookup by injection; this is the web adapter, injecting
 * getModelTransport from metadata-client while keeping the web call signature and behavior unchanged.
 */
import { resolveModelTransport as coreResolveModelTransport } from '@oriveo/core/providers/transport/model-transport-resolver';
import type { ProviderKind } from '@oriveo/shared';
import { getModelTransport } from '../../metadata/metadata-client';

export function resolveModelTransport(
  providerKind: ProviderKind | string,
  modelID: string,
): string {
  return coreResolveModelTransport(providerKind, modelID, getModelTransport);
}
