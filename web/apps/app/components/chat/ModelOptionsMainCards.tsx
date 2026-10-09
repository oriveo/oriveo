'use client';

import React, { useRef } from 'react';
import { useTranslations } from 'next-intl';
import { Check, ChevronRight } from 'lucide-react';
import { useCopy } from '../generation/useCopy';
import type { ModelControlFooterEntry } from '../../lib/core/chat/model-control-capability-layout';
import type { ModelOptionLinkAction } from '../../lib/core/chat/model-option-capability-shape';
import type { ModelOptionsPanelModel, ModelOptionsPanelRow } from '../../lib/core/chat/model-options-panel-model';
import {
  CHAT_TEMPLATE_THINKING_STATE_KEYS,
  MODEL_OPTION_CAPABILITY_TITLE_KEYS,
  MODEL_OPTION_CAPTION_KEYS,
  MODEL_OPTION_LINK_KEYS,
  MODEL_OPTION_NOTICE_STATUS_KEYS,
  MODEL_OPTION_PROTOCOL_UNDECIDED_KEYS,
  MODEL_OPTION_WEB_TIMING_KEYS,
  generationDisplayValueCopy,
  generationParameterTitleCopy,
  modelOptionDisclosureStatusCopy,
  modelOptionNoticeBodyCopy,
  modelOptionTierFootnoteCopy,
  modelOptionTierTrailingCopy,
  reasoningTierLabelCopy,
  reasoningTierNoteCopy,
} from '../../lib/core/chat/model-options-copy';
import styles from './InputComposer.module.css';
import main from './ModelOptionsMainCards.module.css';

/**
 * The three blocks of the main "Model options" pane: the second header line, the "Capabilities" card
 * and the "Parameters" card. They only render the result of `modelOptionsPanelModel`; writes and
 * navigation are handled by callbacks supplied by the host.
 */

export type ModelOptionsCardActions = {
  /** Returns false when there is no destination for the link, in which case the link is not rendered. */
  canFollow: (link: ModelOptionLinkAction) => boolean;
  follow: (link: ModelOptionLinkAction, capability: 'web' | 'reasoning') => void;
  onToggle: (row: Extract<ModelOptionsPanelRow, { kind: 'toggle' | 'toggleWithTiming' }>, isOn: boolean) => void;
  onWebTiming: (timing: 'automatic' | 'force') => void;
  onTier: (tapped: string, options: readonly string[], current: string | undefined) => void;
  onAdvancedSettingsLink: () => void;
};

export function ModelOptionsHeaderLine({ model }: { model: ModelOptionsPanelModel }) {
  const tc = useTranslations('common');
  const { connection, transport } = model.header;
  const parts = [connection.name];
  if (transport) parts.push(transport.kind === 'local' ? tc('modelOptionsLocal') : transport.label);
  const markKey = model.mark === 'official' ? 'modelOptionsMarkOfficial'
    : model.mark === 'unverified' ? 'generationParameterUnverifiedBadge' : undefined;
  return (
    <span className={styles.modelControlsSubtitle} data-testid="model-options-header-line">
      {parts.filter(Boolean).join(' · ')}
      {markKey && (
        <>
          {' · '}
          <span className={main.mark} data-mark={model.mark}>{tc(markKey)}</span>
        </>
      )}
    </span>
  );
}

