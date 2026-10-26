/**
 * Pre-send cap / price-line confirmation.
 * Spec: shared/context-contracts/context-cap-confirm.v1.json — the fixture `rules` text is the algorithm.
 * Decision is pure; the per-conversation state is a local preference (not synced).
 */
import type { AIModel, AppPreference } from '@oriveo/shared';
import type { BudgetLimitedBy } from '@oriveo/core/context/budget';
import { getPreference, setPreference } from '../../../infra/storage/preferences';
import { formatCostAmount, normalizeCostCurrency } from '../../cost/cost-currency';
import { resolvePriceLineReminderEnabled } from '../../context-cap-preferences';
import {
  type CapPanelInput,
  type CapPanelModel,
  capMultiplierOf,
  effectiveCapBoundOf,
  isolatedCompactCount,
  multiplierPhrase,
} from './cap-presentation';

type Translate = (key: string, values?: Record<string, string>) => string;

const FSI = '⁨';
const PDI = '⁩';

export type CapConfirmAttempt =
  | 'send'
  | 'edit'
  | 'regenerate'
  | 'retry'
  | 'continue'
  | 'overflowRecovery'
  | 'toolLoopLeg';

export interface PriceLineAcknowledgement {
  model: string;
  T: number;
}

export interface CapConfirmState {
  suppressed: boolean;
  acknowledged: PriceLineAcknowledgement | null;
}

export interface CapConfirmInput {
  attempt: CapConfirmAttempt;
  /** Runtime model id of this request. */
  model: string;
  reminderEnabled: boolean;
  conversationState: CapConfirmState;
  /** Per-million prices below ({base}) and above ({long}) the price line. */
  pricing: CapPanelInput['pricing'];
  /** Plan estimate P-hat after pre-send compaction. */
  estimatedInput: number;
  B: number | null;
  limitedBy: BudgetLimitedBy | null;
  priceLineTokens: number | null;
}

export type CapConfirmKind = 'none' | 'overCap' | 'priceLine' | 'overCapAndPriceLine';

export interface CapConfirmDecision {
  kind: CapConfirmKind;
  showDontAsk: boolean;
  /** Input-only cost in the catalog price currency (ISO 4217, no conversion), 6 decimals; only for the price line. */
  cost: { long: number; base: number; currencyCode: string } | null;
  multiplier: CapPanelModel['multiplier'];
  acknowledgeOnConfirm: PriceLineAcknowledgement | null;
}

const ASKING_ATTEMPTS: ReadonlySet<CapConfirmAttempt> = new Set(['send', 'edit']);

const NONE: CapConfirmDecision = {
  kind: 'none',
  showDontAsk: false,
  cost: null,
  multiplier: null,
  acknowledgeOnConfirm: null,
};

const round6 = (value: number) => Math.round(value * 1e6) / 1e6;

const positive = (value: number | null | undefined): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value > 0;

export function decideCapConfirm(input: CapConfirmInput): CapConfirmDecision {
  if (!ASKING_ATTEMPTS.has(input.attempt)) return NONE;
  const P = input.estimatedInput;
  const overCap = input.limitedBy === 'custom' && input.B !== null && P > input.B;
  const T = input.priceLineTokens;
  const acknowledged = input.conversationState.acknowledged;
  const priceLine =
    T !== null &&
    P >= T &&
    input.reminderEnabled &&
    !input.conversationState.suppressed &&
    !(acknowledged !== null && acknowledged.model === input.model && acknowledged.T === T);
  if (!overCap && !priceLine) return NONE;
  if (!priceLine) return { ...NONE, kind: 'overCap' };

  // Unreadable price currency: no amount (falls back to the multiplier), never shown as dollars.
  const currencyCode = normalizeCostCurrency(input.pricing?.currencyCode);
  const basePrompt = input.pricing?.base?.prompt;
  const longPrompt = input.pricing?.long?.prompt;
  const cost =
    positive(basePrompt) && positive(longPrompt) && currencyCode !== null
      ? { long: round6((P * longPrompt) / 1e6), base: round6((P * basePrompt) / 1e6), currencyCode }
      : null;
  return {
    kind: overCap ? 'overCapAndPriceLine' : 'priceLine',
    showDontAsk: true,
    cost,
    multiplier: cost === null ? capMultiplierOf(input.pricing) : null,
    acknowledgeOnConfirm: { model: input.model, T: T! },
  };
}

// ---- Copy ----

export interface CapConfirmTextContext {
  estimatedInput: number;
  B: number | null;
  priceLineTokens: number | null;
  /** AIModel.name (id when empty); see capConfirmModelName. */
  modelName: string;
  locale: string;
}

export interface CapConfirmText {
  title: string;
  body: string;
  showDontAsk: boolean;
  /** Checkbox label (unchecked by default); null when the checkbox is hidden. */
  dontAsk: string | null;
  /** Confirm button label; never the default action. Cancel uses the common cancel key. */
  confirm: string;
}

/** {model} in the confirm copy: AIModel.name, falling back to the id when empty. */
export function capConfirmModelName(model: Pick<AIModel, 'id' | 'name'>): string {
  const name = model.name?.trim();
  return name ? name : model.id;
}

const isolated = (text: string) => `${FSI}${text}${PDI}`;

