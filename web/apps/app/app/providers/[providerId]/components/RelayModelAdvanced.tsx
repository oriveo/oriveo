'use client';

import type { CSSProperties } from 'react';
import { useTranslations } from 'next-intl';
import {
  ArrowCounterClockwiseIcon,
  BrainIcon,
  CaretDownIcon,
  CheckCircleIcon,
  DatabaseIcon,
  EyeIcon,
  GlobeIcon,
  HardDrivesIcon,
  ImageIcon,
  KeyIcon,
  LightningIcon,
  PaperclipIcon,
  ScanIcon,
  UserIcon,
  WrenchIcon,
  type Icon,
} from '@phosphor-icons/react';
import type { ReasoningMode } from '@oriveo/shared';
import { BackButton } from '@oriveo/ui';
import type { RelayAdvancedCapabilityKey } from '../../../../lib/core/relay-model-advanced-ops';
import { setupProtocolForTransport } from '../../relay/new/setup-board';
import { ProtocolDot } from '../../relay/new/setup-board-parts';
import {
  RELAY_ADVANCED_SEGMENTS,
  RELAY_ADVANCED_TEXT,
  type RelayAdvancedControl,
  type RelayAdvancedSegment,
  type RelayAdvancedSource,
  type RelayModelAdvancedBoard,
} from '../relay-model-advanced-board';
import styles from './RelayModelAdvanced.module.css';

/** Capability row icons and capability color tokens (eye / paperclip / image / wrench / globe). */
const CAP_ICONS: Record<RelayAdvancedCapabilityKey, { Icon: Icon; color: string }> = {
  image: { Icon: EyeIcon, color: 'var(--o-cap-vision)' },
  file: { Icon: PaperclipIcon, color: 'var(--o-cap-attachment)' },
  imageGeneration: { Icon: ImageIcon, color: 'var(--o-cap-image-gen-text)' },
  toolCall: { Icon: WrenchIcon, color: 'var(--o-cap-tools)' },
  web: { Icon: GlobeIcon, color: 'var(--o-cap-web-search)' },
};

/** Source badge: database / scan / check-circle / hard-drives / user. */
const SOURCE_ICONS: Record<RelayAdvancedSource, Icon> = {
  catalog: DatabaseIcon,
  detected: ScanIcon,
  tested: CheckCircleIcon,
  engine: HardDrivesIcon,
  user: UserIcon,
};

const CONTROLS: readonly RelayAdvancedControl[] = ['auto', 'on', 'off'];

function SourceBadge({ source }: { source: RelayAdvancedSource }) {
  const tRoot = useTranslations();
  const SourceIcon = SOURCE_ICONS[source];
  return (
    <span className={styles.sourceBadge} data-source={source}>
      <SourceIcon size={12} weight="bold" aria-hidden="true" />
      {tRoot(RELAY_ADVANCED_TEXT.source[source])}
    </span>
  );
}

export interface RelayModelAdvancedProps {
  board: RelayModelAdvancedBoard;
  backLabel: string;
  onBack: () => void;
  onRestoreAll: () => void;
  onSelectSegment: (segment: RelayAdvancedSegment) => void;
  onSetControl: (cap: RelayAdvancedCapabilityKey, control: RelayAdvancedControl) => void;
  onToggleLevel: (level: ReasoningMode) => void;
  onTestCapabilities: () => void;
  /** Key section menu: 'auto' or a key id. */
  onSelectKey: (value: string) => void;
  disabled?: boolean;
}