export function ModelOptionsCapabilityCard({ model, actions, notes }: {
  model: ModelOptionsPanelModel;
  actions: ModelOptionsCardActions;
  notes: (entries: ModelControlFooterEntry[], capability: 'web' | 'reasoning') => React.ReactNode;
}) {
  const tc = useTranslations('common');
  const copy = useCopy();
  const card = model.card;
  const link = (target: ModelOptionLinkAction | undefined, capability: 'web' | 'reasoning') => (
    target && actions.canFollow(target) ? (
      <button type="button" className={styles.modelControlInlineAction} data-variant="link" onClick={() => actions.follow(target, capability)}>
        {copy({ key: MODEL_OPTION_LINK_KEYS[target] })}
      </button>
    ) : null
  );

  if (card.kind === 'protocolUndecided') {
    return (
      <section className={styles.modelControlCard} aria-label={tc('modelOptionsCapabilitiesSection')}>
        <strong className={styles.modelControlCardTitle}>{copy({ key: MODEL_OPTION_PROTOCOL_UNDECIDED_KEYS.title })}</strong>
        <p className={styles.modelControlNote} data-tone="tertiary">{copy({ key: MODEL_OPTION_PROTOCOL_UNDECIDED_KEYS.body })}</p>
        {actions.canFollow(card.link) && (
          <button type="button" className={main.primaryAction} onClick={() => actions.follow(card.link, 'web')}>
            {copy({ key: MODEL_OPTION_LINK_KEYS[card.link] })}
          </button>
        )}
      </section>
    );
  }

  const renderRow = (row: ModelOptionsPanelRow) => {
    const title = copy({ key: MODEL_OPTION_CAPABILITY_TITLE_KEYS[row.capability] });
    switch (row.kind) {
      case 'toggle':
      case 'toggleWithTiming':
        return (
          <>
            <div className={styles.modelControlCardHeader}>
              <span className={main.rowText}>
                <span className={styles.modelControlCardTitle}>{title}</span>
                {row.kind === 'toggle' && row.caption && (
                  <span className={main.caption}>{copy({ key: MODEL_OPTION_CAPTION_KEYS[row.caption] })}</span>
                )}
              </span>
              <Switch label={title} checked={row.isOn} onChange={(isOn) => actions.onToggle(row, isOn)} />
            </div>
            {row.kind === 'toggle' && link(row.link, row.capability)}
            {row.kind === 'toggleWithTiming' && (
              <Segments
                variant="segments"
                label={tc('capabilityControlSearchTiming')}
                options={row.timing.options.map((id) => ({ id, label: copy({ key: MODEL_OPTION_WEB_TIMING_KEYS[id] }) }))}
                selection={row.timing.selection}
                onSelect={(id) => actions.onWebTiming(id as 'automatic' | 'force')}
              />
            )}
          </>
        );
      case 'tiers': {
        const selection = row.selection ?? (row.options.includes('automatic') ? 'automatic' : undefined);
        const note = selection ? reasoningTierNoteCopy(selection) : undefined;
        return (
          <>
            <div className={styles.modelControlCardHeader}>
              <span className={styles.modelControlCardTitle}>{title}</span>
              <span className={main.trailing} data-tone={row.trailing.kind === 'rejected' ? 'error' : undefined}>
                {copy(modelOptionTierTrailingCopy(row.trailing))}
              </span>
            </div>
            <Segments
              variant="tiers"
              label={title}
              options={row.options.map((id) => ({ id, label: copy(reasoningTierLabelCopy(id)) }))}
              selection={selection}
              onSelect={(id) => actions.onTier(id, row.options, row.selection)}
            />
            {row.footnotes.length > 0
              ? row.footnotes.map((footnote, index) => (
                <p key={index} className={styles.modelControlNote} data-tone="tertiary">{copy(modelOptionTierFootnoteCopy(footnote))}</p>
              ))
              : note && <p className={styles.modelControlNote} data-tone="tertiary">{copy(note)}</p>}
          </>
        );
      }
      case 'notice':
        return (
          <>
            <div className={styles.modelControlCardHeader}>
              <span className={styles.modelControlCardTitle}>{title}</span>
              <span className={main.trailing}>{copy({ key: MODEL_OPTION_NOTICE_STATUS_KEYS[row.status] })}</span>
            </div>
            <p className={styles.modelControlNote} data-tone="tertiary">{copy(modelOptionNoticeBodyCopy(row.body))}</p>
            {link(row.link, row.capability)}
          </>
        );
      case 'chatTemplateBlocked':
        return (
          <>
            <div className={styles.modelControlCardHeader}>
              <span className={styles.modelControlCardTitle}>{title}</span>
              <span className={main.trailing}>{tc('modelOptionsCantSwitchHere')}</span>
            </div>
            <p className={styles.modelControlNote} data-tone="tertiary">{copy({ key: CHAT_TEMPLATE_THINKING_STATE_KEYS[row.state] })}</p>
            {link(row.link, row.capability)}
          </>
        );
      case 'disclosure': {
        const status = copy(modelOptionDisclosureStatusCopy(row.status, row.capability));
        const target = row.link && actions.canFollow(row.link) ? row.link : undefined;
        return target ? (
          <button type="button" className={main.disclosure} onClick={() => actions.follow(target, row.capability)}>
            <span className={styles.modelControlCardTitle}>{title}</span>
            <span className={main.trailing}>{status}</span>
            <ChevronRight size={14} aria-hidden="true" className={styles.modelControlForwardChevron} />
          </button>
        ) : (
          <div className={main.disclosure}>
            <span className={styles.modelControlCardTitle}>{title}</span>
            <span className={main.trailing}>{status}</span>
          </div>
        );
      }
      case 'protocolUndecided':
        return (
          <div className={main.disclosure}>
            <span className={styles.modelControlCardTitle}>{title}</span>
            {link(row.link, row.capability)}
          </div>
        );
    }
  };

  return (
    <section className={styles.modelControlCard} aria-label={tc('modelOptionsCapabilitiesSection')}>
      {card.rows.map((row) => (
        <div key={row.capability} className={main.row} role="group" aria-label={copy({ key: MODEL_OPTION_CAPABILITY_TITLE_KEYS[row.capability] })}>
          {renderRow(row)}
          {notes(model.notes[row.capability], row.capability)}
        </div>
      ))}
    </section>
  );
}

