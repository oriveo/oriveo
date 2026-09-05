// Shell for the SiliconFlow Images adapter in @oriveo/core, injecting the web image downloader (safeImageToDataURL).
import { adaptSiliconFlowImagesResponse as coreAdapt } from "@oriveo/core/providers/response-adapters/siliconflow-images";
import { downloadImageAsDataURL } from "./utils";

export function adaptSiliconFlowImagesResponse(upstream: Response): Promise<Response> {
  return coreAdapt(upstream, downloadImageAsDataURL);
}
