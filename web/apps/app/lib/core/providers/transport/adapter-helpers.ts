/**
 * Web adapter for the protocol core in @oriveo/core, which web and desktop import from the same
 * place. The core transport(fetch) and metadata come in through deps injection; here they are
 * window.fetch plus metadata-client's getProviderTransport/getWebSearchProfile, so web callers
 * keep their existing signatures.
 */
import {
  streamWithStrategy as coreStreamWithStrategy,
  type StreamWithStrategyParams,
} from '@oriveo/core/providers/transport/adapter-helpers';
import type { GetProviderTransportFn } from '@oriveo/core/providers/transport/endpoint-resolver';
import type { StreamHandle } from '@oriveo/core/providers/types';
import type { TransportPort } from '@oriveo/core';
import { getProviderTransport, getWebSearchProfile } from '../../metadata/metadata-client';

export type { StreamWithStrategyParams };

const webTransport: TransportPort = {
  fetch: (url, init) =>
    fetch(url, {
      method: init.method,
      headers: init.headers,
      body: init.body,
      signal: init.signal,
    }),
};

const getMeta: GetProviderTransportFn = (providerKind) =>
  getProviderTransport(providerKind) ?? undefined;

export function streamWithStrategy(params: StreamWithStrategyParams): StreamHandle {
  return coreStreamWithStrategy(params, {
    transport: webTransport,
    getProviderTransport: getMeta,
    getWebSearchProfile,
  });
}
