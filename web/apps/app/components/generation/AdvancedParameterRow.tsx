'use client';

import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import type { GenerationParameterProfile, GenerationParameterValue } from '@oriveo/core/providers/request-builders/types';
import type { GenerationParameterBound, GenerationParameterRow } from '../../lib/core/chat/generation-parameter-rows';
import { advancedMemberShortTitle } from '../../lib/core/chat/advanced-settings-layout';
import {
  GENERATION_PARAMETER_UNSET_LABEL_KEYS,
  advancedMemberShortTitleCopy,
  generationDisplayValueCopy,
  generationParameterTitleCopy,
  generationRowStatusCopy,
  generationValidationIssueCopy,
} from '../../lib/core/chat/model-options-copy';
import { addStopSequence, canAddStopSequence, removeStopSequence, visibleStopSequence } from '../../lib/core/chat/stop-sequence-tags';
import { useCopy } from './useCopy';
import styles from './AdvancedSettingsList.module.css';

type ProfileParameter = GenerationParameterProfile['parameters'][number];

/** The part the panel computes from evidence and the data layer does not own: whether it is editable, inline labels, and the exit for "not adjustable". */
export interface AdvancedRowExtras {
  editable: boolean;
  /** Inline "unverified" label; when the whole page already carries the unverified tone, only rows in `inlineIds` get it. */
  unverifiedLabel?: string;
  supportLabel?: string;
  supportDetail?: string;
  /** Note for reasoning-group rows that have no write path. */
  statusNote?: string;
  fixedText?: string;
  notAdjustable?: ReactNode;
}

/** Only these three items get a description sentence (temperature, max tokens, stop sequences). */
const NOTE_KEYS: Readonly<Record<string, string>> = {
  temperature: 'generationParameterTemperatureNote',
  max_output_tokens: 'generationParameterMaxTokensNote',
  stop: 'advancedStopSequencesNote',
  stop_sequences: 'advancedStopSequencesNote',
};

