/**
 * Web adapter over the endpoint resolver in @oriveo/core, which the web and desktop clients share.
 * The core version takes its metadata lookup by injection; here it is wired to
 * getProviderTransport from metadata-client, keeping the web call signature and the three-level
 * resolution behavior unchanged.
 */
import {
  applyEndpointPlaceholders,
  resolveBaseURL as coreResolveBaseURL,
  resolveEndpoint as coreResolveEndpoint,
  resolveEndpointPath as coreResolveEndpointPath,
  type GetProviderTransportFn,
  type MetadataBaseURLRejectionReporter,
} from '@oriveo/core/providers/transport/endpoint-resolver';
import type { ProviderTransportDefinition } from '@oriveo/core/metadata/types';
import type { Provider, ProviderKind } from '@oriveo/shared';
import { getProviderTransport } from '../../metadata/metadata-client';
import { trackEvent } from '../../telemetry';
import type { EndpointKind } from './transport-kind';

export { applyEndpointPlaceholders };

const getMeta: GetProviderTransportFn = (providerKind) =>
  getProviderTransport(providerKind) ?? undefined;

const reportRejectedMetadataBaseURL: MetadataBaseURLRejectionReporter = (event) => {
  trackEvent('metadata_base_url_rejected', {
    provider_kind: event.providerKind,
    base_url: event.baseUrl,
    reason: event.reason,
  });
};

export function resolveEndpoint(
  provider: Provider | null | undefined,
  providerKind: ProviderKind | string,
  kind: EndpointKind,
  options?:
    | { metadataOverride?: ProviderTransportDefinition | null; modelID?: string }
    | ProviderTransportDefinition
    | null,
): string {
  return coreResolveEndpoint(
    provider,
    providerKind,
    kind,
    options,
    getMeta,
    reportRejectedMetadataBaseURL,
  );
}

export function resolveBaseURL(
  provider: Provider | null | undefined,
  providerKind: ProviderKind | string,
  metadataOverride?: ProviderTransportDefinition | null,
): string {
  return coreResolveBaseURL(
    provider,
    providerKind,
    metadataOverride,
    getMeta,
    reportRejectedMetadataBaseURL,
  );
}

export function resolveEndpointPath(
  providerKind: ProviderKind | string,
  kind: EndpointKind,
  metadataOverride?: ProviderTransportDefinition | null,
): string | undefined {
  return coreResolveEndpointPath(providerKind, kind, metadataOverride, getMeta);
}
