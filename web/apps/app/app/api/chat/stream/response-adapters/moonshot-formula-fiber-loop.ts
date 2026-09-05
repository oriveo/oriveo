// Shell Formula/Fiber loop stays in core; Web only injects its guarded upstream transport.
import {
  adaptMoonshotFormulaFiberResponse as coreAdapt,
  prepareMoonshotFormulaRequest as corePrepare,
} from '@oriveo/core/providers/response-adapters/moonshot-formula-fiber-loop';
import type { ProviderRequest } from '../request-builders/types';
import { webUpstreamTransport } from '../request-builders/utils';

export function prepareMoonshotFormulaRequest(request: ProviderRequest, signal?: AbortSignal): Promise<ProviderRequest> {
  return corePrepare(request, webUpstreamTransport, signal);
}

export function adaptMoonshotFormulaFiberResponse(
  upstream: Response,
  request: ProviderRequest,
  signal?: AbortSignal,
): Promise<Response> {
  return coreAdapt(upstream, request, webUpstreamTransport, signal);
}
