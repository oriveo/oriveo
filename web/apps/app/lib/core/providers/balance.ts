/**
 * ProviderBalance -- one abstraction for balance queries.
 *
 * Only four providers support balance queries: OpenRouter / SiliconFlow / DeepSeek / Moonshot.
 * Other BYOK providers and Relay do not render a balance card at all, so an empty card never
 * looks like something went wrong.
 */

import type { ProviderKind } from '@oriveo/shared';

export type BalanceCurrency = 'USD' | 'CNY';

export interface ProviderBalance {
  currency: BalanceCurrency;
  /** Total balance, meaning everything usable right now. */
  total: number;
  /** Granted credit or vouchers (SiliconFlow balance / DeepSeek granted / Moonshot voucher). OpenRouter has no such concept -> undefined */
  granted?: number;
  /** Topped-up or cash balance. Moonshot cash_balance can go negative, meaning the account is in arrears, and the UI has to warn. */
  topUp?: number;
  /** Cumulative spend (OpenRouter only, from `total_usage`); undefined for the others. */
  totalUsage?: number;
  fetchedAt: Date;
}

/** Balance amount format shared by the provider list and detail pages: two decimals, upstream currency preserved. */
export function formatProviderBalanceAmount(
  balance: Pick<ProviderBalance, 'currency' | 'total'>,
  locale: string,
): string {
  const symbol = balance.currency === 'CNY' ? '¥' : '$';
  const sign = balance.total < 0 ? '-' : '';
  const amount = new Intl.NumberFormat(locale, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
    useGrouping: true,
  }).format(Math.abs(balance.total));
  return `${symbol}${sign}${amount}`;
}

/**
 * Allowlist of provider kinds that can report a balance.
 * The UI calls `BALANCE_CAPABLE_KINDS.includes(provider.kind)` to decide whether to render the
 * balance card.
 */
export const BALANCE_CAPABLE_KINDS = [
  'openRouter',
  'siliconFlow',
  'deepseek',
  'moonshot',
] as const satisfies readonly ProviderKind[];

export type BalanceCapableKind = (typeof BALANCE_CAPABLE_KINDS)[number];

export function isBalanceCapable(kind: ProviderKind | string): kind is BalanceCapableKind {
  return (BALANCE_CAPABLE_KINDS as readonly string[]).includes(kind);
}

/**
 * OpenRouter `/credits` answers 401 for some key types (documented as requiring a management
 * key). The UI uses this marker to hide the balance card silently, since it is not a user error.
 */
export class BalanceUnsupportedError extends Error {
  constructor(message = 'Balance API not available for this key') {
    super(message);
    this.name = 'BalanceUnsupportedError';
  }
}

/** The provider key was rejected (401/403) -- the UI should report an invalid key and prompt the user to check it. */
export class BalanceUnauthorizedError extends Error {
  constructor(message = 'API key is invalid or has been revoked') {
    super(message);
    this.name = 'BalanceUnauthorizedError';
  }
}

/** Network-layer failure (timeout, connection failure, 5xx) -- the UI should offer a retry. */
export class BalanceNetworkError extends Error {
  constructor(message = 'Failed to fetch balance, please retry') {
    super(message);
    this.name = 'BalanceNetworkError';
  }
}

/** Shared signature for every BalanceQueryable adapter. */
export type FetchBalanceFn = (apiKey: string, baseURL?: string) => Promise<ProviderBalance>;

/**
 * Extracts the origin (`https://host[:port]`) from the configured baseURL, dropping any path.
 * Balance endpoint paths are fixed per provider and differ from the chat endpoints, so building
 * them on the origin avoids duplicates such as `/v1/v1/user/balance` (a chat baseURL usually
 * already ends in `/v1`, while the DeepSeek balance endpoint sits at the root).
 *
 * It also tolerates a path prefix in a self-hosted reverse proxy (`https://my-proxy/openai`), in
 * which case the balance request will most likely 404 and the caller degrades silently instead
 * of raising KeyInvalid.
 */
function originOf(baseURL: string | undefined, fallbackOrigin: string): string {
  const raw = baseURL?.trim();
  try {
    if (raw && raw.length > 0) {
      // Matches the chat path behavior: when a bare host is entered (`api.moonshot.cn/v1`, no
      // scheme) the chat path adds the scheme and reaches the right regional endpoint. Here
      // `new URL(raw)` would throw Invalid URL, fall through to the global host fallback, and a
      // CN key would be rejected there with a 401 that the UI reports as "API Key invalid".
      // Adding https:// before parsing keeps chat and balance on the same host.
      const normalized = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
      const u = new URL(normalized);
      return `${u.protocol}//${u.host}`;
    }
  } catch {
    // fall through
  }
  return fallbackOrigin;
}