/**
 * Dialog copy for a decision; null when nothing is asked.
 * tCap = pages.chat.contextCap (holds both the confirm keys and the U7 multiplier phrases).
 */
export function capConfirmTextOf(
  decision: CapConfirmDecision,
  context: CapConfirmTextContext,
  tCap: Translate,
): CapConfirmText | null {
  if (decision.kind === 'none') return null;
  const { locale } = context;
  const estimate = isolatedCompactCount(context.estimatedInput, locale);
  const overCapBody = () =>
    tCap('confirmOverCapBody', {
      estimate,
      cap: context.B === null ? '' : isolatedCompactCount(context.B, locale),
    });

  // Price-line sentence: cost, else multiplier, else plain. prefix = 'confirmPriceLineBody' | 'confirmAlsoPriceLine'.
  const lineSentence = (prefix: 'confirmPriceLineBody' | 'confirmAlsoPriceLine') => {
    const values: Record<string, string> = {
      estimate,
      model: isolated(context.modelName),
      line: context.priceLineTokens === null ? '' : isolatedCompactCount(context.priceLineTokens, locale),
    };
    const long = decision.cost ? formatCostAmount(decision.cost.long, decision.cost.currencyCode, locale) : '';
    const base = decision.cost ? formatCostAmount(decision.cost.base, decision.cost.currencyCode, locale) : '';
    if (long && base) {
      const key = prefix === 'confirmPriceLineBody' ? 'confirmPriceLineBodyCost' : 'confirmAlsoPriceLineCost';
      return tCap(key, { ...values, cost: isolated(long), base: isolated(base) });
    }
    const phrase = multiplierPhrase(decision.multiplier, locale, tCap);
    if (phrase) {
      const key = prefix === 'confirmPriceLineBody' ? 'confirmPriceLineBodyMult' : 'confirmAlsoPriceLineMult';
      return tCap(key, { ...values, multiplier: phrase });
    }
    return tCap(prefix, values);
  };

  let title: string;
  let body: string;
  if (decision.kind === 'overCap') {
    title = tCap('confirmOverCapTitle');
    body = overCapBody();
  } else if (decision.kind === 'priceLine') {
    title = tCap('confirmPriceLineTitle');
    body = lineSentence('confirmPriceLineBody');
  } else {
    title = tCap('confirmOverCapTitle');
    body = `${overCapBody()}\n${lineSentence('confirmAlsoPriceLine')}`;
  }
  return {
    title,
    body,
    showDontAsk: decision.showDontAsk,
    dontAsk: decision.showDontAsk ? tCap('confirmDontAsk') : null,
    confirm: tCap('confirmSend'),
  };
}

// ---- Local per-conversation state ----

const DEFAULT_STATE: CapConfirmState = { suppressed: false, acknowledged: null };

export function capConfirmStateKey(conversationId: string): string {
  return `context_price_line_confirm:${conversationId}`;
}

function acknowledgementOf(value: unknown): PriceLineAcknowledgement | null {
  if (!value || typeof value !== 'object') return null;
  const { model, T } = value as Record<string, unknown>;
  if (typeof model !== 'string' || typeof T !== 'number' || !Number.isSafeInteger(T)) return null;
  return { model, T };
}

/** Missing or malformed = {suppressed: false, acknowledged: null}. */
export function readCapConfirmState(conversationId: string): CapConfirmState {
  const raw = getPreference<unknown>(capConfirmStateKey(conversationId), null);
  if (!raw || typeof raw !== 'object') return { ...DEFAULT_STATE };
  const record = raw as Record<string, unknown>;
  return { suppressed: record.suppressed === true, acknowledged: acknowledgementOf(record.acknowledged) };
}

/**
 * Confirm pressed. Only a price-line decision changes state: acknowledged = acknowledgeOnConfirm,
 * and the checked box sets suppressed. Cancel never calls this.
 */
export function recordCapConfirm(conversationId: string, decision: CapConfirmDecision, dontAsk: boolean): void {
  if (!decision.acknowledgeOnConfirm) return;
  const current = readCapConfirmState(conversationId);
  const next: CapConfirmState = {
    suppressed: current.suppressed || (decision.showDontAsk && dontAsk),
    acknowledged: { ...decision.acknowledgeOnConfirm },
  };
  setPreference(capConfirmStateKey(conversationId), next);
}

// ---- Production assembly ----

/**
 * Decision input from the send path: the cap presentation input (capPresentationInputOf: window, price line
 * and decoded catalog price), the global reminder switch and this conversation's local state.
 */
export function capConfirmInputOf(input: {
  presentation: Omit<CapPanelInput, 'used'>;
  attempt: CapConfirmAttempt;
  modelId: string;
  estimatedInput: number;
  preferences: Pick<AppPreference, 'contextPriceLineReminderEnabled'>;
  conversationId: string;
}): CapConfirmInput {
  const { presentation } = input;
  const bound = effectiveCapBoundOf(presentation);
  return {
    attempt: input.attempt,
    model: input.modelId,
    reminderEnabled: resolvePriceLineReminderEnabled(input.preferences),
    conversationState: readCapConfirmState(input.conversationId),
    pricing: presentation.pricing ?? null,
    estimatedInput: input.estimatedInput,
    B: bound.B,
    limitedBy: bound.limitedBy,
    priceLineTokens: presentation.priceLineTokens,
  };
}
