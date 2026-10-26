/**
 * Price v2 (pricingV2) decoding and local cost estimation.
 *
 * - `decodePricingV2`: allowlist-decodes the server `pricingV2`; a bad shape returns undefined (only this key is dropped).
 * - `estimatePricingV2`: a pure function that resolves the unit price by base -> length tier -> cache fallback -> time window, five buckets x unit price / 1e6.
 *   Three states: estimated / unavailable (price unknown is shown, never treated as 0) / not_applicable (not per_token, takes the legacy path).
 */

export type PricingV2Weekday =
  | 'monday'
  | 'tuesday'
  | 'wednesday'
  | 'thursday'
  | 'friday'
  | 'saturday'
  | 'sunday';

export interface PricingV2ContextTier {
  aboveInputTokens: number;
  semantics: 'whole_request' | 'incremental';
  inputPerMToken?: number;
  outputPerMToken?: number;
  cacheReadPerMToken?: number;
  cacheWritePerMToken?: number;
}

export interface PricingV2TimeWindow {
  timezone: string;
  days?: PricingV2Weekday[];
  start: string;
  end: string;
  inputPerMToken?: number;
  outputPerMToken?: number;
  cacheReadPerMToken?: number;
  multiplier?: number;
  holidayCalendar?: string;
}

export interface PricingV2 {
  currencyCode?: string;
  unit: string;
  base?: {
    inputPerMToken?: number | null;
    outputPerMToken?: number | null;
  };
  cache?: {
    readPerMToken?: number;
    writes?: Array<{ ttl: '5m' | '1h'; perMToken: number }>;
  };
  contextTiers?: PricingV2ContextTier[];
  timeWindows?: PricingV2TimeWindow[];
  regionSurcharges?: Array<{ regionScope: string; multiplier: number }>;
  perUnit?: number;
}

/** Five-bucket usage (token counts); the four input buckets do not overlap. */
export interface PricingV2Usage {
  uncachedInputTokens: number;
  cacheReadTokens: number;
  cacheWrite5mTokens: number;
  cacheWrite1hTokens: number;
  outputTokens: number;
}

export type PricingV2Estimate =
  | { status: 'estimated'; amount: number; currencyCode?: string }
  | { status: 'unavailable' }
  | { status: 'not_applicable' };

// -- Decoding --

const WEEKDAYS: readonly PricingV2Weekday[] = [
  'sunday',
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
];
const START_PATTERN = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
const END_PATTERN = /^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$/;

class PricingV2ShapeError extends Error {}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function fail(): never {
  throw new PricingV2ShapeError();
}

/** Matches schema `additionalProperties: false`: a key outside the allowlist means a bad shape. */
function onlyKeys(record: Record<string, unknown>, keys: readonly string[]): void {
  for (const key of Object.keys(record)) {
    if (!keys.includes(key)) fail();
  }
}

/** An optional finite number; present but not finite means a bad shape. */
function optionalNumber(value: unknown): number | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== 'number' || !Number.isFinite(value)) fail();
  return value;
}

function optionalString(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== 'string') fail();
  return value;
}

function optionalArray(value: unknown): unknown[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) fail();
  return value;
}

function assign<T extends object, K extends keyof T>(target: T, key: K, value: T[K] | undefined): void {
  if (value !== undefined) target[key] = value;
}

function decodeBase(raw: unknown): PricingV2['base'] {
  if (raw === undefined) return undefined;
  if (!isRecord(raw)) fail();
  onlyKeys(raw, ['inputPerMToken', 'outputPerMToken']);
  const out: NonNullable<PricingV2['base']> = {};
  for (const key of ['inputPerMToken', 'outputPerMToken'] as const) {
    const value = raw[key];
    if (value === null) out[key] = null;
    else assign(out, key, optionalNumber(value));
  }
  return out;
}

