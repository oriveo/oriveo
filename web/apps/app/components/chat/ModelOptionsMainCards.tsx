'use client';

import React, { useRef } from 'react';
import { useTranslations } from 'next-intl';
import { Check, ChevronRight } from 'lucide-react';
import { BrainIcon, CheckIcon, EyeIcon, GlobeIcon, PaperclipIcon, QuestionIcon, SlidersHorizontalIcon, ThermometerSimpleIcon, XIcon } from '@phosphor-icons/react';
import { useCopy } from '../generation/useCopy';
import type { ModelControlFooterEntry } from '../../lib/core/chat/model-control-capability-layout';
import type { ModelOptionLinkAction } from '../../lib/core/chat/model-option-capability-shape';
import type { ModelOptionsPanelModel, ModelOptionsPanelRow, ModelOptionsTile } from '../../lib/core/chat/model-options-panel-model';
import {
  GENERATION_PARAMETER_UNSET_LABEL_KEYS,
  MODEL_OPTIONS_INFO_TILE_TITLE_KEYS,
  MODEL_OPTION_CAPABILITY_TITLE_KEYS,
  MODEL_OPTION_LINK_KEYS,
  MODEL_OPTION_PROTOCOL_UNDECIDED_KEYS,
  MODEL_OPTION_WEB_TIMING_KEYS,
  generationDisplayValueCopy,
  generationParameterTitleCopy,
  modelOptionTierFootnoteCopy,
  modelOptionTierTrailingCopy,
  modelOptionsReasoningLevelCountCopy,
  modelOptionsSummaryItemCopy,
  modelOptionsTileBodyCopy,
  modelOptionsTileStatusCopy,
  reasoningTierLabelCopy,
  reasoningTierNoteCopy,
} from '../../lib/core/chat/model-options-copy';
import styles from './InputComposer.module.css';
import main from './ModelOptionsMainCards.module.css';

/**
 * The three blocks of the "Model options" main pane: the header second line, the capabilities card (2x2 tiles + summary line) and the parameters card (temperature row + entry row).
 * Only draws what `modelOptionsPanelModel` produced; writes and exits go through callbacks from the host.
 */