export function AdvancedParameterRow({ row, parameter, extras, inputId, isReadOnly, onSet, onClear, onOmit }: {
  row: GenerationParameterRow;
  parameter: ProfileParameter;
  extras: AdvancedRowExtras;
  inputId: string;
  isReadOnly: boolean;
  onSet: (value: GenerationParameterValue) => void;
  onClear: () => void;
  onOmit: () => void;
}) {
  const tc = useTranslations('common');
  const copy = useCopy();
  const [expanded, setExpanded] = useState(false);
  const short = advancedMemberShortTitle(row.id);
  const title = short ? `${copy(advancedMemberShortTitleCopy(short.title))} ${short.symbol}` : copy(generationParameterTitleCopy(row.id));
  const superseded = Boolean(row.supersededById);
  const editable = extras.editable && !isReadOnly;
  const error = row.validationIssue ? copy(generationValidationIssueCopy(row.id, row.validationIssue)) : undefined;
  // Rows that are taken over show no drop reason; only when expanded does it say "X is on, so this item has no effect".
  const reason = !error && !superseded ? statusText(row, copy) : undefined;
  return (
    <div className={styles.row} data-advanced-row={row.id} data-parameter={row.id} data-superseded={superseded ? 'true' : undefined}>
      <button type="button" className={styles.rowHead} aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}>
        <span className={styles.rowTitle}>
          <span className={styles.titleText}>{title}</span>
          {extras.unverifiedLabel && <em className={styles.badge} data-testid="generation-unverified-badge">{extras.unverifiedLabel}</em>}
        </span>
        <Trailing row={row} fixedText={extras.fixedText} />
      </button>
      {error && <p className={styles.error} role="alert">{error}</p>}
      {reason && <p className={styles.note}>{reason}</p>}
      {extras.statusNote && <p className={styles.note}>{extras.statusNote}</p>}
      {extras.supportLabel && <p className={styles.note} data-testid="generation-support-line">{extras.supportLabel}</p>}
      {extras.supportDetail && <p className={styles.note} data-testid="generation-support-detail">{extras.supportDetail}</p>}
      {extras.notAdjustable}
      {expanded && (
        <div className={styles.editor}>
          {superseded && <p className={styles.note}>{copy(generationRowStatusCopy(row)!)}</p>}
          {editable && !superseded && (
            <ValueEditor row={row} parameter={parameter} inputId={inputId} title={title} onSet={onSet} onClear={onClear} />
          )}
          {error && row.allowedRange && (
            <p className={styles.error}>{tc('advancedAllowedRange', { range: rangeText(row.allowedRange) })}</p>
          )}
          {NOTE_KEYS[row.id] && <p className={styles.note} data-testid="generation-parameter-annotation">{tc(NOTE_KEYS[row.id])}</p>}
          {editable && (
            <div className={styles.ghostActions}>
              <button type="button" className={styles.ghost} disabled={row.standing !== 'editedHere'} onClick={onClear}>{tc('advancedUseModelDefault')}</button>
              <button type="button" className={styles.ghost} disabled={row.isOmitted && row.standing === 'editedHere'} onClick={onOmit}>{tc('advancedDontSend')}</button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function statusText(row: GenerationParameterRow, copy: ReturnType<typeof useCopy>): string | undefined {
  const status = generationRowStatusCopy(row);
  return status ? copy(status) : undefined;
}

/** The value on the right: changed at this layer -> set pill; inherited from a lower layer -> grey pill + "model default"; nobody set it -> secondary-colour text. */
function Trailing({ row, fixedText }: { row: GenerationParameterRow; fixedText?: string }) {
  const tc = useTranslations('common');
  const copy = useCopy();
  if (fixedText !== undefined) return <span className={styles.unset} data-value-source="fixed">{fixedText}</span>;
  if (row.isOmitted) {
    return <span className={styles.unset} data-value-source={row.source}>{tc('generationParameterOmittedValue')}</span>;
  }
  const text = row.displayValue ? copy(generationDisplayValueCopy(row.displayValue)) : undefined;
  if (row.standing === 'editedHere' && text !== undefined) {
    return <span className={styles.setChip} data-value-source={row.source}>{text}</span>;
  }
  if (row.standing === 'inherited' && text !== undefined) {
    return (
      <span className={styles.inheritedChip} data-value-source={row.source}>
        {text}
        <em>{tc('advancedYourDefault')}</em>
      </span>
    );
  }
  // Nobody set it: show the engine's own default in grey when it has one, otherwise say who decides.
  if (text !== undefined) return <span className={styles.engineDefault} data-value-source={row.source}>{text}</span>;
  const unset = row.unsetLabel ? tc(GENERATION_PARAMETER_UNSET_LABEL_KEYS[row.unsetLabel].slice('common.'.length)) : '';
  return <span className={styles.unset} data-value-source={row.source}>{unset}</span>;
}

function ValueEditor({ row, parameter, inputId, title, onSet, onClear }: {
  row: GenerationParameterRow;
  parameter: ProfileParameter;
  inputId: string;
  title: string;
  onSet: (value: GenerationParameterValue) => void;
  onClear: () => void;
}) {
  const tc = useTranslations('common');
  const copy = useCopy();
  const editedValue = row.standing === 'editedHere' && row.displayValue ? copy(generationDisplayValueCopy(row.displayValue)) : '';
  const [draft, setDraft] = useState(editedValue);
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => { input.current?.focus(); }, []);
  const schema = parameter.valueSchema;

  if (schema === 'boolean') {
    const checked = row.displayValue?.kind === 'boolean' && row.displayValue.value;
    return <input id={inputId} aria-label={title} type="checkbox" className={styles.toggle} checked={checked} onChange={(event) => onSet(event.target.checked)} />;
  }
  if (schema === 'enum' && parameter.enumValues?.length) {
    return (
      <select id={inputId} aria-label={title} className={styles.field} value={editedValue} onChange={(event) => {
        const match = parameter.enumValues?.find((item) => String(item) === event.target.value);
        if (match === undefined) onClear();
        else if (typeof match === 'string' || typeof match === 'number') onSet(match);
      }}>
        <option value="">{tc('advancedModelDefaultValue')}</option>
        {editedValue && !parameter.enumValues.some((item) => String(item) === editedValue) && <option value={editedValue}>{editedValue}</option>}
        {parameter.enumValues.map((item) => <option key={String(item)} value={String(item)}>{String(item)}</option>)}
      </select>
    );
  }
  if (schema === 'string-list' && STOP_SEQUENCE_IDS.has(row.id)) {
    return <StopSequenceEditor list={row.listValue ?? []} onSet={onSet} />;
  }
  if (schema === 'json-schema') return <JsonSchemaEditor inputId={inputId} title={title} row={row} onSet={onSet} onClear={onClear} />;

  const numeric = schema === 'number' || schema === 'integer';
  const commit = (raw: string) => {
    setDraft(raw);
    if (!raw.trim()) return onClear();
    if (schema === 'string-list') return onSet(raw.split(/[,\n]/).map((item) => item.trim()).filter(Boolean));
    // Input is not blocked and values are not clamped: text that does not parse as a number is still stored, the row model reports the validation error, and this item is not sent until it is fixed.
    const number = Number(raw);
    onSet(numeric && Number.isFinite(number) ? number : raw);
  };
  const lower = row.allowedRange?.lower?.value;
  const upper = row.allowedRange?.upper?.value;
  const slider = numeric && lower !== undefined && upper !== undefined && upper > lower;
  const tick = slider && row.modelDefaultValue?.kind === 'text' ? Number(row.modelDefaultValue.text) : undefined;
  const tickPercent = slider && tick !== undefined && Number.isFinite(tick)
    ? Math.min(100, Math.max(0, ((tick - lower) / (upper - lower)) * 100))
    : undefined;
  const current = Number(draft);
  return (
    <>
      <input
        ref={input}
        id={inputId}
        aria-label={title}
        type="text"
        inputMode={numeric ? 'decimal' : 'text'}
        className={styles.field}
        value={draft}
        placeholder={row.fallbackValue ? copy(generationDisplayValueCopy(row.fallbackValue)) : undefined}
        onChange={(event) => commit(event.target.value)}
      />
      {slider && (
        <div className={styles.slider} data-tick={tickPercent !== undefined ? 'true' : undefined}>
          <input
            type="range"
            aria-label={title}
            min={lower}
            max={upper}
            step={schema === 'integer' ? 1 : (upper - lower) / 100}
            value={Number.isFinite(current) && draft ? Math.min(Math.max(current, lower), upper) : (tick ?? lower)}
            onChange={(event) => commit(event.target.value)}
          />
          {/* Draw the "model default" tick only when a lower layer really provides a value. */}
          {tickPercent !== undefined && (
            <span
              className={styles.tick}
              // When the tick sits at either end the label aligns inward so it does not stick out past the slider.
              data-edge={tickPercent < 15 ? 'start' : tickPercent > 85 ? 'end' : undefined}
              style={tickPercent > 85 ? { insetInlineEnd: `${100 - tickPercent}%` } : { insetInlineStart: `${tickPercent}%` }}
            >
              {`${tc('advancedYourDefault')} ${row.modelDefaultValue && copy(generationDisplayValueCopy(row.modelDefaultValue))}`}
            </span>
          )}
        </div>
      )}
    </>
  );
}

const STOP_SEQUENCE_IDS = new Set(['stop', 'stop_sequences']);

/**
 * Each entry becomes a tag; commas, spaces and newlines inside a sequence are content and are not split. It shows the effective entries (the lower layer's when inherited),
 * and any edit writes the whole group to this layer. The Web parameter table declares no entry limit, so there is no cap and no counter.
 */
function StopSequenceEditor({ list, limit, onSet }: {
  list: readonly string[];
  limit?: number;
  onSet: (value: GenerationParameterValue) => void;
}) {
  const tc = useTranslations('common');
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState('');
  const confirm = () => {
    const next = addStopSequence(list, draft, limit);
    // Empty or duplicate: nothing is added and no message is shown; the input keeps its text.
    if (!next) return;
    onSet(next);
    setDraft('');
    setAdding(false);
  };
  return (
    <>
      {limit !== undefined && <p className={styles.note}>{`${list.length} / ${limit}`}</p>}
      <div className={styles.tags}>
        {list.map((sequence, index) => {
          const visible = visibleStopSequence(sequence);
          return (
            <span key={`${index}:${sequence}`} className={styles.tag}>
              <span>{visible}</span>
              <button
                type="button"
                className={styles.tagRemove}
                aria-label={tc('advancedStopSequenceRemove', { sequence: visible })}
                onClick={() => onSet(removeStopSequence(list, index))}
              >
                <svg width="9" height="9" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true"><path d="M2 2l8 8M10 2l-8 8" /></svg>
              </button>
            </span>
          );
        })}
        {!adding && canAddStopSequence(list, limit) && (
          <button type="button" className={styles.tagAdd} onClick={() => setAdding(true)}>{tc('advancedStopSequenceAdd')}</button>
        )}
      </div>
      {adding && (
        // Enter confirms; Shift+Enter inserts a newline (a sequence may contain newlines); Esc closes.
        <textarea
          autoFocus
          rows={1}
          className={`${styles.field} ${styles.tagInput}`}
          value={draft}
          placeholder={tc('advancedNewStopSequence')}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault();
              confirm();
            } else if (event.key === 'Escape') {
              setDraft('');
              setAdding(false);
            }
          }}
        />
      )}
    </>
  );
}

function JsonSchemaEditor({ inputId, title, row, onSet, onClear }: {
  inputId: string;
  title: string;
  row: GenerationParameterRow;
  onSet: (value: GenerationParameterValue) => void;
  onClear: () => void;
}) {
  const tc = useTranslations('common');
  const [draft, setDraft] = useState(() => row.standing === 'editedHere' && row.displayValue?.kind === 'text' ? row.displayValue.text : '');
  const [invalid, setInvalid] = useState(false);
  return (
    <>
      <textarea id={inputId} aria-label={title} aria-invalid={invalid} className={styles.schema} value={draft} onChange={(event) => {
        const raw = event.target.value;
        setDraft(raw);
        if (!raw.trim()) {
          setInvalid(false);
          onClear();
          return;
        }
        try {
          const parsed: unknown = JSON.parse(raw);
          setInvalid(false);
          onSet(parsed as GenerationParameterValue);
        } catch {
          setInvalid(true);
        }
      }} />
      {invalid && <p className={styles.error} role="alert">{tc('advancedErrorJsonSchema')}</p>}
    </>
  );
}

function rangeText(range: NonNullable<GenerationParameterRow['allowedRange']>): string {
  const { lower, upper } = range;
  if (lower && upper) return `${boundText(lower, '(')} – ${boundText(upper, ')')}`;
  if (lower) return `${lower.open ? '>' : '≥'} ${lower.value}`;
  return `${upper!.open ? '<' : '≤'} ${upper!.value}`;
}

function boundText(bound: GenerationParameterBound, openMark: string): string {
  if (!bound.open) return String(bound.value);
  return openMark === '(' ? `(${bound.value}` : `${bound.value})`;
}