/** Model › Advanced: protocol / channel, four capability rows, thinking levels, and in the writable state the footer "Changes take effect immediately". */
export function RelayModelAdvanced({
  board,
  backLabel,
  onBack,
  onRestoreAll,
  onSelectSegment,
  onSetControl,
  onToggleLevel,
  onTestCapabilities,
  onSelectKey,
  disabled: disabledByCaller = false,
}: RelayModelAdvancedProps) {
  const tRoot = useTranslations();
  const tr = useTranslations('pages.relayDetail');
  const { protocolRow, thinking, keySection } = board;
  // Read-only Advanced: no control is operable (the back button is unaffected).
  const disabled = disabledByCaller || board.readOnly;

  return (
    <div className={styles.page} data-advanced-page>
      {/* Page header: [back · "Advanced" · restore] → model name → host. */}
      <div className={styles.header}>
        <BackButton label={backLabel} onClick={onBack} />
        <h1 className={styles.title}>{tRoot(RELAY_ADVANCED_TEXT.title)}</h1>
        {/* Restore all = text link (icon + accent color), greyed out when nothing can be restored. */}
        <button
          type="button"
          className={`${styles.textAction} ${styles.restoreAll}`}
          onClick={onRestoreAll}
          disabled={disabled || !board.restoreAllEnabled}
          aria-label={tRoot(RELAY_ADVANCED_TEXT.restoreAll)}
        >
          <ArrowCounterClockwiseIcon size={14} weight="bold" aria-hidden="true" />
          {tRoot(RELAY_ADVANCED_TEXT.restoreAll)}
        </button>
      </div>
      <div className={styles.headerText}>
        <div className={styles.modelName}>{board.header.modelName}</div>
        {board.header.host && <div className={styles.subtitle}>{board.header.host}</div>}
      </div>

      {board.readOnly && (
        <p className={styles.readOnlyNote} data-advanced-readonly-note>{tRoot('pages.relayDetail.advancedReadOnlyNote')}</p>
      )}

      <section className={styles.section} data-advanced-section="protocol">
        <div className={styles.sectionHeader}>
          <HardDrivesIcon size={16} weight="bold" aria-hidden="true" />
          {tRoot(protocolRow.kind === 'relay' ? RELAY_ADVANCED_TEXT.protocol : RELAY_ADVANCED_TEXT.channel)}
        </div>
        <div className={styles.card}>
        {protocolRow.kind === 'relay' ? (
          <>
            <div className={styles.segments} role="radiogroup" aria-label={tRoot(RELAY_ADVANCED_TEXT.protocol)}>
              {RELAY_ADVANCED_SEGMENTS.map((segment) => (
                <button
                  key={segment}
                  type="button"
                  role="radio"
                  className={styles.segment}
                  data-advanced-segment={segment}
                  data-active={protocolRow.selected === segment}
                  aria-checked={protocolRow.selected === segment}
                  disabled={disabled}
                  onClick={() => onSelectSegment(segment)}
                >
                  {segment === 'auto' ? tRoot(RELAY_ADVANCED_TEXT.segmentAuto) : (
                    <>
                      <ProtocolDot protocol={setupProtocolForTransport(segment)} />
                      {setupProtocolForTransport(segment)}
                    </>
                  )}
                </button>
              ))}
            </div>
            {/* Two description lines: line 1 appears only when Auto is selected; line 2 = status word · base URL. */}
            {protocolRow.autoEquals && (
              <div className={styles.explain} data-advanced-auto-line>
                {tRoot(
                  protocolRow.autoEqualsConnectionDefault
                    ? RELAY_ADVANCED_TEXT.autoEqualsConnectionDefault
                    : RELAY_ADVANCED_TEXT.autoEquals,
                  { value: protocolRow.autoEquals },
                )}
              </div>
            )}
            <div className={styles.explain} data-advanced-status-line data-protocol-status={protocolRow.status}>
              {[
                tRoot(RELAY_ADVANCED_TEXT.protocolStatus[protocolRow.status]),
                tRoot(RELAY_ADVANCED_TEXT.apiRoot, { value: protocolRow.apiRoot }),
              ].join(' · ')}
            </div>
          </>
        ) : (
          // Channel (local): title + hint in the left column, value in the right column, whole row centered.
          <div className={styles.capRow} data-advanced-channel-row>
            <span className={styles.capText} data-row-lead>
              <span className={styles.capTitle}>{tRoot(RELAY_ADVANCED_TEXT.channel)}</span>
              {protocolRow.channelHint && <span className={styles.capSubtitle}>{tRoot(RELAY_ADVANCED_TEXT.channelHint)}</span>}
            </span>
            <span className={styles.channelValue} data-row-trailing>{protocolRow.channel}</span>
          </div>
        )}
        </div>
      </section>

      {keySection && (
        <section className={styles.section} data-advanced-section="key">
          <div className={styles.sectionHeader}>
            <KeyIcon size={16} weight="bold" aria-hidden="true" />
            {tRoot('pages.relayDetail.advancedKeySection')}
          </div>
          {/* Key section: name + mask + hint together in the left column, the menu centered against the whole left column. */}
          <div className={styles.card}>
          <div className={styles.keyRow}>
            <span className={styles.capText} data-row-lead>
              <span className={styles.keyName}>{keySection.current.title}</span>
              {keySection.current.title !== keySection.current.preview && (
                <span className={styles.keyMask}>{keySection.current.preview}</span>
              )}
              <span className={styles.explain}>{tRoot('pages.relayDetail.advancedKeyAutoHint')}</span>
            </span>
            <span className={styles.selectWrap} data-row-trailing>
              <select
                className={styles.select}
                data-control={keySection.selected === 'auto' ? 'auto' : 'set'}
                value={keySection.selected}
                disabled={disabled}
                aria-label={tRoot('pages.relayDetail.advancedKeySection')}
                onChange={(event) => onSelectKey(event.target.value)}
              >
                <option value="auto">{tRoot(RELAY_ADVANCED_TEXT.control.auto)}</option>
                {keySection.options.map((option) => (
                  <option key={option.id} value={option.id}>
                    {option.title === option.preview ? option.title : `${option.title} · ${option.preview}`}
                  </option>
                ))}
              </select>
              <CaretDownIcon className={styles.selectCaret} size={12} weight="bold" aria-hidden="true" />
            </span>
          </div>
          </div>
        </section>
      )}

      <section className={styles.section} data-advanced-section="capabilities">
        <div className={styles.sectionHeader}>
          <LightningIcon size={16} weight="bold" aria-hidden="true" />
          {tRoot(RELAY_ADVANCED_TEXT.capabilities)}
        </div>
        <div className={`${styles.card} ${styles.capList}`}>
        {board.capabilityRows.map((row) => {
          const { Icon: CapIcon, color } = CAP_ICONS[row.cap];
          return (
            <div key={row.cap} className={styles.capRow} data-advanced-cap={row.cap} data-cap-state={row.state}>
              <span className={styles.capIcon} style={{ '--cap-color': color } as CSSProperties} aria-hidden="true">
                <CapIcon size={18} weight={row.state === 'supported' ? 'duotone' : 'regular'} />
              </span>
              <span className={styles.capText}>
                <span className={styles.capTitle}>{tRoot(RELAY_ADVANCED_TEXT.capTitle[row.cap])}</span>
                <span className={styles.capSubtitle}>
                  {tRoot(row.stateKey)}
                  {row.source && (
                    <>
                      <span aria-hidden="true"> · </span>
                      <SourceBadge source={row.source} />
                    </>
                  )}
                </span>
              </span>
              <span className={styles.selectWrap}>
                <select
                  className={styles.select}
                  data-control={row.control}
                  value={row.control}
                  disabled={disabled}
                  aria-label={tRoot(RELAY_ADVANCED_TEXT.capTitle[row.cap])}
                  onChange={(event) => onSetControl(row.cap, event.target.value as RelayAdvancedControl)}
                >
                  {CONTROLS.map((control) => (
                    <option key={control} value={control}>{tRoot(RELAY_ADVANCED_TEXT.control[control])}</option>
                  ))}
                </select>
                <CaretDownIcon className={styles.selectCaret} size={12} weight="bold" aria-hidden="true" />
              </span>
            </div>
          );
        })}
        {/* Test entry: at the bottom inside the capability card, plain primary text at the start of the row. */}
        {board.testEntry && (
          <div className={styles.testEntry}>
            <button type="button" className={styles.textAction} onClick={onTestCapabilities} disabled={disabled}>
              {tr('capabilityTest.action')}
            </button>
          </div>
        )}
        </div>
      </section>

      {thinking && (
        <section className={styles.section} data-advanced-section="thinking">
          <div className={styles.sectionHeader}>
            <BrainIcon size={16} weight="bold" aria-hidden="true" />
            {tRoot(RELAY_ADVANCED_TEXT.thinkingLevels)}
          </div>
          <div className={`${styles.card} ${styles.levels}`} role="group" aria-label={tRoot(RELAY_ADVANCED_TEXT.thinkingLevels)}>
            {thinking.cells.map((cell) => (
              <button
                key={cell.level}
                type="button"
                className={styles.level}
                data-thinking-cell={cell.level}
                data-available={cell.available}
                data-selected={cell.selected}
                aria-pressed={cell.selected}
                disabled={disabled || !cell.canToggle}
                onClick={() => onToggleLevel(cell.level)}
              >
                {tRoot(RELAY_ADVANCED_TEXT.level[cell.level])}
              </button>
            ))}
          </div>
        </section>
      )}

      {board.legend.length > 0 && (
        <ul className={styles.legend} data-advanced-legend>
          {board.legend.map((source) => <li key={source}><SourceBadge source={source} /></li>)}
        </ul>
      )}
      {board.footer && <p className={styles.footer} data-advanced-footer>{tRoot(RELAY_ADVANCED_TEXT.appliesNow)}</p>}
    </div>
  );
}
