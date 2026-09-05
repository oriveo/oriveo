/**
 * BYOK API key validation engine. Pure core with no global `fetch` dependency: the caller injects
 * `fetchImpl` (the global fetch on the web runtime, undici plus SSRF guards on the desktop main
 * process), and every client implements the same decision logic.
 *
 * - The backend ships one contract per provider under `/api/metadata.providers[*].validation`
 *   (probe / probePath / authMode / headerProfile / invalidKeySignals).
 * - Browsers cannot call upstreams directly because of CORS, so validation runs server-side in the
 *   Next runtime; the desktop runs it in the main process. Either way the key stays local.
 * - The probe hits a model-independent endpoint (GET /models, or GET /key for OpenRouter) and
 *   decides on HTTP status plus body text only. Vendor-specific error codes are never parsed:
 *   MiniMax returns contradictory 1004/2049 codes while its HTTP 401 is stable.
 * - Innocent until proven guilty: 2xx -> valid; a matched invalidKeySignal -> invalid; anything
 *   else (404 / 429 / 5xx / timeout / network error / no match) -> unverified. A working key must
 *   never be rejected.
 */

/** Validation contract, shipped by the backend so it can be adjusted without a release. */
export interface ProviderValidationContract {
  /** `list_models` (GET /models) or `key_info` (OpenRouter's GET /key). */
  probe?: string;
  /** Probe path, relative to the resolved baseURL (for example `/models` or `/key`). */
  probePath?: string;
  /** Auth mode: `bearer` / `x_api_key` / `query_key`. */
  authMode?: "bearer" | "x_api_key" | "query_key";
  /** Header profile: `none` / `anthropic_v2023_06_01` / `openrouter`. */
  headerProfile?: "none" | "anthropic_v2023_06_01" | "openrouter";
  /** Signals that prove a key is invalid; matching any one of them yields invalid. */
  invalidKeySignals?: InvalidKeySignal[];
}

export interface InvalidKeySignal {
  status?: number;
  /** AND semantics: every string must appear in the response body (case-sensitive literal substring). */
  bodyIncludes?: string[];
}

/** Three-state validation result. */
export type ValidationResult = "valid" | "invalid" | "unverified";

/** Fallback when the contract is missing: list_models + bearer + a 401 signal, the most common shape. */
const DEFAULT_PROBE_PATH = "/models";
const DEFAULT_AUTH_MODE: NonNullable<ProviderValidationContract["authMode"]> = "bearer";
const DEFAULT_SIGNALS: InvalidKeySignal[] = [{ status: 401 }];

/** Probe timeout in milliseconds. A timeout is unverified, never invalid. */
const TIMEOUT_MS = 18_000;

const USER_AGENT = "Oriveo (Web)";

/**
 * Decide on a single probe response. Pure function, touches no network.
 *
 * - HTTP 2xx -> valid
 * - Any matched `invalidKeySignals` entry (status equal, and every bodyIncludes string present in
 *   the body; an empty or missing bodyIncludes matches on status alone) -> invalid
 * - Everything else (404 / 429 / 5xx / no match) -> unverified
 *
 * bodyIncludes uses AND semantics and matches case-sensitive literal substrings.
 */
export function judge(
  statusCode: number,
  body: string,
  signals: InvalidKeySignal[],
): ValidationResult {
  if (statusCode >= 200 && statusCode < 300) {
    return "valid";
  }

  for (const signal of signals) {
    if (signal.status !== statusCode) continue;
    const needles = signal.bodyIncludes ?? [];
    // AND semantics: an empty bodyIncludes decides on status alone, otherwise every needle must hit.
    if (needles.every((needle) => body.includes(needle))) {
      return "invalid";
    }
  }

  return "unverified";
}

interface ProbeOutcome {
  result: ValidationResult;
  /** HTTP status of the response; undefined on timeout or network error. */
  status?: number;
}

/**
 * Probe one official provider's credential against its contract.
 *
 * Appends `probePath`, sends a GET, builds the auth headers from authMode/headerProfile and then
 * applies the decision above. The caller resolves baseURL (region already applied). `apiKey` is
 * used locally only and is never forwarded to the backend.
 */
