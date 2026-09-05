// Shared response helpers. The pure parts (SSE headers, citation normalization, latest user
// prompt) live in @oriveo/core; downloadImageAsDataURL stays here because it does fetch IO and
// applies the SSRF restrictions.
import { safeImageToDataURL } from "../image-fetch";

export {
  streamResponseHeaders,
  normalizeCitationURL,
  extractLatestUserPrompt,
} from "@oriveo/core/providers/request-builders/response-utils";

export async function downloadImageAsDataURL(url: string): Promise<string | null> {
  // Goes through safeImageToDataURL: https:// only, size <= 10MB, timeout <= 10s, to prevent SSRF
  return safeImageToDataURL(url);
}