export function ModelOptionsParametersCard({ model, onOpen }: { model: ModelOptionsPanelModel; onOpen: () => void }) {
  const tc = useTranslations('common');
  const copy = useCopy();
  const { chips, moreCount } = model.parameters;
  return (
    <button type="button" className={styles.modelControlNavigationRow} onClick={onOpen}>
      <span className={styles.modelControlNavigationCopy}>
        <span className={styles.modelControlCardTitle}>{tc('modelBehavior')}</span>
        {(chips.length > 0 || moreCount > 0) && (
          <span className={main.chips}>
            {chips.map((chip) => (
              <span key={chip.id} className={main.chip} data-kind="set">
                {`${copy(generationParameterTitleCopy(chip.id))} ${copy(generationDisplayValueCopy(chip.displayValue))}`}
              </span>
            ))}
            {moreCount > 0 && <span className={main.chip}>{tc('modelOptionsMoreCount', { count: moreCount })}</span>}
          </span>
        )}
      </span>
      <ChevronRight size={14} aria-hidden="true" className={styles.modelControlForwardChevron} />
    </button>
  );
}

function Switch({ label, checked, onChange }: { label: string; checked: boolean; onChange: (isOn: boolean) => void }) {
  return (
    <label className={styles.modelControlSwitchHit}>
      <input
        type="checkbox"
        role="switch"
        className={styles.modelControlSwitch}
        aria-label={label}
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
      />
      <span className={styles.modelControlSwitchTrack} aria-hidden="true">
        <span className={styles.modelControlSwitchThumb}>
          <Check className={styles.modelControlSwitchCheck} strokeWidth={3} />
        </span>
      </span>
    </label>
  );
}

/**
 * Offset applied by an arrow key inside a radiogroup. In RTL the left and right arrows flip with the reading direction (APG radio group).
 */
function radioArrowDelta(key: string, isRTL: boolean): number {
  switch (key) {
    case 'ArrowDown': return 1;
    case 'ArrowUp': return -1;
    case 'ArrowRight': return isRTL ? -1 : 1;
    case 'ArrowLeft': return isRTL ? 1 : -1;
    default: return 0;
  }
}

