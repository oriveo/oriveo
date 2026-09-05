/**
 * Shell around the pure BYOK key validation engine in @oriveo/core/providers/key-validation, which
 * the web Next runtime and the desktop main process share and must not fork. This file injects the
 * web global fetch so routes and tests need no changes.
 */
import { probeProviderKey as coreProbeProviderKey } from "@oriveo/core/providers/key-validation";
import type { ProviderValidationContract } from "@oriveo/core/providers/key-validation";
import { getRuntimeConfig } from "../../../lib/core/metadata/metadata-client";

export {
  judge,
  buildProbeURL,
  buildAuthHeaders,
} from "@oriveo/core/providers/key-validation";
export type {
  ProviderValidationContract,
  InvalidKeySignal,
  ValidationResult,
} from "@oriveo/core/providers/key-validation";

/** Web adapter: probes go through the global fetch, proxied server-side in the Next runtime because of browser CORS. */
export function probeProviderKey(input: {
  baseURL: string;
  apiKey: string;
  validation: ProviderValidationContract | undefined;
  fetchImpl?: typeof fetch;
}): ReturnType<typeof coreProbeProviderKey> {
  const timeoutSecs = getRuntimeConfig()?.networkPolicy.keyValidationTimeoutSecs;
  const timeoutMs =
    typeof timeoutSecs === "number" && Number.isFinite(timeoutSecs) && timeoutSecs > 0
      ? timeoutSecs * 1000
      : undefined;
  // redirect:'manual': the SSRF guard only validates the initial URL, so following an upstream 302 into a private network or a metadata endpoint must be blocked.
  const safeFetch: typeof fetch = (url, init) => fetch(url, { ...init, redirect: "manual" });
  return coreProbeProviderKey({ ...input, fetchImpl: input.fetchImpl ?? safeFetch, timeoutMs });
}