function decodeCache(raw: unknown): PricingV2['cache'] {
  if (raw === undefined) return undefined;
  if (!isRecord(raw)) fail();
  onlyKeys(raw, ['readPerMToken', 'writes']);
  const out: NonNullable<PricingV2['cache']> = {};
  assign(out, 'readPerMToken', optionalNumber(raw.readPerMToken));
  const writes = optionalArray(raw.writes);
  if (writes) {
    out.writes = writes.map((item) => {
      if (!isRecord(item)) fail();
      onlyKeys(item, ['ttl', 'perMToken']);
      if (item.ttl !== '5m' && item.ttl !== '1h') fail();
      const perMToken = optionalNumber(item.perMToken);
      if (perMToken === undefined) fail();
      return { ttl: item.ttl, perMToken };
    });
  }
  return out;
}

function decodeTier(raw: unknown): PricingV2ContextTier {
  if (!isRecord(raw)) fail();
  onlyKeys(raw, ['aboveInputTokens', 'semantics', 'inputPerMToken', 'outputPerMToken', 'cacheReadPerMToken', 'cacheWritePerMToken']);
  const above = raw.aboveInputTokens;
  if (typeof above !== 'number' || !Number.isSafeInteger(above) || above < 0) fail();
  if (raw.semantics !== 'whole_request' && raw.semantics !== 'incremental') fail();
  const tier: PricingV2ContextTier = { aboveInputTokens: above, semantics: raw.semantics };
  assign(tier, 'inputPerMToken', optionalNumber(raw.inputPerMToken));
  assign(tier, 'outputPerMToken', optionalNumber(raw.outputPerMToken));
  assign(tier, 'cacheReadPerMToken', optionalNumber(raw.cacheReadPerMToken));
  assign(tier, 'cacheWritePerMToken', optionalNumber(raw.cacheWritePerMToken));
  return tier;
}

function decodeWindow(raw: unknown): PricingV2TimeWindow {
  if (!isRecord(raw)) fail();
  onlyKeys(raw, [
    'timezone', 'days', 'start', 'end', 'inputPerMToken', 'outputPerMToken', 'cacheReadPerMToken', 'multiplier',
    'holidayCalendar',
  ]);
  const { timezone, start, end } = raw;
  if (typeof timezone !== 'string' || timezone.length === 0) fail();
  if (typeof start !== 'string' || !START_PATTERN.test(start)) fail();
  if (typeof end !== 'string' || !END_PATTERN.test(end)) fail();
  const window: PricingV2TimeWindow = { timezone, start, end };
  const days = optionalArray(raw.days);
  if (days) {
    window.days = days.map((day) => {
      if (typeof day !== 'string' || !WEEKDAYS.includes(day as PricingV2Weekday)) fail();
      return day as PricingV2Weekday;
    });
  }
  assign(window, 'inputPerMToken', optionalNumber(raw.inputPerMToken));
  assign(window, 'outputPerMToken', optionalNumber(raw.outputPerMToken));
  assign(window, 'cacheReadPerMToken', optionalNumber(raw.cacheReadPerMToken));
  assign(window, 'multiplier', optionalNumber(raw.multiplier));
  // holidayCalendar is passed through only; the estimate ignores it.
  const holidayCalendar = optionalString(raw.holidayCalendar);
  if (holidayCalendar !== undefined && holidayCalendar !== 'cn_statutory') fail();
  assign(window, 'holidayCalendar', holidayCalendar);
  return window;
}

