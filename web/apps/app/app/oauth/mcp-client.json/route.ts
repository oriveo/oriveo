import { mcpClientMetadataDocument } from "@oriveo/core/mcp/index";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * The CIMD client metadata document, generated from the origin the request arrived at: `client_id`
 * must equal the document URL character for character, and the same code is deployed under
 * different domains, so a static file with one domain baked in would be a document whose
 * `client_id` does not match on any other origin.
 *
 * The origin comes from `Host` and `X-Forwarded-Proto`: behind a reverse proxy the origin of
 * `request.url` is the internal `localhost:3001`. Only valid characters are accepted in the
 * hostname, because it is written into the JSON as is.
 */
const HOST_PATTERN = /^(?:[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?|\[[0-9a-f:.]{2,45}\])(?::\d{1,5})?$/i;

export function GET(request: Request): Response {
  const url = new URL(request.url);
  const host = (request.headers.get("host") ?? url.host).trim().toLowerCase();
  if (!HOST_PATTERN.test(host)) {
    return Response.json({ error: "Invalid Host header" }, { status: 400 });
  }
  const forwardedProto = request.headers.get("x-forwarded-proto")?.split(",")[0]?.trim().toLowerCase();
  const protocol = forwardedProto === "https" || forwardedProto === "http" ? forwardedProto : url.protocol.replace(":", "");
  return Response.json(mcpClientMetadataDocument(`${protocol}://${host}`), {
    headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
  });
}