export async function probeProviderKey(input: {
  baseURL: string;
  apiKey: string;
  validation: ProviderValidationContract | undefined;
  /** Injected upstream transport; core never reaches for a global fetch. */
  fetchImpl: typeof fetch;
  timeoutMs?: number;
}): Promise<ProbeOutcome> {
  const fetchImpl = input.fetchImpl;
  const probePath = sanitizePath(input.validation?.probePath) ?? DEFAULT_PROBE_PATH;
  const authMode = input.validation?.authMode ?? DEFAULT_AUTH_MODE;
  const headerProfile = input.validation?.headerProfile ?? "none";
  const signals = input.validation?.invalidKeySignals?.length
    ? input.validation.invalidKeySignals
    : DEFAULT_SIGNALS;

  const url = buildProbeURL(input.baseURL, probePath, authMode, input.apiKey);
  const headers = buildAuthHeaders(authMode, headerProfile, input.apiKey);
  const timeoutMs =
    typeof input.timeoutMs === "number" && Number.isFinite(input.timeoutMs) && input.timeoutMs > 0
      ? input.timeoutMs
      : TIMEOUT_MS;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, {
      method: "GET",
      headers,
      signal: controller.signal,
    });
    const body = await res.text().catch(() => "");
    return { result: judge(res.status, body, signals), status: res.status };
  } catch {
    // Timeout, network error, DNS failure or an unreachable region -> unverified.
    return { result: "unverified" };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Build the probe URL. `query_key` (Gemini) appends the key to the query string.
 *
 * Version-prefix dedupe: the anthropic and gemini base URLs already carry a version segment
 * (`/v1`, `/v1beta`) because chat needs `base + /messages`, while the contract's probePath carries
 * one too (`/v1/models`, `/v1beta/models`). Naive concatenation yields `.../v1/v1/models`, a 404
 * that is forever unverified. The overlapping prefix is stripped before joining. The chat path
 * does not go through here and is unaffected.
 */
export function buildProbeURL(
  baseURL: string,
  probePath: string,
  authMode: NonNullable<ProviderValidationContract["authMode"]>,
  apiKey: string,
): string {
  const normalizedBase = baseURL.replace(/\/+$/, "");
  const normalizedPath = probePath.startsWith("/") ? probePath : `/${probePath}`;
  const effectivePath = dedupeVersionPrefix(normalizedBase, normalizedPath);
  const joined = `${normalizedBase}${effectivePath}`;
  if (authMode !== "query_key") return joined;

  const url = new URL(joined);
  url.searchParams.append("key", apiKey);
  return url.toString();
}

/**
 * Strip the version prefix that probePath shares with the base pathname.
 *
 * basePath is the pathname of normalizedBase after the host (`https://api.anthropic.com/v1` ->
 * `/v1`; a bare host -> ``). When basePath is non-empty and probePath equals it or starts with
 * `basePath + "/"`, that prefix is removed so the version is not written twice. Otherwise the path
 * is returned unchanged.
 */
function dedupeVersionPrefix(normalizedBase: string, normalizedPath: string): string {
  let basePath: string;
  try {
    basePath = new URL(normalizedBase).pathname.replace(/\/+$/, "");
  } catch {
    // base is not a valid URL, which should not happen since the caller resolved it -> leave as is.
    return normalizedPath;
  }

  if (!basePath) return normalizedPath;

  if (normalizedPath === basePath) return "";
  if (normalizedPath.startsWith(`${basePath}/`)) {
    return normalizedPath.slice(basePath.length);
  }
  return normalizedPath;
}

/**
 * Build the auth headers from authMode + headerProfile, matching what each adapter sends, so a key
 * that works for chat is validated through the same headers.
 */
export function buildAuthHeaders(
  authMode: NonNullable<ProviderValidationContract["authMode"]>,
  headerProfile: NonNullable<ProviderValidationContract["headerProfile"]>,
  apiKey: string,
): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: "application/json",
    "User-Agent": USER_AGENT,
  };

  switch (authMode) {
    case "bearer":
      headers.Authorization = `Bearer ${apiKey}`;
      break;
    case "x_api_key":
      headers["x-api-key"] = apiKey;
      break;
    case "query_key":
      // The key already rides on the URL query (see buildProbeURL), so no auth header is added.
      break;
  }

  switch (headerProfile) {
    case "none":
      break;
    case "anthropic_v2023_06_01":
      headers["anthropic-version"] = "2023-06-01";
      break;
    case "openrouter":
      headers["HTTP-Referer"] = "http://localhost:3000";
      headers["X-Title"] = "Oriveo";
      break;
  }

  return headers;
}

function sanitizePath(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : undefined;
}

/**
 * API key character-set validation (printable ASCII).
 *
 * Browser fetch() validates synchronously that header values fall inside ISO-8859-1 (Latin-1), and
 * any codepoint above 0xFF makes it throw "String contains non ISO-8859-1 code point". Provider
 * keys are printable ASCII, so a paste that picked up a full-width space, a zero-width space or a
 * control character should raise a localized error before fetch is called instead of surfacing
 * that low-level throw.
 *
 * It lives in core rather than in the app so that relay form validation
 * (`relay-form-validation.ts`) and every key input share one rule; otherwise the same key could be
 * judged differently on two paths.
 */
const PRINTABLE_ASCII_MIN = 0x20; // space
const PRINTABLE_ASCII_MAX = 0x7e; // tilde

export function isPrintableAsciiKey(value: string): boolean {
  if (value.length === 0) return false;
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    if (code < PRINTABLE_ASCII_MIN || code > PRINTABLE_ASCII_MAX) {
      return false;
    }
  }
  return true;
}
