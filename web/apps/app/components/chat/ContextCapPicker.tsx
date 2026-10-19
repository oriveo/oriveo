'use client';

import { useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { ChevronLeft, Circle, CircleCheck } from 'lucide-react';
import { type BudgetCapOption, CONTEXT_BUDGET_CONSTANTS } from '@oriveo/core/context/budget';
import {
  capOptionText,
  capPanelOf,
  capPickerOf,
  commitCustomCap,
  isolatedCompactCount,
  multiplierPhrase,
  type CapPanelInput,
  type CapPickerSelection,
} from '../../lib/core/chat/context-visibility/cap-presentation';
import { updateConversationContextCap } from '../../lib/core/conversation-ops';
import { getVanillaStore } from '../../providers/StoreProvider';
import styles from './ContextCapPicker.module.css';

const FSI = '\u2068';
const PDI = '\u2069';
/** A price-line label this close (percent of the track) to an end replaces that end's label. */
const PRICE_LABEL_EDGE_PERCENT = 20;

interface ContextCapPickerProps {
  conversationId: string;
  /** Production cap presentation input (capPresentationInputOf). */
  capInput: Omit<CapPanelInput, 'used'>;
  modelName: string;
  onBack: () => void;
}

/**
 * P9·U7 "limit for this chat" picker, shown inside the context popover.
 * Options write immediately (follow = clear the conversation cap); the slider is bound to tick indices
 * and writes on release; the number field writes on blur / Enter.
 */
export function ContextCapPicker({ conversationId, capInput, modelName, onBack }: ContextCapPickerProps) {
  const tCap = useTranslations('pages.chat.contextCap');
  const tCommon = useTranslations('common');
  const locale = useLocale();
  const picker = capPickerOf(capInput);
  const isolated = (value: number) => isolatedCompactCount(value, locale);
  const labels = { auto: tCap('auto'), unlimited: tCap('unlimited') };
  const T = capInput.priceLineTokens;
  // Unlimited is bounded by U only: its B is the model's usable amount (null = window unknown).
  const U = picker.unlimited.B;
  const storedCustom = typeof capInput.conversationCap === 'number' ? capInput.conversationCap : null;
  const customValue = storedCustom ?? picker.customStart;

  // Number field draft; null = show the stored value.
  const [draft, setDraft] = useState<string | null>(null);
  const [adjustedTo, setAdjustedTo] = useState<number | null>(null);
  // Slider index while dragging; null = follow the stored value.
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const movedRef = useRef(false);
  const sliderRef = useRef<HTMLInputElement>(null);

  const write = (cap: BudgetCapOption | undefined) => {
    setDraft(null);
    setDragIndex(null);
    updateConversationContextCap(getVanillaStore(), conversationId, cap);
  };

  const select = (selection: CapPickerSelection) => {
    setAdjustedTo(null);
    if (selection === picker.selected) return;
    if (selection === 'follow') write(undefined);
    else write(selection === 'custom' ? picker.customStart : selection);
  };

  const commitSlider = (raw: string) => {
    const index = Number(raw);
    // A key or pointer release without movement (e.g. Tab into the slider) does not snap to a tick.
    if (!movedRef.current && index === picker.sliderIndex) return;
    movedRef.current = false;
    setDragIndex(null);
    const value = picker.ticks[index];
    if (value === undefined) return;
    setAdjustedTo(null);
    if (value !== storedCustom) write(value);
  };
  const commitSliderRef = useRef(commitSlider);
  commitSliderRef.current = commitSlider;

  // Native change fires on release (React's onChange fires on every input event).
  const customOpen = picker.selected === 'custom';
  useEffect(() => {
    const slider = sliderRef.current;
    if (!slider) return undefined;
    const onChange = () => commitSliderRef.current(slider.value);
    slider.addEventListener('change', onChange);
    return () => slider.removeEventListener('change', onChange);
  }, [customOpen]);

  const commitDraft = () => {
    if (draft === null) return;
    const result = commitCustomCap(draft, U, customValue);
    setDraft(null);
    if (result.restored) return;
    setAdjustedTo(result.adjusted ? result.value : null);
    if (result.value !== storedCustom) write(result.value);
  };

  const onInputKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key !== 'Enter' || event.nativeEvent.isComposing) return;
    event.preventDefault();
    commitDraft();
  };

  // Head row: model · window · usable [· price line].
  const model = `${FSI}${modelName}${PDI}`;
  let head = capInput.W !== null && U !== null
    ? tCap('head', { model, window: isolated(capInput.W), usable: isolated(U) })
    : tCap('headUnknown', { model });
  if (capInput.W !== null && T !== null) head = tCap('headPriceLine', { head, line: isolated(T) });

  const followHint = tCap('followHint', { value: capOptionText(capInput.globalCap, locale, labels) });

  // Window unknown (B null): auto and unlimited share the window-unknown explanation.
  const windowUnknownHint = tCap('hintWindowUnknown');
  let autoHint: string | null = windowUnknownHint;
  const autoB = picker.auto.B;
  if (autoB !== null) {
    autoHint = null;
    const value = isolated(autoB);
    const max = isolated(CONTEXT_BUDGET_CONSTANTS.autoCapDefault);
    if (picker.auto.limitedBy === 'priceLine') autoHint = tCap('autoHintPriceLine', { value });
    else if (picker.auto.limitedBy === 'autoDefault') {
      autoHint = T !== null
        ? tCap('autoHintDefaultBelowLine', { value, max })
        : tCap('autoHintDefault', { value, max });
    } else if (picker.auto.limitedBy === 'window') autoHint = tCap('autoHintWindow', { value });
  }

  let unlimitedHint: string | null = windowUnknownHint;
  if (U !== null) {
    unlimitedHint = picker.unlimitedCrossesPriceLine && T !== null
      ? tCap('unlimitedHintPriceLine', { value: isolated(U), line: isolated(T) })
      : tCap('unlimitedHint', { value: isolated(U) });
  }

  // Echo: the dragged tick, else the clamped value the typed text would store (hidden when it does not parse).
  const sliderIndex = dragIndex ?? picker.sliderIndex;
  const dragValue = dragIndex !== null ? picker.ticks[dragIndex] : null;
  const inputText = dragValue !== null ? String(dragValue) : draft ?? String(customValue);
  const preview = commitCustomCap(inputText, U, customValue);
  const echoValue = dragValue ?? (preview.restored ? null : preview.value);
  // Price-line hint follows the stored value or the dragged tick only; a typed draft changes it after commit.
  const liveHint = dragValue !== null
    ? capPickerOf({ ...capInput, conversationCap: dragValue }).customHint
    : picker.customHint;
  const a11yValue = dragValue ?? picker.ticks[sliderIndex] ?? customValue;
  let customHintText: string | null = null;
  if (liveHint.kind !== 'none' && T !== null) {
    const line = isolated(T);
    if (liveHint.kind === 'over') {
      const mult = multiplierPhrase(capPanelOf({ ...capInput, used: 0 }).multiplier, locale, tCap);
      customHintText = mult ? tCap('customOver', { line, mult }) : tCap('customOverPlain', { line });
    } else if (liveHint.kind === 'at') customHintText = tCap('customAt');
    else customHintText = tCap('customUnder', { gap: isolated(liveHint.gap) });
  }
  const over = liveHint.kind === 'over';
  const lastTick = picker.ticks.length - 1;
  const tickPercent = (index: number) => (lastTick > 0 ? (index / lastTick) * 100 : 0);
  // The price-line label is always drawn; an endpoint label it would overlap is dropped.
  const priceTick = picker.priceLineTickIndex !== null && T !== null ? picker.priceLineTickIndex : null;
  const pricePercent = priceTick !== null ? tickPercent(priceTick) : null;
  const priceAtStart = pricePercent !== null && pricePercent < PRICE_LABEL_EDGE_PERCENT;
  const priceAtEnd = pricePercent !== null && !priceAtStart && pricePercent > 100 - PRICE_LABEL_EDGE_PERCENT;
  let priceLabelClass = styles.tickAnchor;
  if (priceAtStart) priceLabelClass = styles.tickStart;
  else if (priceAtEnd) priceLabelClass = styles.tickEnd;

  const option = (selection: CapPickerSelection, title: string, hint: string | null, hintOver = false): ReactNode => {
    const selected = picker.selected === selection;
    return (
      <button
        type="button"
        role="radio"
        aria-checked={selected}
        data-testid={`chat-context-cap-${selection}`}
        className={[styles.option, selected ? styles.optionSelected : ''].filter(Boolean).join(' ')}
        onClick={() => select(selection)}
      >
        <span className={styles.optionCopy}>
          <span className={styles.optionTitle}>{title}</span>
          {hint ? (
            <span className={styles.optionHint} data-over={hintOver ? 'true' : undefined}>
              {hint}
            </span>
          ) : null}
        </span>
        <span className={styles.optionRadio} aria-hidden="true">
          {selected ? <CircleCheck size={18} strokeWidth={2.2} /> : <Circle size={18} strokeWidth={2} />}
        </span>
      </button>
    );
  };

  return (
    <div className={styles.picker}>
      <header className={styles.header}>
        <button type="button" className={styles.back} data-testid="chat-context-cap-back" onClick={onBack}>
          <ChevronLeft size={16} strokeWidth={2.2} className="rtl-mirror" aria-hidden="true" />
          {tCommon('back')}
        </button>
        <h2 id="context-cap-picker-title" className={styles.title}>
          {tCap('title')}
        </h2>
      </header>
      <p className={styles.head}>{head}</p>

      <div className={styles.options} role="radiogroup" aria-labelledby="context-cap-picker-title">
        {option('follow', tCap('follow'), followHint)}
        {option('auto', tCap('auto'), autoHint)}
        {option('unlimited', tCap('unlimited'), unlimitedHint, picker.unlimitedCrossesPriceLine)}
        {option('custom', tCap('custom'), null)}
      </div>

      {customOpen ? (
        <div className={styles.custom} data-over={over ? 'true' : undefined}>
          <input
            ref={sliderRef}
            type="range"
            className={styles.slider}
            data-testid="chat-context-cap-slider"
            min={0}
            max={Math.max(lastTick, 0)}
            step={1}
            value={sliderIndex}
            aria-label={tCap('inputLabel')}
            aria-valuetext={tCap('sliderA11y', { value: isolated(a11yValue) })}
            onChange={(event) => {
              movedRef.current = true;
              setDraft(null);
              setAdjustedTo(null);
              setDragIndex(Number(event.target.value));
            }}
            onPointerUp={(event) => commitSlider(event.currentTarget.value)}
            onKeyUp={(event) => commitSlider(event.currentTarget.value)}
          />
          {picker.ticks.length > 0 ? (
            <div className={styles.ticks} aria-hidden="true">
              {priceAtStart ? null : <span className={styles.tickStart}>{isolated(picker.ticks[0])}</span>}
              {lastTick > 0 && !priceAtEnd ? (
                <span className={styles.tickEnd}>{isolated(picker.ticks[lastTick])}</span>
              ) : null}
              {pricePercent !== null && T !== null ? (
                <span
                  className={`${priceLabelClass} ${styles.tickPriceLine}`}
                  data-testid="chat-context-cap-tick-price-line"
                  style={priceAtStart || priceAtEnd ? undefined : { insetInlineStart: `${pricePercent}%` }}
                >
                  <span>{tCap('priceLineTick', { value: isolated(T) })}</span>
                </span>
              ) : null}
            </div>
          ) : null}
          <label className={styles.field}>
            <span className={styles.fieldLabel}>{tCap('inputLabel')}</span>
            <input
              type="text"
              inputMode="numeric"
              autoComplete="off"
              className={styles.input}
              data-testid="chat-context-cap-input"
              value={inputText}
              onChange={(event) => {
                setDragIndex(null);
                setDraft(event.target.value);
                setAdjustedTo(null);
              }}
              onBlur={commitDraft}
              onKeyDown={onInputKeyDown}
            />
            <span className={styles.fieldUnit}>{tCap('inputUnit')}</span>
          </label>
          {echoValue !== null ? (
            <p className={styles.echo}>{tCap('inputEcho', { value: isolated(echoValue) })}</p>
          ) : null}
          {adjustedTo !== null ? (
            <p className={styles.adjusted} role="status">
              {tCap('adjusted', { value: isolated(adjustedTo) })}
            </p>
          ) : null}
          {customHintText !== null ? (
            <p className={styles.hint} data-testid="chat-context-cap-custom-hint" data-over={over ? 'true' : undefined}>
              {customHintText}
            </p>
          ) : null}
        </div>
      ) : null}

      <p className={styles.footer}>{tCap('footer')}</p>
    </div>
  );
}
