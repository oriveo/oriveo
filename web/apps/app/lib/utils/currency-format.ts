export function formatMinorCurrency(amountMinor: number, currency: string, locale: string): string {
  if (!Number.isSafeInteger(amountMinor) || amountMinor < 0 || !isCurrencyCode(currency)) return '';

  try {
    const formatter = new Intl.NumberFormat(locale, { style: 'currency', currency });
    const fractionDigits = formatter.resolvedOptions().maximumFractionDigits ?? 0;
    return formatCurrency(formatter, amountMinor / 10 ** fractionDigits, currency);
  } catch {
    return '';
  }
}

// Managed balance truncates to two decimals (never round up money the user does not have);
// same rule as iOS balanceDisplayString.
const managedWalletDigits: UsdFormatOptions = {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
  roundingMode: 'trunc',
};

// Credited / bonus amounts: whole dollars show no fraction ("$5"), otherwise two decimals rounded half up
// ("$5.50"); same rule as iOS / Android.
export function formatCreditMicroUSD(amountMicroUSD: number, locale: string): string {
  if (!Number.isFinite(amountMicroUSD) || amountMicroUSD < 0) return '';
  if (amountMicroUSD % 1_000_000 === 0) {
    return formatUsd(amountMicroUSD / 1_000_000, locale, { minimumFractionDigits: 0, maximumFractionDigits: 0 });
  }
  return formatUsd(roundedCents(amountMicroUSD) / 100, locale, twoDigitsHalfUp);
}

// Refund debt always shows two decimals rounded half up (iOS / Android parity); the server's
// display_refund_debt string is no longer shown directly.
export function formatRefundDebtMicroUSD(amountMicroUSD: number, locale: string): string {
  if (!Number.isFinite(amountMicroUSD)) return '';
  return formatUsd(roundedCents(amountMicroUSD) / 100, locale, twoDigitsHalfUp);
}

// Ledger row amounts are formatted from amount_microusd in the app language, matching the server
// precision: at least 2 and at most 6 fraction digits with trailing zeros dropped. Micro-USD is
// exact at 6 digits, so nothing is rounded. Negative values use the platform minus sign; positive
// values get no "+"; zero shows "$0.00".
export function formatLedgerAmountMicroUSD(amountMicroUSD: number, locale: string): string {
  if (!Number.isFinite(amountMicroUSD)) return '';
  return formatUsd(amountMicroUSD / 1_000_000, locale, { minimumFractionDigits: 2, maximumFractionDigits: 6 });
}

const twoDigitsHalfUp: UsdFormatOptions = {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
  roundingMode: 'halfExpand',
};

// Round micro-USD to whole cents on integers: the same integer-cent rule iOS / Android use.
function roundedCents(amountMicroUSD: number): number {
  const cents = amountMicroUSD / 10_000;
  return Math.sign(cents) * Math.round(Math.abs(cents));
}

export function formatBalanceMicroUSD(amountMicroUSD: number, locale: string): string {
  if (!Number.isFinite(amountMicroUSD)) return '';
  // Negative values clamp to $0.00 (iOS parity: Swift.max(0, micro)); an empty string would render a blank area.
  return formatUsd(Math.max(0, amountMicroUSD) / 1_000_000, locale, managedWalletDigits);
}

export type UsdFormatOptions = {
  minimumFractionDigits: number;
  maximumFractionDigits: number;
  roundingMode?: 'halfExpand' | 'trunc';
};

// Intl.NumberFormat construction is costly: cache per locale|digits|rounding so list rows reuse one instance.
const usdFormatters = new Map<string, Intl.NumberFormat>();

function usdFormatter(locale: string, opts: UsdFormatOptions): Intl.NumberFormat {
  const roundingMode = opts.roundingMode ?? 'halfExpand';
  const key = `${locale}|${opts.minimumFractionDigits}|${opts.maximumFractionDigits}|${roundingMode}`;
  let formatter = usdFormatters.get(key);
  if (!formatter) {
    // roundingMode is ES2023 Intl; the shared tsconfig lib stops at es2022.
    const options = {
      style: 'currency',
      currency: 'USD',
      numberingSystem: 'latn',
      useGrouping: true,
      minimumFractionDigits: opts.minimumFractionDigits,
      maximumFractionDigits: opts.maximumFractionDigits,
      roundingMode,
    } as Intl.NumberFormatOptions;
    formatter = new Intl.NumberFormat(locale, options);
    usdFormatters.set(key, formatter);
  }
  return formatter;
}

/**
 * Shared USD display: the app-language platform currency format with the symbol forced to "$"
 * (never US$ / $US / USD), Latin digits and grouping on. Callers keep their own fraction tiers.
 */
export function formatUsd(value: number, locale: string, opts: UsdFormatOptions): string {
  if (!Number.isFinite(value)) return '';
  let formatter: Intl.NumberFormat;
  try {
    formatter = usdFormatter(locale, opts);
  } catch {
    // Malformed locale tag: fall back to en-US instead of hiding the amount.
    formatter = usdFormatter('en-US', opts);
  }
  return formatCurrency(formatter, value, 'USD');
}

function isCurrencyCode(value: string): boolean {
  return /^[A-Z]{3}$/.test(value);
}

function formatCurrency(formatter: Intl.NumberFormat, amount: number, currency: string): string {
  return formatter.formatToParts(amount)
    .map((part) => part.type === 'currency' && currency === 'USD' ? '$' : part.value)
    .join('');
}
