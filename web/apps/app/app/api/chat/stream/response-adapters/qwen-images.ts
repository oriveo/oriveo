// Shell for the Qwen Images adapter in @oriveo/core: injects a downloader that keeps the
// safeFetchImage plus Buffer behaviour (DashScope URLs expire after 24h, so the image is
// downloaded immediately and converted to base64, falling back to the original url on failure).
import { adaptQwenImagesResponse as coreAdapt } from "@oriveo/core/providers/response-adapters/qwen-images";
import { safeFetchImage } from "../image-fetch";

async function qwenDownloadImage(url: string): Promise<string | null> {
  const fetched = await safeFetchImage(url);
  if (!fetched) return null;
  const base64 = Buffer.from(fetched.buffer).toString("base64");
  return `data:${fetched.contentType};base64,${base64}`;
}

export function adaptQwenImagesResponse(upstream: Response): Promise<Response> {
  return coreAdapt(upstream, qwenDownloadImage);
}
