/**
 * Shell around buildProviderRequest, which lives in @oriveo/core. It pre-binds the web
 * getRuntimeMetadata, including its TTL cache, so route.ts keeps calling
 * `buildProviderRequest(params)` with an unchanged signature.
 */
import { buildProviderRequest as coreBuildProviderRequest } from "@oriveo/core/providers/request-builders/dispatch";
import type { MetadataBaseURLRejectionReporter } from "@oriveo/core/providers/transport/endpoint-resolver";
import type { ProviderRequest, RequestParams } from "@oriveo/core/providers/request-builders/types";
import { trackEvent } from "../../../../../lib/core/telemetry";
import { getRuntimeMetadata } from "../runtime";

const reportRejectedMetadataBaseURL: MetadataBaseURLRejectionReporter = (event) => {
  trackEvent("metadata_base_url_rejected", {
    provider_kind: event.providerKind,
    base_url: event.baseUrl,
    reason: event.reason,
  });
};

export function buildProviderRequest(params: RequestParams): Promise<ProviderRequest> {
  return coreBuildProviderRequest(params, getRuntimeMetadata, reportRejectedMetadataBaseURL);
}
