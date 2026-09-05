// Thin shell: the moonshot built-in tool loop lives in @oriveo/core, and this injects the web
// upstream transport (the global fetch). There is no abort signal here, so the tool loop does not
// observe a client disconnect.
import { adaptMoonshotToolLoopResponse as coreAdapt } from "@oriveo/core/providers/response-adapters/moonshot-tool-loop";
import { webUpstreamTransport } from "../request-builders/utils";
import type { ProviderRequest } from "../request-builders/types";

export function adaptMoonshotToolLoopResponse(
  upstream: Response,
  req: ProviderRequest,
): Promise<Response> {
  return coreAdapt(upstream, req, webUpstreamTransport);
}