function toFiniteNumber(value: unknown, fallback = 0): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = Number.parseFloat(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

async function readJson(res: Response): Promise<unknown> {
  try {
    return await res.json();
  } catch {
    throw new BalanceNetworkError('Invalid balance response');
  }
}

function mapStatusToError(status: number, body?: string): Error {
  if (status === 401 || status === 403) {
    return new BalanceUnauthorizedError(body || 'Unauthorized');
  }
  return new BalanceNetworkError(`HTTP ${status}${body ? `: ${body}` : ''}`);
}

/* ── OpenRouter ──────────────────────────────────────────────────────── */

const OPENROUTER_DEFAULT_ORIGIN = 'https://openrouter.ai';

export async function fetchOpenRouterBalance(
  apiKey: string,
  baseURL?: string,
): Promise<ProviderBalance> {
  const origin = originOf(baseURL, OPENROUTER_DEFAULT_ORIGIN);
  let res: Response;
  try {
    res = await fetch(`${origin}/api/v1/credits`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
  } catch (err) {
    throw new BalanceNetworkError(err instanceof Error ? err.message : 'Network error');
  }
  if (res.status === 401) {
    // Documented as requiring a management key; a plain Bearer key sees an occasional 401 -- the UI hides the card silently.
    throw new BalanceUnsupportedError();
  }
  if (!res.ok) {
    throw mapStatusToError(res.status, await res.text().catch(() => ''));
  }
  const body = (await readJson(res)) as { data?: { total_credits?: unknown; total_usage?: unknown } };
  const totalCredits = toFiniteNumber(body.data?.total_credits);
  const totalUsage = toFiniteNumber(body.data?.total_usage);
  // OpenRouter has no notion of granted credit: total_credits is the cumulative top-up (topUp)
  // and total_usage the cumulative spend (totalUsage). Both are needed for the UI to show spend.
  return {
    currency: 'USD',
    total: totalCredits - totalUsage,
    topUp: totalCredits,
    totalUsage,
    fetchedAt: new Date(),
  };
}

/* ── SiliconFlow ─────────────────────────────────────────────────────── */

const SILICONFLOW_DEFAULT_ORIGIN = 'https://api.siliconflow.cn';

export async function fetchSiliconFlowBalance(
  apiKey: string,
  baseURL?: string,
): Promise<ProviderBalance> {
  const origin = originOf(baseURL, SILICONFLOW_DEFAULT_ORIGIN);
  let res: Response;
  try {
    res = await fetch(`${origin}/v1/user/info`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
  } catch (err) {
    throw new BalanceNetworkError(err instanceof Error ? err.message : 'Network error');
  }
  if (!res.ok) {
    throw mapStatusToError(res.status, await res.text().catch(() => ''));
  }
  const body = (await readJson(res)) as {
    data?: { balance?: unknown; chargeBalance?: unknown; totalBalance?: unknown };
  };
  const total = toFiniteNumber(body.data?.totalBalance);
  const granted = toFiniteNumber(body.data?.balance);
  const topUp = toFiniteNumber(body.data?.chargeBalance);
  return {
    currency: new URL(origin).hostname.toLowerCase().endsWith('siliconflow.com') ? 'USD' : 'CNY',
    total,
    granted,
    topUp,
    fetchedAt: new Date(),
  };
}

/* ── DeepSeek ────────────────────────────────────────────────────────── */

const DEEPSEEK_DEFAULT_ORIGIN = 'https://api.deepseek.com';

export async function fetchDeepSeekBalance(
  apiKey: string,
  baseURL?: string,
): Promise<ProviderBalance> {
  // Chat goes to `${origin}/v1/chat/completions`, but the balance sits at the root,
  // `${origin}/user/balance`. Do not build it from baseURL as `${base}/user/balance`: that
  // becomes `/v1/user/balance` and 404s.
  const origin = originOf(baseURL, DEEPSEEK_DEFAULT_ORIGIN);
  let res: Response;
  try {
    res = await fetch(`${origin}/user/balance`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
  } catch (err) {
    throw new BalanceNetworkError(err instanceof Error ? err.message : 'Network error');
  }
  if (!res.ok) {
    throw mapStatusToError(res.status, await res.text().catch(() => ''));
  }
  const body = (await readJson(res)) as {
    balance_infos?: Array<{
      currency?: string;
      total_balance?: unknown;
      granted_balance?: unknown;
      topped_up_balance?: unknown;
    }>;
  };
  const infos = Array.isArray(body.balance_infos) ? body.balance_infos : [];
  // Prefer USD, otherwise take the first entry.
  const info = infos.find((b) => b.currency === 'USD') ?? infos[0];
  if (!info) {
    throw new BalanceNetworkError('balance_infos missing');
  }
  const currency: BalanceCurrency = info.currency === 'CNY' ? 'CNY' : 'USD';
  return {
    currency,
    total: toFiniteNumber(info.total_balance),
    granted: toFiniteNumber(info.granted_balance),
    topUp: toFiniteNumber(info.topped_up_balance),
    fetchedAt: new Date(),
  };
}

/* ── Moonshot ────────────────────────────────────────────────────────── */

const MOONSHOT_DEFAULT_ORIGIN = 'https://api.moonshot.ai';

/**
 * Currency by host: `api.moonshot.cn` (China) -> CNY; `api.moonshot.ai` (international) and any
 * custom host -> USD. Both Moonshot hosts share the path (`/v1/users/me/balance`) and the
 * response fields; only the currency differs.
 */
function moonshotCurrencyFor(origin: string): BalanceCurrency {
  try {
    const host = new URL(origin).hostname.toLowerCase();
    return host.endsWith('moonshot.cn') ? 'CNY' : 'USD';
  } catch {
    return 'USD';
  }
}

export async function fetchMoonshotBalance(
  apiKey: string,
  baseURL?: string,
): Promise<ProviderBalance> {
  const origin = originOf(baseURL, MOONSHOT_DEFAULT_ORIGIN);
  let res: Response;
  try {
    res = await fetch(`${origin}/v1/users/me/balance`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
  } catch (err) {
    throw new BalanceNetworkError(err instanceof Error ? err.message : 'Network error');
  }
  if (!res.ok) {
    throw mapStatusToError(res.status, await res.text().catch(() => ''));
  }
  const body = (await readJson(res)) as {
    data?: { available_balance?: unknown; voucher_balance?: unknown; cash_balance?: unknown };
  };
  return {
    currency: moonshotCurrencyFor(origin),
    total: toFiniteNumber(body.data?.available_balance),
    granted: toFiniteNumber(body.data?.voucher_balance),
    // cash_balance can go negative (arrears); the UI warns on topUp < 0.
    topUp: toFiniteNumber(body.data?.cash_balance),
    fetchedAt: new Date(),
  };
}

/* ── Registry ────────────────────────────────────────────────────────── */

const FETCHERS: Record<BalanceCapableKind, FetchBalanceFn> = {
  openRouter: fetchOpenRouterBalance,
  siliconFlow: fetchSiliconFlowBalance,
  deepseek: fetchDeepSeekBalance,
  moonshot: fetchMoonshotBalance,
};

/**
 * Dispatches by providerKind to the matching fetcher; an unsupported kind throws.
 * Callers should guard with {@link isBalanceCapable} first.
 */
export async function fetchProviderBalance(
  kind: ProviderKind | string,
  apiKey: string,
  baseURL?: string,
): Promise<ProviderBalance> {
  if (!isBalanceCapable(kind)) {
    throw new BalanceUnsupportedError(`Balance not supported for ${kind}`);
  }
  return FETCHERS[kind](apiKey, baseURL);
}

/* ── 5 minute cache ──────────────────────────────────────────────────────── */

const CACHE_TTL_MS = 5 * 60 * 1000;
interface BalanceCacheEntry {
  apiKey: string;
  baseURL: string;
  balance: ProviderBalance;
}
const cache = new Map<string, BalanceCacheEntry>();

/**
 * Balance query with a 5 minute cache.
 * `bypassCache=true` forces a refresh, as when the user presses the refresh button.
 */
export async function getProviderBalanceCached(
  providerId: string,
  kind: ProviderKind | string,
  apiKey: string,
  baseURL: string | undefined,
  bypassCache = false,
): Promise<ProviderBalance> {
  const normalizedKey = apiKey.trim();
  const normalizedBaseURL = baseURL?.trim() ?? '';
  if (!bypassCache) {
    const cached = cache.get(providerId);
    if (
      cached
      && cached.apiKey === normalizedKey
      && cached.baseURL === normalizedBaseURL
      && Date.now() - cached.balance.fetchedAt.getTime() < CACHE_TTL_MS
    ) {
      return cached.balance;
    }
  }
  const fresh = await fetchProviderBalance(
    kind,
    normalizedKey,
    normalizedBaseURL || undefined,
  );
  cache.set(providerId, {
    apiKey: normalizedKey,
    baseURL: normalizedBaseURL,
    balance: fresh,
  });
  return fresh;
}

/** Test only: clears the cache. */
export function __resetBalanceCacheForTest(): void {
  cache.clear();
}
