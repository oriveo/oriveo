import { NextRequest } from "next/server";
import { isValidProviderKind, type ProviderKind } from "@oriveo/shared";
import { resolveProviderBaseURL } from "../../_shared/url-utils";
import { probeProviderKey, type ValidationResult } from "../../_shared/key-validation";
import { getRuntimeMetadata } from "../../chat/stream/runtime";
import { assertUrlNotSsrf, SsrfBlockedError } from "../../_shared/ssrf-guard";

export const runtime = "nodejs";

const JSON_HEADERS = {
  Accept: "application/json",
  "Content-Type": "application/json",
} as const;

interface ValidateResponse {
  result: ValidationResult;
  status?: number;
}

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
    // Official providers: probe through the Next runtime using the validation contract sent by the
    // backend, so the key never reaches the Go backend. The three-way result is valid / invalid /
    // unverified.
    if (providerKind !== "relay") {
      const metadata = await getRuntimeMetadata();
      const validation = metadata?.providers[providerKind]?.validation;
      const resolvedBaseURL = resolveProviderBaseURL(providerKind, baseURL);

      // SSRF guard: baseURL can come from the user, so block private, reserved and metadata addresses before probing.
      await assertUrlNotSsrf(resolvedBaseURL);

      const outcome = await probeProviderKey({
        baseURL: resolvedBaseURL,
        apiKey,
        validation,
      });

      const body: ValidateResponse = { result: outcome.result };
      if (typeof outcome.status === "number") body.status = outcome.status;
      return Response.json(body);
    }

    // Relay: a custom endpoint has no official metadata catalog, so keep the /models probe.
    const url = `${resolveProviderBaseURL(providerKind, baseURL)}/models`;
    // SSRF guard: a relay endpoint is entirely user supplied, so block private, reserved and metadata addresses before probing.
    await assertUrlNotSsrf(url);
    const headers: Record<string, string> = {
      ...JSON_HEADERS,
      Authorization: `Bearer ${apiKey}`,
    };

    // redirect:'manual': the SSRF guard only checks the initial URL, so never follow an upstream 302 into a private or metadata address.
    const res = await fetch(url, { headers, redirect: "manual" });

    if (!res.ok) {
      const body = await res.text().catch(() => "");
      return Response.json(
        { valid: false, error: body },
        { status: res.status },
      );
    }

    return Response.json({ valid: true });
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