/** Strictly decodes per the shared schema `$defs/pricingV2`; any mismatch (including a key outside the allowlist) discards the whole block and returns undefined. */
export function decodePricingV2(raw: unknown): PricingV2 | undefined {
  if (!isRecord(raw)) return undefined;
  try {
    onlyKeys(raw, [
      'currencyCode', 'unit', 'base', 'cache', 'contextTiers', 'timeWindows', 'regionSurcharges', 'perUnit',
    ]);
    if (raw.unit !== 'per_token' && raw.unit !== 'per_image' && raw.unit !== 'per_second') fail();
    const out: PricingV2 = { unit: raw.unit };
    assign(out, 'currencyCode', optionalString(raw.currencyCode));
    assign(out, 'base', decodeBase(raw.base));
    assign(out, 'cache', decodeCache(raw.cache));
    assign(out, 'contextTiers', optionalArray(raw.contextTiers)?.map(decodeTier));
    assign(out, 'timeWindows', optionalArray(raw.timeWindows)?.map(decodeWindow));
    const surcharges = optionalArray(raw.regionSurcharges);
    if (surcharges) {
      out.regionSurcharges = surcharges.map((item) => {
        if (!isRecord(item) || typeof item.regionScope !== 'string' || item.regionScope.length === 0) fail();
        onlyKeys(item, ['regionScope', 'multiplier']);
        const multiplier = optionalNumber(item.multiplier);
        if (multiplier === undefined) fail();
        return { regionScope: item.regionScope, multiplier };
      });
    }
    assign(out, 'perUnit', optionalNumber(raw.perUnit));
    return out;
  } catch (error) {
    if (error instanceof PricingV2ShapeError) return undefined;
    throw error;
  }
}

// -- Estimation --

/** A resolved set of unit prices (per M token). */
interface PriceSet {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite5m: number;
  cacheWrite1h: number;
}

/** Tier overrides; a missing cache price falls back to that tier's input price. */
function priceSetFor(
  base: { input: number; output: number; cacheRead?: number; cacheWrite5m?: number; cacheWrite1h?: number },
  tier: PricingV2ContextTier | undefined,
): PriceSet {
  const input = tier?.inputPerMToken ?? base.input;
  const output = tier?.outputPerMToken ?? base.output;
  const cacheRead = tier?.cacheReadPerMToken ?? base.cacheRead;
  const cacheWrite5m = tier?.cacheWritePerMToken ?? base.cacheWrite5m;
  const cacheWrite1h = tier?.cacheWritePerMToken ?? base.cacheWrite1h;
  return {
    input,
    output,
    cacheRead: cacheRead ?? input * 0.5,
    cacheWrite5m: cacheWrite5m ?? input * 1.25,
    cacheWrite1h: cacheWrite1h ?? input * 2,
  };
}

function minutesOf(hhmm: string): number {
  const [h, m] = hhmm.split(':');
  return Number(h) * 60 + Number(m);
}

/** Weekday index (0 = Sunday) and local minute in the window's time zone; null when the time zone cannot be resolved. */
function localClock(at: Date, timeZone: string): { weekday: number; minute: number } | null {
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat('en-US', {
      timeZone,
      weekday: 'long',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    }).formatToParts(at);
  } catch {
    return null;
  }
  const part = (type: string) => parts.find((p) => p.type === type)?.value;
  const weekday = WEEKDAYS.indexOf((part('weekday') ?? '').toLowerCase() as PricingV2Weekday);
  const hour = Number(part('hour'));
  const minute = Number(part('minute'));
  if (weekday < 0 || !Number.isFinite(hour) || !Number.isFinite(minute)) return null;
  return { weekday, minute: (hour % 24) * 60 + minute };
}

function windowMatches(window: PricingV2TimeWindow, at: Date): boolean {
  const clock = localClock(at, window.timezone);
  if (!clock) return false;
  const dayAllowed = (weekday: number) =>
    !window.days || window.days.includes(WEEKDAYS[(weekday + 7) % 7]!);
  const start = minutesOf(window.start);
  const end = minutesOf(window.end);
  const m = clock.minute;
  if (end > start) return start <= m && m < end && dayAllowed(clock.weekday);
  // Crossing midnight: days refers to the day the window starts.
  return (m >= start && dayAllowed(clock.weekday)) || (m < end && dayAllowed(clock.weekday - 1));
}

function applyWindow(prices: PriceSet, window: PricingV2TimeWindow | undefined): PriceSet {
  if (!window) return prices;
  if (window.multiplier !== undefined) {
    const k = window.multiplier;
    return {
      input: prices.input * k,
      output: prices.output * k,
      cacheRead: prices.cacheRead * k,
      cacheWrite5m: prices.cacheWrite5m * k,
      cacheWrite1h: prices.cacheWrite1h * k,
    };
  }
  return {
    ...prices,
    input: window.inputPerMToken ?? prices.input,
    output: window.outputPerMToken ?? prices.output,
    cacheRead: window.cacheReadPerMToken ?? prices.cacheRead,
  };
}