export type ModelOptionsCardActions = {
  /** Returns false when there is no destination, and the exit is not drawn. */
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

  /** In-card controls: the switch sits top right; the timing segments and tier segments go below the status line. */
  const tileControl = (tile: Extract<ModelOptionsTile, { kind: 'capability' }>, title: string) => {
    const row = tile.row;
    if (row.kind === 'toggleWithTiming') {
      return (
        <Segments
          variant="segments"
          label={tc('capabilityControlSearchTiming')}
          options={row.timing.options.map((id) => ({ id, label: copy({ key: MODEL_OPTION_WEB_TIMING_KEYS[id] }) }))}
          selection={row.timing.selection}
          onSelect={(id) => actions.onWebTiming(id as 'automatic' | 'force')}
        />
      );
    }
    if (row.kind === 'tiers') {
      // The cell draws only the tier icon, the tier word is the accessible name; the selected tier word is written in the status line.
      return (
        <Segments
          variant="tiers"
          label={title}
          options={row.options.map((id) => ({ id, label: copy(reasoningTierLabelCopy(id)) }))}
          selection={row.selection}
          onSelect={(id) => actions.onTier(id, row.options, row.selection)}
        />
      );
    }
    if (row.kind === 'toggle') return link(row.link, row.capability);
    return null;
  };

  const corner = (tile: ModelOptionsTile, title: string) => {
    switch (tile.corner) {
      case 'switch': {
        const row = tile.kind === 'capability' && (tile.row.kind === 'toggle' || tile.row.kind === 'toggleWithTiming') ? tile.row : undefined;
        return row ? (
          <Switch
            label={title}
            checked={row.isOn}
            disabled={row.kind === 'toggle' && row.disabled === true}
            onChange={(isOn) => actions.onToggle(row, isOn)}
          />
        ) : null;
      }
      case 'levels':
        return tile.kind === 'capability' && tile.row.kind === 'tiers'
          ? <span className={main.tileCorner}>{copy(modelOptionsReasoningLevelCountCopy(tile.row.options.length))}</span>
          : null;
      case 'chevron':
        return <ChevronRight size={14} aria-hidden="true" className={styles.modelControlForwardChevron} />;
      case 'check':
        return <CheckIcon size={18} weight="bold" aria-hidden="true" className={main.tileMark} data-mark="check" />;
      case 'question':
        return <QuestionIcon size={18} weight="bold" aria-hidden="true" className={main.tileMark} data-mark="question" />;
      case 'x':
        return <XIcon size={18} weight="bold" aria-hidden="true" className={main.tileMark} data-mark="x" />;
      case 'none':
        return null;
    }
  };

  const renderTile = (tile: ModelOptionsTile) => {
    const key = tile.kind === 'capability' ? tile.capability : tile.kind;
    const title = copy({ key: tile.kind === 'capability' ? MODEL_OPTION_CAPABILITY_TITLE_KEYS[tile.capability] : MODEL_OPTIONS_INFO_TILE_TITLE_KEYS[tile.kind] });
    const status = modelOptionsTileStatusCopy(tile);
    const body = modelOptionsTileBodyCopy(tile);
    const action = tile.kind === 'capability' && tile.action && actions.canFollow(tile.action) ? tile.action : undefined;
    const content = (
      <>
        <span className={main.tileTop}>
          <TileIcon tile={key} />
          {(tile.corner !== 'chevron' || action) && corner(tile, title)}
        </span>
        <span className={styles.modelControlCardTitle}>{title}</span>
        {status && <span className={main.tileStatus}>{copy(status)}</span>}
        {body && <span className={main.tileBody}>{copy(body)}</span>}
      </>
    );
    return (
      <div key={key} className={main.tile} data-tile={key} role="group" aria-label={title}>
        {action && tile.kind === 'capability' ? (
          <button type="button" className={main.tileAction} onClick={() => actions.follow(action, tile.capability)}>
            {content}
          </button>
        ) : content}
        {tile.kind === 'capability' && tileControl(tile, title)}
      </div>
    );
  };

  const reasoningRow = card.rows.find((row) => row.capability === 'reasoning');
  return (
    <section className={`${styles.modelControlCard} ${main.capabilities}`} aria-label={tc('modelOptionsCapabilitiesSection')}>
      <div className={main.tileGrid}>{model.tiles.map(renderTile)}</div>
      {reasoningRow?.kind === 'tiers' && <TierNotes row={reasoningRow} />}
      {notes(model.notes.web, 'web')}
      {notes(model.notes.reasoning, 'reasoning')}
    </section>
  );
}

/** "This turn will send": placed after the parameters card (same on all platforms and the design board); not drawn when there are no items. */
export function ModelOptionsTurnSummary({ model }: { model: ModelOptionsPanelModel }) {
  const tc = useTranslations('common');
  const copy = useCopy();
  const items = model.summary.map((item) => copy(modelOptionsSummaryItemCopy(item))).join(' · ');
  if (!items) return null;
  return <p className={main.summary} data-testid="model-options-turn-summary">{tc('modelOptionsTurnSummary', { items })}</p>;
}

/** Below the grid: the tier-rejected warning and tier footnotes (not inside a card). */
function TierNotes({ row }: { row: Extract<ModelOptionsPanelRow, { kind: 'tiers' }> }) {
  const copy = useCopy();
  const note = row.selection ? reasoningTierNoteCopy(row.selection) : undefined;
  return (
    <>
      {row.trailing.kind === 'rejected' && (
        <p className={styles.modelControlNote} data-tone="error">{copy(modelOptionTierTrailingCopy(row.trailing))}</p>
      )}
      {row.footnotes.length > 0
        ? row.footnotes.map((footnote, index) => (
          <p key={index} className={styles.modelControlNote} data-tone="tertiary">{copy(modelOptionTierFootnoteCopy(footnote))}</p>
        ))
        : note && <p className={styles.modelControlNote} data-tone="tertiary">{copy(note)}</p>}
    </>
  );
}

const TILE_ICONS = {
  web: { Icon: GlobeIcon, color: 'var(--o-cap-web-search)' },
  reasoning: { Icon: BrainIcon, color: 'var(--o-cap-reasoning)' },
  vision: { Icon: EyeIcon, color: 'var(--o-cap-vision)' },
  file: { Icon: PaperclipIcon, color: 'var(--o-cap-attachment)' },
} as const;