function isRTLElement(element: Element): boolean {
  return element.closest('[dir]')?.getAttribute('dir') === 'rtl'
    || element.ownerDocument.documentElement.dir === 'rtl';
}

/**
 * Segmented control (APG radio group): roving tabindex, so the whole group takes a single stop in the
 * Tab order; arrow keys move focus and the selection together, and Home / End jump to the ends. When
 * nothing is selected, Tab lands on the first segment.
 */
const TIER_BAR_COUNT: Readonly<Record<string, number>> = { low: 1, balanced: 2, deep: 3, max: 4 };
const TIER_BAR_HEIGHTS = [4, 7, 10, 13] as const;

/** Tier icon: signal bars light up according to the tier, "automatic" is a sparkle, and "off" is a horizontal line. Unknown tiers are not drawn. */
function TierIcon({ tier }: { tier: string }) {
  if (tier === 'automatic') {
    return (
      <svg className={main.tierIcon} width={15} height={13} viewBox="0 0 15 13" fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
        <path d="M7.5 1v2.2M7.5 9.8V12M2 6.5h2.2M10.8 6.5H13M3.6 2.6l1.5 1.5M9.9 8.9l1.5 1.5M11.4 2.6L9.9 4.1M5.1 8.9l-1.5 1.5" />
      </svg>
    );
  }
  if (tier === 'off') {
    return (
      <svg className={main.tierIcon} width={15} height={13} viewBox="0 0 15 13" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" aria-hidden="true" focusable="false">
        <path d="M3.5 6.5h8" />
      </svg>
    );
  }
  const filled = TIER_BAR_COUNT[tier];
  if (filled === undefined) return null;
  return (
    <svg className={main.tierIcon} width={19.5} height={13} viewBox="0 0 19.5 13" fill="currentColor" aria-hidden="true" focusable="false">
      {TIER_BAR_HEIGHTS.map((height, index) => (
        <rect key={height} x={index * 5.5} y={13 - height} width={3} height={height} rx={1.5} opacity={index < filled ? 1 : 0.32} />
      ))}
    </svg>
  );
}

function Segments({ variant, label, options, selection, onSelect }: {
  /** `tiers`: tier segments with the icon on top; `segments`: single-line text segments. Both use equal-width cells. */
  variant: 'tiers' | 'segments';
  label: string;
  options: ReadonlyArray<{ id: string; label: string }>;
  selection: string | undefined;
  onSelect: (id: string) => void;
}) {
  const groupRef = useRef<HTMLDivElement>(null);
  const selectedIndex = Math.max(0, options.findIndex((option) => option.id === selection));
  const handleKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const container = groupRef.current;
    if (!container) return;
    const delta = radioArrowDelta(event.key, isRTLElement(container));
    const isEdgeKey = event.key === 'Home' || event.key === 'End';
    if (delta === 0 && !isEdgeKey) return;
    event.preventDefault();
    const nextIndex = event.key === 'Home' ? 0
      : event.key === 'End' ? options.length - 1
      : (selectedIndex + delta + options.length) % options.length;
    const next = options[nextIndex];
    if (!next) return;
    container.querySelectorAll<HTMLButtonElement>('[role="radio"]')[nextIndex]?.focus();
    onSelect(next.id);
  };
  return (
    <div ref={groupRef} className={styles.modelControlPills} data-variant={variant} role="radiogroup" aria-label={label} onKeyDown={handleKeyDown}>
      {options.map((option, index) => (
        <button
          key={option.id}
          type="button"
          role="radio"
          aria-checked={selection === option.id}
          tabIndex={index === selectedIndex ? 0 : -1}
          className={styles.modelControlPill}
          data-active={selection === option.id}
          onClick={() => onSelect(option.id)}
        >
          {variant === 'tiers' && <TierIcon tier={option.id} />}
          <span className={main.segmentLabel}>{option.label}</span>
        </button>
      ))}
    </div>
  );
}