function tokens(value: number): number {
  return Number.isFinite(value) && value > 0 ? value : 0;
}

/**
 * Estimates the cost of one request from pricingV2; at is the pricing instant (UTC).
 * amount is in the currency's major unit; currencyCode is passed through and omitted when absent.
 */
export function estimatePricingV2(
  pricingV2: PricingV2,
  usage: PricingV2Usage,
  at: Date,
): PricingV2Estimate {
  if (pricingV2.unit !== 'per_token') return { status: 'not_applicable' };
  const baseInput = pricingV2.base?.inputPerMToken;
  const baseOutput = pricingV2.base?.outputPerMToken;
  if (typeof baseInput !== 'number' || typeof baseOutput !== 'number') {
    return { status: 'unavailable' };
  }
  const base = {
    input: baseInput,
    output: baseOutput,
    cacheRead: pricingV2.cache?.readPerMToken,
    cacheWrite5m: pricingV2.cache?.writes?.find((w) => w.ttl === '5m')?.perMToken,
    cacheWrite1h: pricingV2.cache?.writes?.find((w) => w.ttl === '1h')?.perMToken,
  };
  const window = pricingV2.timeWindows?.find((w) => windowMatches(w, at));
  const priced = (tier: PricingV2ContextTier | undefined) => applyWindow(priceSetFor(base, tier), window);

  const cacheRead = tokens(usage.cacheReadTokens);
  const write5m = tokens(usage.cacheWrite5mTokens);
  const write1h = tokens(usage.cacheWrite1hTokens);
  const uncached = tokens(usage.uncachedInputTokens);
  const output = tokens(usage.outputTokens);
  const totalInput = cacheRead + write5m + write1h + uncached;

  const tiers = [...(pricingV2.contextTiers ?? [])].sort((a, b) => a.aboveInputTokens - b.aboveInputTokens);
  const crossed = tiers.filter((t) => totalInput > t.aboveInputTokens);
  const top = crossed[crossed.length - 1];

  let sum: number;
  if (!top || top.semantics === 'whole_request') {
    const p = priced(top);
    sum =
      uncached * p.input +
      cacheRead * p.cacheRead +
      write5m * p.cacheWrite5m +
      write1h * p.cacheWrite1h +
      output * p.output;
  } else {
    // incremental: inputs are laid out on a token line of cache read -> write 5m -> write 1h -> uncached, and each segment is priced at the tier it falls in.
    const bands = [
      { from: 0, prices: priced(undefined) },
      ...tiers.map((t) => ({ from: t.aboveInputTokens, prices: priced(t) })),
    ];
    const line: Array<{ count: number; price: (p: PriceSet) => number }> = [
      { count: cacheRead, price: (p) => p.cacheRead },
      { count: write5m, price: (p) => p.cacheWrite5m },
      { count: write1h, price: (p) => p.cacheWrite1h },
      { count: uncached, price: (p) => p.input },
    ];
    sum = 0;
    let cursor = 0;
    for (const segment of line) {
      const segStart = cursor;
      const segEnd = cursor + segment.count;
      cursor = segEnd;
      bands.forEach((band, index) => {
        const bandEnd = bands[index + 1]?.from ?? Number.POSITIVE_INFINITY;
        const overlap = Math.min(segEnd, bandEnd) - Math.max(segStart, band.from);
        if (overlap > 0) sum += overlap * segment.price(band.prices);
      });
    }
    sum += output * priced(top).output;
  }

  const amount = sum / 1_000_000;
  return pricingV2.currencyCode !== undefined
    ? { status: 'estimated', amount, currencyCode: pricingV2.currencyCode }
    : { status: 'estimated', amount };
}
