import { NextRequest } from "next/server";
import { isValidProviderKind, type ProviderKind } from "@oriveo/shared";
import { resolveProviderBaseURL } from "../../_shared/url-utils";
import { getRuntimeMetadata } from "../../chat/stream/runtime";
import { assertUrlNotSsrf, SsrfBlockedError } from "../../_shared/ssrf-guard";

export const runtime = "nodejs";

const JSON_HEADERS = {
  Accept: "application/json",
  "Content-Type": "application/json",
} as const;

export async function POST(request: NextRequest) {
  let parsed: {
    providerKind: ProviderKind;
    apiKey: string;
    baseURL?: string;
  };
  try {
    parsed = await request.json();
  } catch {
    return Response.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  const { providerKind, apiKey, baseURL } = parsed;

  if (!apiKey || !providerKind) {
    return Response.json({ error: "Missing required fields" }, { status: 400 });
  }

  if (!isValidProviderKind(providerKind)) {
    return Response.json(
      { error: `Unknown provider: ${providerKind}` },
      { status: 400 },
    );
  }

  try {
    // Official providers: no upstream key ping, since the model catalog comes only from the metadata.
    if (providerKind !== "relay") {
      const metadata = await getRuntimeMetadata();
      const provider = metadata?.providers[providerKind];
      return Response.json({
        data: provider ? Object.keys(provider.models).sort().map((id) => ({ id })) : [],
      });
    }

    // Relay: a custom endpoint has no official metadata catalog, so the /models probe is kept.
    const url = `${resolveProviderBaseURL(providerKind, baseURL)}/models`;
    // SSRF guard: a relay endpoint is entirely user-supplied, so private, reserved and metadata addresses are blocked before probing.
    await assertUrlNotSsrf(url);
    const headers: Record<string, string> = {
      ...JSON_HEADERS,
      Authorization: `Bearer ${apiKey}`,
    };

    // redirect:'manual' because the SSRF guard only checks the initial URL; following an upstream 302 into a private or metadata address must not be allowed.
    const res = await fetch(url, { headers, redirect: "manual" });

    if (!res.ok) {
      const body = await res.text().catch(() => "");
      return Response.json({ error: body }, { status: res.status });
    }

    const data = await res.json();
    return Response.json(data);
  } catch (error) {
    if (error instanceof SsrfBlockedError) {
      return Response.json({ error: error.message }, { status: 403 });
    }
    if (
      error instanceof Error &&
      error.message.includes("Base URL is required")
    ) {
      return Response.json({ error: error.message }, { status: 400 });
    }
    return Response.json({ error: "Network error" }, { status: 502 });
  }
}