function TileIcon({ tile }: { tile: keyof typeof TILE_ICONS }) {
  const { Icon, color } = TILE_ICONS[tile];
  return <Icon size={28} weight="duotone" color={color} aria-hidden="true" />;
}

/** Leading icon of the two parameter-card rows: neutral secondary color, not a capability color. */
const PARAMETER_ROW_ICON = { size: 22, weight: 'duotone', color: 'var(--o-text-secondary)', 'aria-hidden': true } as const;

/** Two parameter-card rows: temperature (only when present) + the original entry row (the chips no longer carry temperature). Either row opens the parameters page. */
export function ModelOptionsParametersCard({ model, onOpen }: { model: ModelOptionsPanelModel; onOpen: () => void }) {
  const tc = useTranslations('common');
  const copy = useCopy();
  const { chips, moreCount } = model.parameters;
  const temperature = model.temperature;
  const temperatureValue = temperature?.displayValue
    ? generationDisplayValueCopy(temperature.displayValue)
    : temperature?.unsetLabel ? { key: GENERATION_PARAMETER_UNSET_LABEL_KEYS[temperature.unsetLabel] } : undefined;
  return (
    <div className={main.parameterRows}>
      {temperature && (
        <button type="button" className={styles.modelControlNavigationRow} onClick={onOpen}>
          <ThermometerSimpleIcon {...PARAMETER_ROW_ICON} />
          <span className={styles.modelControlCardTitle}>{copy(generationParameterTitleCopy(temperature.id))}</span>
          {temperatureValue && <span className={main.trailing}>{copy(temperatureValue)}</span>}
          <ChevronRight size={14} aria-hidden="true" className={styles.modelControlForwardChevron} />
        </button>
      )}
      <button type="button" className={styles.modelControlNavigationRow} onClick={onOpen}>
        <SlidersHorizontalIcon {...PARAMETER_ROW_ICON} />
        <span className={styles.modelControlNavigationCopy}>
          <span className={styles.modelControlCardTitle}>{tc('generationParameters')}</span>
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
    </div>
  );
}

function Switch({ label, checked, disabled = false, onChange }: { label: string; checked: boolean; disabled?: boolean; onChange: (isOn: boolean) => void }) {
  return (
    <label className={styles.modelControlSwitchHit}>
      <input
        type="checkbox"
        role="switch"
        className={styles.modelControlSwitch}
        aria-label={label}
        checked={checked}
        disabled={disabled}
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
 * Arrow-key movement inside a radiogroup. In RTL the left and right arrows flip with the reading direction (APG radio group).
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
 * Segments (APG radio group): roving tabindex, so the whole group takes one stop in the Tab ring; arrow keys move focus and change the selection together,
 * Home / End jump to the ends. With no selection, Tab lands on the first cell.
 */
const TIER_BAR_COUNT: Readonly<Record<string, number>> = { low: 1, balanced: 2, deep: 3, max: 4 };
const TIER_BAR_HEIGHTS = [4, 7, 10, 13] as const;

function hasTierIcon(tier: string): boolean {
  return tier === 'automatic' || tier === 'off' || TIER_BAR_COUNT[tier] !== undefined;
}

/** Tier icon: signal bars lit according to the tier, "automatic" is a sparkle, "off" is a horizontal line. Unknown tiers are not drawn. */
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
    <div ref={groupRef} className={variant === 'tiers' ? `${styles.modelControlPills} ${main.tierSegments}` : styles.modelControlPills} data-variant={variant} role="radiogroup" aria-label={label} onKeyDown={handleKeyDown}>
      {options.map((option, index) => (
        <button
          key={option.id}
          type="button"
          role="radio"
          aria-checked={selection === option.id}
          tabIndex={index === selectedIndex ? 0 : -1}
          className={styles.modelControlPill}
          {...(variant === 'tiers' ? { 'aria-label': option.label } : {})}
          data-active={selection === option.id}
          onClick={() => onSelect(option.id)}
        >
          {variant === 'tiers' && <TierIcon tier={option.id} />}
          {/* Tier cells draw only the icon (the tier word is the accessible name); unknown tiers without an icon fall back to text. */}
          {(variant === 'segments' || !hasTierIcon(option.id)) && <span className={main.segmentLabel}>{option.label}</span>}
        </button>
      ))}
    </div>
  );
}
